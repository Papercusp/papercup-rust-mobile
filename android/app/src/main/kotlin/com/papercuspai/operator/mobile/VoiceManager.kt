// SPDX-License-Identifier: GPL-3.0-or-later
package com.papercuspai.operator.mobile

import android.content.Context
import android.util.Log
import io.elevenlabs.ClientTool
import io.elevenlabs.ClientToolResult
import io.elevenlabs.ConversationClient
import io.elevenlabs.ConversationConfig
import io.elevenlabs.ConversationSession
import io.elevenlabs.models.ConversationMode
import io.elevenlabs.models.ConversationStatus
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import okhttp3.OkHttpClient
import okhttp3.Request
import org.json.JSONObject
import java.util.concurrent.TimeUnit

/// Voice coordinator — V1 (ElevenLabs Conversational AI).
///
/// Phone is an ElevenLabs Conv AI client of the SAME agent the desktop
/// uses. Phone fetches a short-lived conversation token from
/// `/api/mobile/voice-session-init` (operator mints via EL API key),
/// then starts a WebRTC session via the EL Android SDK. All STT/TTS/
/// VAD/AEC happen on the EL side. Tools the agent calls fall into:
///   - browser:'required' → invoked here as clientTools, mapped to a
///     ClientToolDispatcher which drives the phone's native UI
///   - browser:'none'/'optional' → webhook → /api/elevenlabs/webhook
///     → operator runCommand() (server-side, no phone involvement)
///
/// State surface preserved across the WSS → EL migration so the rest
/// of the app didn't have to change: state / intents / micLevel /
/// start() / stop().
class VoiceManager(
    private val context: Context,
    private val creds: DeviceCredentials,
) {
    sealed interface State {
        data object Idle : State
        data object Connecting : State
        data object Listening : State
        data class Speaking(val text: String, val source: String) : State
        data class Failed(val message: String) : State
    }

    /// Voice-driven phone intents. These map to client tools the
    /// agent invokes; they fire onto a SharedFlow the UI subscribes
    /// to (e.g. Navigate → push detail screen).
    sealed interface Intent {
        data class Navigate(val slug: String) : Intent
        data object Pause : Intent
        data object Resume : Intent
        data object ClaimVoice : Intent
    }

    private val _state = MutableStateFlow<State>(State.Idle)
    val state: StateFlow<State> = _state.asStateFlow()

    private val _intents = MutableSharedFlow<Intent>(extraBufferCapacity = 8)
    val intents: SharedFlow<Intent> = _intents.asSharedFlow()

    private val _micLevel = MutableStateFlow(0f)
    val micLevel: StateFlow<Float> = _micLevel.asStateFlow()

    private var scope: CoroutineScope? = null
    private var session: ConversationSession? = null
    private var sessionJob: Job? = null

    fun start() {
        if (scope != null) return
        val s = CoroutineScope(SupervisorJob() + Dispatchers.Main)
        scope = s
        _state.value = State.Connecting

        sessionJob = s.launch(Dispatchers.IO) {
            val initResult = runCatching { fetchSessionInit() }
            val init = initResult.getOrElse { err ->
                Log.w(TAG, "session-init failed: ${err.message}")
                _state.value = State.Failed("Voice unavailable — ${err.message}")
                return@launch
            }
            try {
                val config = ConversationConfig(
                    conversationToken = init.conversationToken,
                    userId = init.dynamicVariables.deviceId,
                    onConnect = { _ -> Log.i(TAG, "EL connected") },
                    onDisconnect = { reason ->
                        Log.i(TAG, "EL disconnected: $reason")
                        if (_state.value !is State.Failed) _state.value = State.Idle
                    },
                    onStatusChange = { status ->
                        when (status) {
                            ConversationStatus.CONNECTED -> if (_state.value is State.Connecting) {
                                _state.value = State.Listening
                            }
                            ConversationStatus.CONNECTING -> _state.value = State.Connecting
                            ConversationStatus.DISCONNECTED,
                            ConversationStatus.DISCONNECTING -> {
                                if (_state.value !is State.Failed) _state.value = State.Idle
                            }
                            ConversationStatus.ERROR -> _state.value = State.Failed("Voice error")
                        }
                    },
                    onModeChange = { mode ->
                        when (mode) {
                            ConversationMode.SPEAKING -> {
                                if (_state.value !is State.Speaking) {
                                    _state.value = State.Speaking("…", "agent")
                                }
                            }
                            ConversationMode.LISTENING -> _state.value = State.Listening
                        }
                    },
                    onAudioLevelChanged = { level -> _micLevel.value = level },
                    onAgentResponse = { response ->
                        _state.value = State.Speaking(response, "agent")
                    },
                    onUserTranscript = { transcript ->
                        Log.d(TAG, "user: $transcript")
                    },
                    onUnhandledClientToolCall = { call ->
                        Log.w(TAG, "agent invoked unhandled client tool: $call")
                    },
                    clientTools = buildClientTools(),
                )
                session = ConversationClient.startSession(config, context)
            } catch (t: Throwable) {
                Log.w(TAG, "EL startSession failed", t)
                _state.value = State.Failed("Voice unavailable — ${t.message ?: t.javaClass.simpleName}")
            }
        }
    }

    fun stop() {
        val s = scope ?: return
        scope = null
        val sess = session
        session = null
        // endSession() is a suspend fn; fire-and-forget on IO before
        // we cancel the scope.
        if (sess != null) {
            CoroutineScope(Dispatchers.IO).launch {
                try { sess.endSession() } catch (_: Throwable) {}
            }
        }
        sessionJob?.cancel()
        sessionJob = null
        _micLevel.value = 0f
        _state.value = State.Idle
        s.cancel()
    }

    /// Native client-tool table. These are the `browser:'required'`
    /// commands the desktop registry exposes — phone implementations
    /// drive native UI for the same command ids. Tools that don't
    /// need a UI session land server-side via the EL webhook and
    /// don't appear here.
    private fun buildClientTools(): Map<String, ClientTool> = mapOf(
        "nav.openHarness" to clientTool { params ->
            val slug = params["slug"]?.toString().orEmpty()
            if (slug.isBlank()) ClientToolResult.failure("missing slug")
            else {
                _intents.tryEmit(Intent.Navigate(slug))
                ClientToolResult.success("ok")
            }
        },
        "operator.pause" to clientTool { _ ->
            _intents.tryEmit(Intent.Pause)
            ClientToolResult.success("ok")
        },
        "operator.resume" to clientTool { _ ->
            _intents.tryEmit(Intent.Resume)
            ClientToolResult.success("ok")
        },
        "voice.claim" to clientTool { _ ->
            _intents.tryEmit(Intent.ClaimVoice)
            ClientToolResult.success("ok")
        },
    )

    private inline fun clientTool(crossinline body: suspend (Map<String, Any>) -> ClientToolResult?): ClientTool =
        object : ClientTool {
            override suspend fun execute(parameters: Map<String, Any>): ClientToolResult? = body(parameters)
        }

    private fun fetchSessionInit(): SessionInit {
        val http = OkHttpClient.Builder()
            .connectTimeout(8, TimeUnit.SECONDS)
            .readTimeout(8, TimeUnit.SECONDS)
            .build()
        val req = Request.Builder()
            .url("${creds.server}/api/mobile/voice-session-init?surface=mobile-android")
            .header("Authorization", "Bearer ${creds.deviceToken}")
            .build()
        http.newCall(req).execute().use { resp ->
            val body = resp.body?.string().orEmpty()
            if (!resp.isSuccessful) {
                error("session-init ${resp.code}: ${body.take(160)}")
            }
            val j = JSONObject(body)
            val dyn = j.optJSONObject("dynamicVariables") ?: JSONObject()
            return SessionInit(
                conversationToken = j.getString("conversationToken"),
                agentId = j.getString("agentId"),
                dynamicVariables = DynamicVars(
                    deviceId = dyn.optString("device_id"),
                    workspaceId = dyn.optString("workspace_id"),
                    surface = dyn.optString("surface", "mobile-android"),
                    desktopHost = dyn.optString("desktop_host", ""),
                ),
            )
        }
    }

    private data class SessionInit(
        val conversationToken: String,
        val agentId: String,
        val dynamicVariables: DynamicVars,
    )

    private data class DynamicVars(
        val deviceId: String,
        val workspaceId: String,
        val surface: String,
        val desktopHost: String,
    )

    companion object {
        private const val TAG = "PapercupVoice"
    }
}
