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
import okhttp3.MediaType.Companion.toMediaTypeOrNull
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
    /// Phone-side intents the agent can fire via client tools. Each
    /// maps to a `browser: 'required'` command in the desktop registry
    /// so the agent's tool catalog is identical across desktop + phone;
    /// the implementation is what differs. MainActivity consumes these.
    sealed interface Intent {
        /// nav.* → navigate to a phone-native screen
        data class NavigateTab(val tab: Tab) : Intent
        data class NavigateHarness(val slug: String) : Intent
        data class NavigateVoiceSettings(val unit: Unit = Unit) : Intent
        data class NavigateStandingApprovals(val unit: Unit = Unit) : Intent
        /// operator.*
        data object Pause : Intent
        data object Resume : Intent
        /// voice.*
        data object ClaimVoice : Intent
        data class VoiceSetMode(val mode: String) : Intent
        /// workspace.switch
        data class WorkspaceSwitch(val workspaceId: String) : Intent
        /// panel.* — no panel concept on phone, but the agent may invoke
        /// these reflexively; we accept + no-op so the conversation flows.

        enum class Tab { Operator, Harnesses, Activity, Settings }
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
                        // Fully tear down so a subsequent FAB tap can
                        // start a fresh session. Without this, `scope`
                        // stays non-null and `start()` short-circuits.
                        Log.i(TAG, "EL disconnected: $reason — tearing down")
                        teardown(reason = reason.toString())
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
                        Log.w(TAG, "agent invoked unhandled client tool: ${call.toolName}")
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

    fun stop() = teardown(reason = "user")

    private fun teardown(reason: String) {
        val s = scope ?: return
        scope = null
        val sess = session
        session = null
        if (sess != null) {
            // endSession() is a suspend fn; fire-and-forget on IO before
            // we cancel the scope. Skip if SDK already disconnected
            // (reason from onDisconnect callback) — calling endSession
            // on an already-dead session can hang.
            if (reason == "user") {
                CoroutineScope(Dispatchers.IO).launch {
                    try { sess.endSession() } catch (_: Throwable) {}
                }
            }
        }
        sessionJob?.cancel()
        sessionJob = null
        _micLevel.value = 0f
        // Preserve a Failed state if onError fired earlier; otherwise
        // park at Idle so the UI shows "Listen" again.
        if (_state.value !is State.Failed) _state.value = State.Idle
        s.cancel()
    }

    /// Native client-tool table covering every `browser:'required'`
    /// command from the desktop registry. The agent's tool catalog is
    /// the same across surfaces — phone implementations differ.
    /// Tools that target desktop-only surfaces (marketplace, docs, API
    /// keys, multi-workspace operator scan) return a failure with a
    /// clear "mobile" reason so the agent can apologize rather than
    /// silently doing nothing.
    private fun buildClientTools(): Map<String, ClientTool> {
        val ok = ClientToolResult.success("ok")
        fun unsupported(reason: String) =
            ClientToolResult.failure("not-supported-on-mobile: $reason")

        fun navigatePath(path: String): ClientToolResult {
            // Map desktop URLs to phone navigation. Anything unrecognized
            // is a "doesn't exist on phone" error.
            val clean = path.trim().removeSuffix("/")
            return when {
                clean == "" || clean == "/" || clean == "/harness" -> {
                    _intents.tryEmit(Intent.NavigateTab(Intent.Tab.Harnesses)); ok
                }
                clean == "/settings" -> {
                    _intents.tryEmit(Intent.NavigateTab(Intent.Tab.Settings)); ok
                }
                clean == "/settings/voice" -> {
                    _intents.tryEmit(Intent.NavigateVoiceSettings()); ok
                }
                clean.startsWith("/harness/") -> {
                    val slug = clean.removePrefix("/harness/")
                    if (slug.isBlank()) ClientToolResult.failure("empty harness slug")
                    else { _intents.tryEmit(Intent.NavigateHarness(slug)); ok }
                }
                clean == "/installed/harnesses" -> {
                    _intents.tryEmit(Intent.NavigateTab(Intent.Tab.Harnesses)); ok
                }
                clean == "/marketplace" -> unsupported("Marketplace isn't available on the phone yet")
                clean == "/docs" -> unsupported("Docs aren't available on the phone")
                clean == "/settings/api-keys" -> unsupported("API keys are desktop-only")
                clean == "/settings/shortcuts" -> unsupported("Shortcuts are desktop-only")
                else -> ClientToolResult.failure("unknown path: $path")
            }
        }

        return mapOf(
            // ── navigation ────────────────────────────────────────────
            "navigate" to clientTool { params ->
                val path = params["path"]?.toString().orEmpty()
                if (path.isBlank()) ClientToolResult.failure("missing path") else navigatePath(path)
            },
            "nav.harness" to clientTool { _ ->
                _intents.tryEmit(Intent.NavigateTab(Intent.Tab.Harnesses)); ok
            },
            "nav.settings" to clientTool { _ ->
                _intents.tryEmit(Intent.NavigateTab(Intent.Tab.Settings)); ok
            },
            "nav.settings-voice" to clientTool { _ ->
                _intents.tryEmit(Intent.NavigateVoiceSettings()); ok
            },
            "nav.installed-harnesses" to clientTool { _ ->
                _intents.tryEmit(Intent.NavigateTab(Intent.Tab.Harnesses)); ok
            },
            "nav.marketplace" to clientTool { _ -> unsupported("Marketplace isn't on the phone yet") },
            "nav.docs" to clientTool { _ -> unsupported("Docs aren't on the phone") },
            "nav.settings-api-keys" to clientTool { _ -> unsupported("API keys are desktop-only") },
            "nav.settings-shortcuts" to clientTool { _ -> unsupported("Shortcuts are desktop-only") },

            // Legacy alias from our pre-unification flow — agents may
            // still emit it; map to NavigateHarness.
            "nav.openHarness" to clientTool { params ->
                val slug = params["slug"]?.toString().orEmpty()
                if (slug.isBlank()) ClientToolResult.failure("missing slug")
                else { _intents.tryEmit(Intent.NavigateHarness(slug)); ok }
            },

            // ── operator pause / resume ──────────────────────────────
            "operator.pause" to clientTool { _ -> _intents.tryEmit(Intent.Pause); ok },
            "operator.resume" to clientTool { _ -> _intents.tryEmit(Intent.Resume); ok },
            "operator.approve-pending" to clientTool { _ ->
                _intents.tryEmit(Intent.NavigateStandingApprovals()); ok
            },
            "operator.scan" to clientTool { _ -> unsupported("Run scans from the desktop") },
            "operator.across-workspaces" to clientTool { _ -> unsupported("Cross-workspace view is desktop-only") },

            // ── voice ────────────────────────────────────────────────
            "voice.claim" to clientTool { _ -> _intents.tryEmit(Intent.ClaimVoice); ok },
            "voice.set-mode" to clientTool { params ->
                val mode = params["mode"]?.toString().orEmpty()
                if (mode.isBlank()) ClientToolResult.failure("missing mode")
                else { _intents.tryEmit(Intent.VoiceSetMode(mode)); ok }
            },

            // ── workspace ────────────────────────────────────────────
            "workspace.switch" to clientTool { params ->
                val id = params["workspaceId"]?.toString().orEmpty()
                if (id.isBlank()) ClientToolResult.failure("missing workspaceId")
                else { _intents.tryEmit(Intent.WorkspaceSwitch(id)); ok }
            },

            // ── panel.* — desktop-only concept, accept + no-op ───────
            // The desktop operator has a side panel for cards. Phone
            // surfaces cards through the Standing Approvals tab. We
            // accept the call so the agent's reflexive UI flow doesn't
            // crash, but actually route to Standing Approvals.
            "panel.open" to clientTool { _ -> _intents.tryEmit(Intent.NavigateStandingApprovals()); ok },
            "panel.close" to clientTool { _ -> ok },
            "panel.toggle" to clientTool { _ -> _intents.tryEmit(Intent.NavigateStandingApprovals()); ok },

            // ── chat pane — desktop-only, no-op ──────────────────────
            "chat.open-pane" to clientTool { _ -> ok },

            // ── delegate_to_claude — server-side from desktop; on
            //    phone we lack the chat surface; surface error ───────
            "delegate_to_claude" to clientTool { _ ->
                unsupported("Delegation isn't available from phone voice in V1")
            },
        ) + proxyTools()
    }

    /// The EL agent has ~37 client tools configured at agent-creation
    /// time. The navigation / UI-mutation set is handled natively
    /// above so taps + route changes happen sub-100ms. The remaining
    /// query+brain tools (harness_status, harness_list, ask_operator,
    /// etc.) need server-side data we don't have locally. Each one
    /// proxies through POST /api/mobile/voice-tool/{name} — operator
    /// runs runQuery/runCommand server-side and returns JSON the
    /// agent speaks. Same authority surface as the desktop client
    /// (same registry, same per-tool schemas).
    private fun proxyTools(): Map<String, ClientTool> {
        val proxiedNames = listOf(
            "ask_operator",
            "workspace_list",
            "harness_list", "harness_status", "harness_list_features",
            "harness_last_scan", "harness_recent_suggestions", "harness_health",
            "agents_across_workspace",
            "chat_list",
            "voice_prefs",
            "issues_list", "escalations_get", "pending_reviews_list",
            "actions_recent", "notifications_recent",
            "scans_list", "scans_get", "scans_search",
            "delegates_list",
        )
        return proxiedNames.associateWith { name ->
            clientTool { params ->
                runCatching { proxyVoiceTool(name, params) }
                    .map { ClientToolResult.success(it) }
                    .getOrElse { ClientToolResult.failure("proxy: ${it.message ?: it.javaClass.simpleName}") }
            }
        }
    }

    /// Synchronous HTTP from inside ClientTool.execute (already a
    /// suspend context). Posts the EL params + tool name to the
    /// operator, returns the response body as the tool result. The
    /// agent reads it back as JSON the LLM can speak from.
    private fun proxyVoiceTool(name: String, params: Map<String, Any>): String {
        val http = OkHttpClient.Builder()
            .connectTimeout(8, TimeUnit.SECONDS)
            .readTimeout(20, TimeUnit.SECONDS)
            .build()
        val bodyJson = JSONObject().apply {
            put("parameters", JSONObject(params))
        }.toString()
        val req = Request.Builder()
            .url("${creds.server}/api/mobile/voice-tool/$name")
            .header("Authorization", "Bearer ${creds.deviceToken}")
            .header("content-type", "application/json")
            .post(okhttp3.RequestBody.create(JSON_MEDIA, bodyJson))
            .build()
        http.newCall(req).execute().use { resp ->
            val text = resp.body?.string().orEmpty()
            if (!resp.isSuccessful) {
                throw RuntimeException("voice-tool $name → ${resp.code}: ${text.take(160)}")
            }
            return text
        }
    }

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
        private val JSON_MEDIA = "application/json".toMediaTypeOrNull()
    }
}
