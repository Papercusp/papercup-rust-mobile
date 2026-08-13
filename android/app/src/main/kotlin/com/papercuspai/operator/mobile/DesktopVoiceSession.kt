// SPDX-License-Identifier: GPL-3.0-or-later
package com.papercuspai.operator.mobile

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.AudioTrack
import android.media.MediaRecorder
import android.util.Base64
import android.util.Log
import androidx.core.content.ContextCompat
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.async
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import okhttp3.MediaType.Companion.toMediaTypeOrNull
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.util.concurrent.TimeUnit
import kotlin.math.min
import kotlin.math.sqrt

/// Desktop-local voice session (on-desktop-direct-lan-voice-2026-07-14
/// P-006/P-007) — the EL-free push-to-talk pipeline. The phone is a thin
/// audio client and the DESKTOP does STT (local whisper) + brain
/// (papercup persona) + TTS (kokoro), all free:
///
///   1. capture 16kHz mono PCM16 while the user talks (tap to finish)
///   2. POST one WAV to `${base}/api/device/voice/turn` (device JWT)
///   3. consume the SSE reply: `transcript` → `delta` (live text) →
///      per-sentence `audio` WAV chunks → `done`
///   4. gapless AudioTrack playback starts on the FIRST audio chunk
///
/// Transport (P-006): probes the voice-session-init `baseUrls` advertise
/// list (mesh → lan → tunnel) in parallel while the user is still
/// talking and streams the turn over the best reachable path, falling
/// back to the paired `creds.server`. ElevenLabs stays fully supported
/// BESIDE this (D-010) — VoiceManager dispatches on the session-init
/// `mode`; this class is only constructed for `mode:'desktop-local'`.
class DesktopVoiceSession(
    private val context: Context,
    private val scope: CoroutineScope,
    private val creds: DeviceCredentials,
    private val init: Init,
    private val listener: Listener,
) {
    /// Parsed voice-session-init `mode:'desktop-local'` payload.
    data class Init(
        val turnPath: String,
        val warmupPath: String,
        val routes: List<Route>,
    ) {
        companion object {
            fun fromJson(j: JSONObject): Init {
                val routes = mutableListOf<Route>()
                val arr = j.optJSONArray("baseUrls")
                if (arr != null) {
                    for (i in 0 until arr.length()) {
                        val r = arr.optJSONObject(i) ?: continue
                        val url = r.optString("url").trimEnd('/')
                        if (url.isNotBlank()) routes.add(Route(r.optString("kind", "lan"), url))
                    }
                }
                return Init(
                    turnPath = j.optString("turnPath", "/api/device/voice/turn"),
                    warmupPath = j.optString("warmupPath", "/api/device/voice/warmup"),
                    routes = routes,
                )
            }
        }
    }

    /// One advertised desktop route: kind is mesh | lan | tunnel.
    data class Route(val kind: String, val url: String)

    interface Listener {
        fun onState(state: VoiceManager.State)
        fun onMicLevel(level: Float)
        /// First spoken/streamed reply content — feeds the latency HUD.
        fun onFirstWord()
        /// "mesh · http://10.10.0.2:3070" etc, for the settings screen.
        fun onActiveRoute(route: String?)
        /// Terminal — the turn played out, came back empty, or failed.
        /// The owner tears the session down; the next FAB tap starts fresh.
        fun onFinished()
    }

    private val recording = ByteArrayOutputStream()
    @Volatile private var recorder: AudioRecord? = null
    @Volatile private var cancelled = false
    @Volatile private var track: AudioTrack? = null
    @Volatile private var activeCall: okhttp3.Call? = null
    private var recordJob: Job? = null
    private var sendJob: Job? = null
    private val probedRoute = CompletableDeferred<String?>()

    /// Start capturing the utterance. Also warms the desktop pipeline
    /// (whisper cold-start is multi-second) and probes the advertised
    /// routes — both while the user is still talking, so neither adds
    /// perceived latency.
    fun beginCapture() {
        listener.onState(VoiceManager.State.Listening)
        scope.launch(Dispatchers.IO) { fireWarmup() }
        scope.launch(Dispatchers.IO) {
            val best = runCatching { probeRoutes() }.getOrNull()
            probedRoute.complete(best)
        }
        recordJob = scope.launch(Dispatchers.IO) { captureLoop() }
    }

    /// Second FAB tap: stop recording and send the turn.
    fun endUtteranceAndSend() {
        if (sendJob != null || cancelled) return
        val rj = recordJob
        recorder = null // capture loop exits + releases the mic
        sendJob = scope.launch(Dispatchers.IO) {
            rj?.join()
            val pcm = recording.toByteArray()
            if (pcm.size < MIN_UTTERANCE_BYTES) {
                if (!cancelled) {
                    listener.onState(
                        VoiceManager.State.Failed(
                            "Didn't catch that — tap to try again.",
                            VoiceManager.FailureKind.Unknown,
                        ),
                    )
                }
                listener.onFinished()
                return@launch
            }
            listener.onState(VoiceManager.State.Connecting)
            val base = withTimeoutOrNull(4_000) { probedRoute.await() }
                ?: creds.server.trimEnd('/')
            runCatching { streamTurn(base, wavFromPcm16(pcm)) }
                .onFailure { err ->
                    if (!cancelled) {
                        Log.w(TAG, "voice turn failed", err)
                        listener.onState(
                            VoiceManager.State.Failed(
                                // WI-4966: raw transport text stays in the log
                                // above; the user sees actionable copy.
                                HumanError.describe(err, "The voice turn"),
                                VoiceManager.FailureKind.NetworkUnreachable,
                            ),
                        )
                    }
                    listener.onFinished()
                }
        }
    }

    /// Hard cancel: releases the mic, aborts the in-flight HTTP call,
    /// and silences playback. Idempotent; owner cancels the scope after.
    fun cancel() {
        cancelled = true
        recorder = null
        activeCall?.cancel()
        try {
            track?.pause()
            track?.flush()
        } catch (_: Throwable) {}
    }

    // ── capture ──────────────────────────────────────────────────────

    private fun captureLoop() {
        if (
            ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            listener.onState(
                VoiceManager.State.Failed(
                    "Mic unavailable — allow microphone access in Settings.",
                    VoiceManager.FailureKind.MicPermission,
                ),
            )
            listener.onFinished()
            return
        }
        val minBuf = AudioRecord.getMinBufferSize(
            SAMPLE_RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT,
        )
        val rec = try {
            AudioRecord(
                MediaRecorder.AudioSource.VOICE_RECOGNITION,
                SAMPLE_RATE,
                AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT,
                maxOf(minBuf * 2, 8192),
            )
        } catch (t: Throwable) {
            Log.w(TAG, "AudioRecord create failed", t)
            null
        }
        if (rec == null || rec.state != AudioRecord.STATE_INITIALIZED) {
            rec?.release()
            listener.onState(
                VoiceManager.State.Failed(
                    "Mic unavailable — check the microphone permission.",
                    VoiceManager.FailureKind.MicPermission,
                ),
            )
            listener.onFinished()
            return
        }
        recorder = rec
        try {
            rec.startRecording()
            val buf = ByteArray(4096)
            val startedAt = System.currentTimeMillis()
            while (recorder != null && !cancelled) {
                val n = rec.read(buf, 0, buf.size)
                if (n <= 0) break
                synchronized(recording) { recording.write(buf, 0, n) }
                listener.onMicLevel(rmsLevel(buf, n))
                if (System.currentTimeMillis() - startedAt > MAX_UTTERANCE_MS) {
                    Log.i(TAG, "utterance cap hit — auto-sending")
                    scope.launch(Dispatchers.Main) { endUtteranceAndSend() }
                    break
                }
            }
        } finally {
            try { rec.stop() } catch (_: Throwable) {}
            rec.release()
            recorder = null
            listener.onMicLevel(0f)
        }
    }

    // ── transport ────────────────────────────────────────────────────

    /// Probe every advertised route in parallel (mesh → lan → tunnel
    /// preference); first reachable by preference order wins. The paired
    /// `creds.server` is treated as known-reachable (session-init just
    /// came over it).
    private suspend fun probeRoutes(): String? {
        val candidates = init.routes.filter { it.url.isNotBlank() }
        if (candidates.isEmpty()) {
            listener.onActiveRoute(null)
            return null
        }
        val server = creds.server.trimEnd('/')
        val http = OkHttpClient.Builder()
            .connectTimeout(1500, TimeUnit.MILLISECONDS)
            .readTimeout(2500, TimeUnit.MILLISECONDS)
            .build()
        val results = coroutineScope {
            candidates.map { route ->
                async(Dispatchers.IO) {
                    val reachable = route.url == server || runCatching {
                        val req = Request.Builder()
                            .url("${route.url}/api/device/runtime-config")
                            .header("Authorization", "Bearer ${creds.deviceToken}")
                            .build()
                        http.newCall(req).execute().use { it.isSuccessful }
                    }.getOrDefault(false)
                    route to reachable
                }
            }.map { it.await() }
        }
        val best = results.firstOrNull { it.second }?.first
        listener.onActiveRoute(best?.let { "${it.kind} · ${it.url}" })
        Log.i(
            TAG,
            "route probe: " +
                results.joinToString { "${it.first.kind}=${if (it.second) "ok" else "down"}" } +
                " → ${best?.url ?: "fallback $server"}",
        )
        return best?.url
    }

    private fun fireWarmup() {
        runCatching {
            val http = OkHttpClient.Builder()
                .connectTimeout(4, TimeUnit.SECONDS)
                .readTimeout(20, TimeUnit.SECONDS)
                .build()
            val req = Request.Builder()
                .url(creds.server.trimEnd('/') + init.warmupPath)
                .header("Authorization", "Bearer ${creds.deviceToken}")
                .post("{}".toRequestBody(JSON_MEDIA))
                .build()
            http.newCall(req).execute().use {
                Log.i(TAG, "warmup → ${it.code} ${it.body?.string()?.take(160)}")
            }
        }.onFailure { Log.w(TAG, "warmup failed: ${it.message}") }
    }

    private suspend fun streamTurn(base: String, wav: ByteArray) {
        val http = OkHttpClient.Builder()
            .connectTimeout(8, TimeUnit.SECONDS)
            // Max gap BETWEEN SSE bytes, not the whole turn; the server
            // heartbeats, and stage gaps (STT→brain) stay well under this.
            .readTimeout(120, TimeUnit.SECONDS)
            .build()
        val body = JSONObject()
            .put("audioBase64", Base64.encodeToString(wav, Base64.NO_WRAP))
            .put("format", "wav")
            .toString()
        val req = Request.Builder()
            .url(base + init.turnPath)
            .header("Authorization", "Bearer ${creds.deviceToken}")
            .post(body.toRequestBody(JSON_MEDIA))
            .build()
        val call = http.newCall(req)
        activeCall = call
        try {
            call.execute().use { resp ->
                if (!resp.isSuccessful) {
                    val errBody = resp.body?.string().orEmpty()
                    error("voice-turn ${resp.code}: ${errBody.take(160)}")
                }
                consumeSse(resp)
            }
        } finally {
            activeCall = null
        }
    }

    // ── SSE consume + playback ───────────────────────────────────────

    private suspend fun consumeSse(resp: okhttp3.Response) {
        val chunks = Channel<WavPcm>(Channel.UNLIMITED)
        val playJob = scope.launch(Dispatchers.IO) { playbackLoop(chunks) }
        val source = resp.body?.source() ?: error("empty SSE body")
        var event = "message"
        val data = StringBuilder()
        val spokenText = StringBuilder()
        var sawFirst = false
        var failed: VoiceManager.State.Failed? = null
        try {
            while (!cancelled) {
                val line = source.readUtf8Line() ?: break
                when {
                    line.isEmpty() -> {
                        if (data.isNotEmpty()) {
                            val payload = data.toString()
                            data.setLength(0)
                            val name = event
                            event = "message"
                            when (name) {
                                "transcript" -> {
                                    // Whisper heard the user; brain is next.
                                    Log.i(TAG, "transcript: ${payload.take(200)}")
                                }
                                "delta" -> {
                                    val text = runCatching { JSONObject(payload).optString("text") }
                                        .getOrDefault("")
                                    if (text.isNotEmpty()) {
                                        if (!sawFirst) {
                                            sawFirst = true
                                            listener.onFirstWord()
                                        }
                                        spokenText.append(text)
                                        listener.onState(
                                            VoiceManager.State.Speaking(
                                                spokenText.toString().takeLast(400),
                                                "agent",
                                            ),
                                        )
                                    }
                                }
                                "audio" -> {
                                    val j = runCatching { JSONObject(payload) }.getOrNull()
                                    val b64 = j?.optString("audioBase64").orEmpty()
                                    if (b64.isNotEmpty()) {
                                        runCatching { Base64.decode(b64, Base64.DEFAULT) }
                                            .getOrNull()
                                            ?.let { parseWav(it) }
                                            ?.let { chunks.trySend(it) }
                                    }
                                }
                                "tts_state" -> Log.i(TAG, "tts_state: ${payload.take(200)}")
                                "error" -> {
                                    val j = runCatching { JSONObject(payload) }.getOrNull()
                                    failed = VoiceManager.State.Failed(
                                        "Voice ${j?.optString("stage") ?: "server"} error — " +
                                            (j?.optString("message") ?: payload).take(120) +
                                            ". Tap to retry.",
                                        VoiceManager.FailureKind.Unknown,
                                    )
                                }
                                "done" -> {
                                    val j = runCatching { JSONObject(payload) }.getOrNull()
                                    if (j?.optBoolean("emptyTranscript") == true) {
                                        // Silence / non-speech: the server stripped whisper's
                                        // [BLANK_AUDIO] marker and short-circuited BEFORE the
                                        // brain (no wasted round-trip). This is benign, NOT a
                                        // failure — leave `failed` null so the turn ends in
                                        // State.Idle and the FAB returns to ready, letting the
                                        // user simply speak again (conventional no-speech
                                        // behavior), instead of showing a red error state.
                                        Log.i(TAG, "empty transcript (no speech detected) — returning to idle")
                                    }
                                }
                                // heartbeat + forwarded brain events → ignore
                            }
                        } else {
                            event = "message"
                        }
                    }
                    line.startsWith(":") -> {}
                    line.startsWith("event:") -> event = line.substring(6).trim()
                    line.startsWith("data:") -> {
                        if (data.isNotEmpty()) data.append('\n')
                        data.append(line.substring(5).trimStart())
                    }
                    // id: / retry: → ignore
                }
            }
        } finally {
            chunks.close()
        }
        if (cancelled) {
            playJob.cancel()
        } else {
            // Let the queued audio play out.
            playJob.join()
        }
        when {
            cancelled -> {}
            failed != null -> listener.onState(failed)
            else -> listener.onState(VoiceManager.State.Idle)
        }
        listener.onFinished()
    }

    private suspend fun playbackLoop(chunks: Channel<WavPcm>) {
        var current: AudioTrack? = null
        var rate = 0
        var chans = 0
        try {
            for (chunk in chunks) {
                if (cancelled) break
                if (current == null || rate != chunk.sampleRate || chans != chunk.channels) {
                    current?.let {
                        try { it.stop() } catch (_: Throwable) {}
                        it.release()
                    }
                    val mask = if (chunk.channels >= 2) {
                        AudioFormat.CHANNEL_OUT_STEREO
                    } else {
                        AudioFormat.CHANNEL_OUT_MONO
                    }
                    val minBuf = AudioTrack.getMinBufferSize(
                        chunk.sampleRate, mask, AudioFormat.ENCODING_PCM_16BIT,
                    )
                    val t = AudioTrack.Builder()
                        .setAudioAttributes(
                            AudioAttributes.Builder()
                                .setUsage(AudioAttributes.USAGE_MEDIA)
                                .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                                .build(),
                        )
                        .setAudioFormat(
                            AudioFormat.Builder()
                                .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                                .setSampleRate(chunk.sampleRate)
                                .setChannelMask(mask)
                                .build(),
                        )
                        .setTransferMode(AudioTrack.MODE_STREAM)
                        .setBufferSizeInBytes(maxOf(minBuf * 2, 16384))
                        .build()
                    rate = chunk.sampleRate
                    chans = chunk.channels
                    t.play()
                    current = t
                    track = t
                }
                // Blocking writes pace playback naturally (gapless).
                var off = 0
                while (off < chunk.pcm.size && !cancelled) {
                    val n = current.write(chunk.pcm, off, min(16384, chunk.pcm.size - off))
                    if (n < 0) break
                    off += n
                }
            }
            if (!cancelled && current != null) {
                // stop() in MODE_STREAM drains what's written; give the
                // tail of the buffer time to play before release.
                try { current.stop() } catch (_: Throwable) {}
                delay(400)
            }
        } finally {
            current?.let { try { it.release() } catch (_: Throwable) {} }
            track = null
        }
    }

    // ── WAV helpers ──────────────────────────────────────────────────

    private class WavPcm(val sampleRate: Int, val channels: Int, val pcm: ByteArray)

    private fun parseWav(bytes: ByteArray): WavPcm? {
        if (bytes.size < 44) return null
        if (ascii(bytes, 0) != "RIFF" || ascii(bytes, 8) != "WAVE") return null
        var pos = 12
        var sampleRate = 24_000
        var channels = 1
        var bits = 16
        var pcm: ByteArray? = null
        while (pos + 8 <= bytes.size) {
            val id = ascii(bytes, pos)
            val size = le32(bytes, pos + 4)
            val body = pos + 8
            if (size < 0 || body > bytes.size) break
            when (id) {
                "fmt " -> if (body + 16 <= bytes.size) {
                    channels = le16(bytes, body + 2)
                    sampleRate = le32(bytes, body + 4)
                    bits = le16(bytes, body + 14)
                }
                "data" -> {
                    val len = min(size, bytes.size - body)
                    if (len > 0) pcm = bytes.copyOfRange(body, body + len)
                }
            }
            pos = body + size + (size and 1)
        }
        val out = pcm ?: return null
        if (bits != 16) {
            Log.w(TAG, "unsupported wav: bits=$bits")
            return null
        }
        return WavPcm(sampleRate.coerceIn(8_000, 48_000), channels.coerceIn(1, 2), out)
    }

    private fun ascii(b: ByteArray, off: Int) = String(b, off, 4, Charsets.US_ASCII)

    private fun le16(b: ByteArray, off: Int) =
        (b[off].toInt() and 0xff) or ((b[off + 1].toInt() and 0xff) shl 8)

    private fun le32(b: ByteArray, off: Int) =
        (b[off].toInt() and 0xff) or
            ((b[off + 1].toInt() and 0xff) shl 8) or
            ((b[off + 2].toInt() and 0xff) shl 16) or
            ((b[off + 3].toInt() and 0xff) shl 24)

    /// 44-byte canonical header for 16kHz mono PCM16.
    private fun wavFromPcm16(pcm: ByteArray): ByteArray {
        val out = ByteArrayOutputStream(44 + pcm.size)
        fun w32(v: Int) {
            out.write(v and 0xff); out.write((v shr 8) and 0xff)
            out.write((v shr 16) and 0xff); out.write((v shr 24) and 0xff)
        }
        fun w16(v: Int) {
            out.write(v and 0xff); out.write((v shr 8) and 0xff)
        }
        out.write("RIFF".toByteArray(Charsets.US_ASCII)); w32(36 + pcm.size)
        out.write("WAVE".toByteArray(Charsets.US_ASCII))
        out.write("fmt ".toByteArray(Charsets.US_ASCII)); w32(16)
        w16(1) // PCM
        w16(1) // mono
        w32(SAMPLE_RATE)
        w32(SAMPLE_RATE * 2) // byte rate
        w16(2) // block align
        w16(16) // bits
        out.write("data".toByteArray(Charsets.US_ASCII)); w32(pcm.size)
        out.write(pcm)
        return out.toByteArray()
    }

    private fun rmsLevel(buf: ByteArray, n: Int): Float {
        var sum = 0.0
        var i = 0
        while (i + 1 < n) {
            val s = (((buf[i].toInt() and 0xff) or (buf[i + 1].toInt() shl 8)).toShort()).toInt()
            sum += (s.toDouble() * s.toDouble())
            i += 2
        }
        val rms = sqrt(sum / maxOf(1, n / 2))
        return (rms / 6000.0).toFloat().coerceIn(0f, 1f)
    }

    companion object {
        private const val TAG = "PapercupVoiceLocal"
        private const val SAMPLE_RATE = 16_000
        private const val MAX_UTTERANCE_MS = 60_000L
        /// ~0.4s @ 16kHz mono PCM16 — anything shorter is a stray tap.
        private const val MIN_UTTERANCE_BYTES = 12_800
        private val JSON_MEDIA = "application/json".toMediaTypeOrNull()
    }
}
