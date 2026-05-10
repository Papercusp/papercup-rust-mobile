// SPDX-License-Identifier: GPL-3.0-or-later
package com.papercuspai.operator.mobile

import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import android.speech.tts.TextToSpeech
import android.util.Log
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import uniffi.papercup.OperatorClient
import uniffi.papercup.VoiceClient
import uniffi.papercup.VoiceEvent
import uniffi.papercup.VoiceException
import uniffi.papercup.VoiceStatus

/// Voice coordinator. Owns the WS client, the STT recognizer, the TTS
/// engine, the lease heartbeat, and the state machine the UI reads.
///
/// Wire protocol mirrors the Tauri-era impl: phone does STT + TTS
/// locally; only transcripts go up and speak frames come down. Phone
/// is the lease owner while listening; releases on stop.
///
/// Lifecycle is bound to a `start()` / `stop()` pair. Internally it
/// owns a SupervisorJob; `stop()` cancels everything cleanly.
class VoiceManager(
    private val context: Context,
    private val creds: DeviceCredentials,
    private val wakeWord: String = "hey papercup",
) {
    sealed interface State {
        data object Idle : State
        data object Connecting : State
        data object Listening : State
        data class Speaking(val text: String, val source: String) : State
        data class Failed(val message: String) : State
    }

    private val _state = MutableStateFlow<State>(State.Idle)
    val state: StateFlow<State> = _state.asStateFlow()

    /// Microphone amplitude reported by SpeechRecognizer.onRmsChanged
    /// while listening. Range observed in practice: ~-2.0 (silence) to
    /// ~10 (loud); UI normalises to 0..1. Reset to 0 when not listening.
    private val _micLevel = MutableStateFlow(0f)
    val micLevel: StateFlow<Float> = _micLevel.asStateFlow()

    private var scope: CoroutineScope? = null
    private var voice: VoiceClient? = null
    private var recognizer: SpeechRecognizer? = null
    private var tts: TextToSpeech? = null
    private var pumpJob: Job? = null
    private var heartbeatJob: Job? = null
    /// We pause the recognizer while TTS plays. Resume after `utt.onDone`.
    @Volatile
    private var sttPaused = false

    fun start() {
        if (scope != null) return
        val s = CoroutineScope(SupervisorJob() + Dispatchers.Main)
        scope = s
        _state.value = State.Connecting

        s.launch(Dispatchers.IO) {
            try {
                OperatorClient(creds.server, creds.deviceToken).voiceLeaseClaim()
            } catch (t: Throwable) {
                Log.w(TAG, "lease claim failed: ${t.message}")
            }
        }

        val client = VoiceClient(creds.server, creds.deviceToken, wakeWord)
        voice = client

        pumpJob = s.launch(Dispatchers.IO) { pumpEvents(client) }
        heartbeatJob = s.launch(Dispatchers.IO) {
            while (true) {
                delay(5_000)
                try {
                    OperatorClient(creds.server, creds.deviceToken).voiceLeaseHeartbeat()
                } catch (_: Throwable) {}
            }
        }

        // STT + TTS init has to happen on the main thread.
        s.launch(Dispatchers.Main) { initTts() }
    }

    fun stop() {
        val s = scope ?: return
        scope = null
        try { recognizer?.cancel() } catch (_: Throwable) {}
        try { recognizer?.destroy() } catch (_: Throwable) {}
        recognizer = null
        try { tts?.stop() } catch (_: Throwable) {}
        try { tts?.shutdown() } catch (_: Throwable) {}
        tts = null
        try { voice?.disconnect() } catch (_: Throwable) {}
        try { voice?.close() } catch (_: Throwable) {}
        voice = null
        _micLevel.value = 0f
        s.cancel()
        pumpJob = null
        heartbeatJob = null
        _state.value = State.Idle

        // Best-effort lease release.
        CoroutineScope(Dispatchers.IO).launch {
            try {
                OperatorClient(creds.server, creds.deviceToken).voiceLeaseRelease()
            } catch (_: Throwable) {}
        }
    }

    private suspend fun pumpEvents(client: VoiceClient) {
        try {
            while (true) {
                val ev = try { client.nextEvent() }
                catch (_: VoiceException) {
                    _state.value = State.Failed("voice stream closed")
                    return
                }
                when (ev) {
                    is VoiceEvent.Connected -> {
                        _state.value = State.Listening
                        client.sendStatus(VoiceStatus.LISTENING)
                        startStt()
                    }
                    is VoiceEvent.Speak -> {
                        _state.value = State.Speaking(ev.text, ev.source)
                        sttPaused = true
                        try { recognizer?.cancel() } catch (_: Throwable) {}
                        client.sendStatus(VoiceStatus.SPEAKING)
                        speak(ev.text, ev.format)
                    }
                    is VoiceEvent.Closed -> {
                        if (ev.code == 1008.toUShort()) {
                            _state.value = State.Failed("auth rejected — re-pair the device")
                        } else {
                            // Transient close; the WS task is reconnecting.
                            _state.value = State.Connecting
                        }
                    }
                }
            }
        } catch (t: Throwable) {
            _state.value = State.Failed(t.message ?: t::class.simpleName ?: "voice error")
        }
    }

    // ── STT (SpeechRecognizer) ─────────────────────────────────────────────

    private fun startStt() {
        if (sttPaused) return
        if (!SpeechRecognizer.isRecognitionAvailable(context)) {
            _state.value = State.Failed(
                "Speech recognition not installed on this device.",
            )
            return
        }
        // Recognizer must run on the main thread.
        CoroutineScope(Dispatchers.Main).launch {
            recognizer?.destroy()
            val r = SpeechRecognizer.createSpeechRecognizer(context)
            r.setRecognitionListener(SttListener())
            recognizer = r
            val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
                putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
                putExtra(RecognizerIntent.EXTRA_LANGUAGE, java.util.Locale.US.toLanguageTag())
                putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, false)
                putExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, false)
            }
            r.startListening(intent)
        }
    }

    private inner class SttListener : RecognitionListener {
        override fun onReadyForSpeech(params: Bundle?) {}
        override fun onBeginningOfSpeech() {}
        override fun onRmsChanged(rmsdB: Float) {
            // Normalise to 0..1. SpeechRecognizer's rms is in dB and ranges
            // roughly -2..10 across silence-to-loud on the Fold5; clamp.
            val normalised = ((rmsdB + 2f) / 12f).coerceIn(0f, 1f)
            _micLevel.value = normalised
        }
        override fun onBufferReceived(buffer: ByteArray?) {}
        override fun onEndOfSpeech() {}
        override fun onPartialResults(partialResults: Bundle?) {}
        override fun onEvent(eventType: Int, params: Bundle?) {}

        override fun onError(error: Int) {
            Log.d(TAG, "stt error code=$error")
            // Most errors mean "no speech / silence / network" — just restart.
            if (!sttPaused && scope != null) startStt()
        }

        override fun onResults(results: Bundle?) {
            val texts = results?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION).orEmpty()
            val text = texts.firstOrNull()?.trim().orEmpty()
            if (text.isNotEmpty()) {
                Log.i(TAG, "transcript: $text")
                CoroutineScope(Dispatchers.IO).launch {
                    voice?.sendTranscript(text)
                }
            }
            // Restart listening for the next utterance.
            if (!sttPaused && scope != null) startStt()
        }
    }

    // ── TTS ────────────────────────────────────────────────────────────────

    private fun initTts() {
        tts = TextToSpeech(context.applicationContext) { status ->
            if (status == TextToSpeech.SUCCESS) {
                tts?.language = java.util.Locale.US
                tts?.setOnUtteranceProgressListener(object :
                    android.speech.tts.UtteranceProgressListener() {
                    override fun onStart(utteranceId: String?) {}
                    override fun onError(utteranceId: String?) { onUtteranceDone() }
                    override fun onDone(utteranceId: String?) { onUtteranceDone() }
                })
            }
        }
    }

    private fun onUtteranceDone() {
        sttPaused = false
        CoroutineScope(Dispatchers.IO).launch {
            voice?.sendStatus(VoiceStatus.LISTENING)
        }
        if (scope != null) startStt()
        _state.value = State.Listening
    }

    private fun speak(text: String, format: String?) {
        val cleaned = if (format == "ssml") {
            // Web Speech doesn't grok SSML; Android's TTS needs <speak> wrapping
            // or no markup. Strip tags as a stub like the Tauri impl did.
            text.replace(Regex("<[^>]+>"), "")
        } else {
            text
        }
        val id = "papercup-${System.currentTimeMillis()}"
        tts?.speak(cleaned, TextToSpeech.QUEUE_FLUSH, null, id)
    }

    private companion object {
        const val TAG = "PapercupVoice"
    }
}
