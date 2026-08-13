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
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
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
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONObject
import java.util.concurrent.TimeUnit

/// Voice coordinator — V1 (ElevenLabs Conversational AI).
///
/// Phone is an ElevenLabs Conv AI client of the SAME agent the desktop
/// uses. Phone fetches a short-lived conversation token from
/// `/api/device/voice-session-init` (operator mints via EL API key),
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
        data class Failed(
            val message: String,
            val kind: FailureKind = FailureKind.Unknown,
            /** Suggested retry delay in seconds; null = manual retry only. */
            val retryAfterSec: Int? = null,
        ) : State
    }

    /// Drives the per-error UX:
    ///   - MicPermission     → "Allow mic" + Open-app-settings button
    ///   - QuotaExceeded     → "EL limit hit" + Open-voice-settings link
    ///   - ConcurrentLimit   → "Another device has voice" + Pre-empt button
    ///   - MintCooldown      → "Cool-down — auto-retry in Xs" + countdown
    ///   - NetworkUnreachable→ "Lost connection — tap to retry"
    ///   - IdleTimeout       → already user-facing "tap to resume" via FAB
    ///   - SessionMax        → already user-facing "tap to start another"
    ///   - AgentEnded        → quiet — agent intentionally ended via end_conversation
    ///   - Unknown           → generic fallback toast
    enum class FailureKind {
        MicPermission,
        QuotaExceeded,
        ConcurrentLimit,
        MintCooldown,
        NetworkUnreachable,
        IdleTimeout,
        SessionMax,
        AgentEnded,
        Unknown,
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

    private val consentStore = VoicePrivacyConsentStore(context)
    private val _cloudConsentRequired = MutableStateFlow(false)
    val cloudConsentRequired: StateFlow<Boolean> = _cloudConsentRequired.asStateFlow()
    private val _cloudVoiceConsentGranted = MutableStateFlow(consentStore.isGranted())
    val cloudVoiceConsentGranted: StateFlow<Boolean> = _cloudVoiceConsentGranted.asStateFlow()

    private val _intents = MutableSharedFlow<Intent>(extraBufferCapacity = 8)
    val intents: SharedFlow<Intent> = _intents.asSharedFlow()

    private val _micLevel = MutableStateFlow(0f)
    val micLevel: StateFlow<Float> = _micLevel.asStateFlow()

    private var scope: CoroutineScope? = null
    private var session: ConversationSession? = null
    private var sessionJob: Job? = null

    /// Idle / session-max timers — bound EL Conv AI billable time on
    /// the mobile client the same way voice-mode.ts does on desktop.
    /// Values come from the server's voice-session-init response so
    /// they're always fresh (no need to refetch prefs). Idle resets on
    /// USER transcript only; session-max is set once at connect.
    private var idleTimerJob: Job? = null
    private var sessionMaxTimerJob: Job? = null
    private var idleTimeoutMs: Long = 0L
    private var sessionMaxMs: Long = 0L

    /// Performance HUD samples (Phase D). Recorded into VoiceMetrics
    /// so Settings → Voice → Performance shows P50/P95 over recent
    /// sessions. tapAtMs is the user's FAB tap; firstWordMs is the
    /// elapsed millis until the first onAgentResponse fires.
    private var tapAtMs: Long = 0L
    private var firstWordRecorded: Boolean = false

    /// WI-4967: the FAB's runtime-permission request routes its DENIAL here
    /// so the standard MicPermission failure surface (VoiceErrorBanner with
    /// its Open-Settings action + the FAB's Error style) fires. Previously a
    /// denial silently returned the UI to "Voice: Listen" with no feedback,
    /// and a permanently-denied mic could never be diagnosed in-app.
    fun reportMicPermissionDenied(permanentlyDenied: Boolean) {
        _state.value = micDenialFailure(permanentlyDenied)
    }

    fun start() {
        if (scope != null) return
        val s = CoroutineScope(SupervisorJob() + Dispatchers.Main)
        scope = s
        _state.value = State.Connecting
        // Mark the user's intent-to-listen time for first-word latency.
        // Latency = time until the first onAgentResponse fires.
        tapAtMs = System.currentTimeMillis()
        firstWordRecorded = false

        sessionJob = s.launch(Dispatchers.IO) {
            val initResult = runCatching { fetchSessionInit() }
            val anyInit = initResult.getOrElse { err ->
                Log.w(TAG, "session-init failed: ${err.message}")
                _state.value = classifyInitFailure(err)
                // Tear down so the FAB / banner Retry can start() again —
                // without this `scope` stays non-null and every later
                // start() short-circuits (dead voice FAB until app
                // restart). teardown() preserves the Failed state set
                // above.
                teardown(reason = "session-init-failed")
                return@launch
            }
            if (requiresCloudVoiceConsent(anyInit is SessionInit.El, consentStore.isGranted())) {
                _cloudConsentRequired.value = true
                teardown(reason = "cloud-consent-required")
                return@launch
            }
            // Desktop-local pipeline (free, EL-less) — dispatched by the
            // session-init `mode` (on-desktop-direct-lan-voice-2026-07-14).
            // ElevenLabs keeps the entire path below unchanged (D-010).
            if (anyInit is SessionInit.DesktopLocal) {
                startLocalSession(anyInit.init)
                return@launch
            }
            val init = anyInit as SessionInit.El
            // Stash the timer budgets so onStatusChange / onUserTranscript
            // can arm + nudge them without re-parsing the init payload.
            idleTimeoutMs = init.idleTimeoutMin.coerceAtLeast(0) * 60_000L
            sessionMaxMs = init.sessionMaxMin.coerceAtLeast(0) * 60_000L

            try {
                val config = ConversationConfig(
                    conversationToken = init.conversationToken,
                    userId = init.dynamicVariables.deviceId,
                    onConnect = { _ ->
                        Log.i(TAG, "EL connected — arming timers idle=${idleTimeoutMs}ms max=${sessionMaxMs}ms")
                        armIdleTimer()
                        armSessionMaxTimer()
                    },
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
                            ConversationStatus.ERROR -> _state.value = State.Failed(
                                "Voice error — tap to retry.",
                                FailureKind.NetworkUnreachable,
                            )
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
                        // Record first-word latency once per session.
                        if (!firstWordRecorded && tapAtMs > 0L) {
                            val elapsed = System.currentTimeMillis() - tapAtMs
                            VoiceMetrics.recordFirstWordMs(context, elapsed)
                            firstWordRecorded = true
                        }
                        // Idle = USER idle. Intentionally NOT resetting
                        // the idle timer on agent responses — matches
                        // desktop voice-mode.ts onAssistantText behavior
                        // (EL credit-burn audit fix #2). A chatty agent
                        // shouldn't keep the session billable forever.
                        _state.value = State.Speaking(response, "agent")
                    },
                    onUserTranscript = { transcript ->
                        Log.d(TAG, "user: $transcript")
                        // User said something — reset the idle clock.
                        nudgeIdleTimer()
                    },
                    onUnhandledClientToolCall = { call ->
                        Log.w(TAG, "agent invoked unhandled client tool: ${call.toolName}")
                    },
                    clientTools = buildClientTools(),
                )
                session = ConversationClient.startSession(config, context)
            } catch (t: Throwable) {
                Log.w(TAG, "EL startSession failed", t)
                val msg = t.message ?: t.javaClass.simpleName
                // EL SDK surfaces quota/concurrent errors in the message
                // body. Match conservatively — we only want to upgrade
                // to a specific kind if we're sure.
                val kind = when {
                    msg.contains("quota", ignoreCase = true) ||
                    msg.contains("limit exceeded", ignoreCase = true) ||
                    msg.contains("1011", ignoreCase = true) ||
                    msg.contains("1002", ignoreCase = true) -> FailureKind.QuotaExceeded
                    msg.contains("network", ignoreCase = true) ||
                    msg.contains("unreachable", ignoreCase = true) ||
                    msg.contains("timeout", ignoreCase = true) -> FailureKind.NetworkUnreachable
                    else -> FailureKind.Unknown
                }
                _state.value = State.Failed("Voice unavailable — $msg", kind)
            }
        }
    }

    fun stop() = teardown(reason = "user")

    fun approveCloudVoice() {
        consentStore.grant()
        _cloudVoiceConsentGranted.value = true
        _cloudConsentRequired.value = false
        start()
    }

    fun declineCloudVoice() {
        _cloudConsentRequired.value = false
        if (scope != null) teardown(reason = "cloud-consent-declined")
        _state.value = State.Idle
    }

    fun revokeCloudVoiceConsent() {
        consentStore.revoke()
        _cloudVoiceConsentGranted.value = false
        _cloudConsentRequired.value = false
        if (session != null) stop()
    }

    /// FAB tap while a session is active. Desktop-local PTT: a tap during
    /// Listening ENDS the utterance and sends the turn; any other active
    /// state cancels the turn. EL mode: always a hard stop (unchanged).
    fun tapStop() {
        val local = localSession
        if (local != null && _state.value is State.Listening) {
            local.endUtteranceAndSend()
        } else {
            stop()
        }
    }

    /// Desktop-local session (mode:'desktop-local') — see DesktopVoiceSession.
    private var localSession: DesktopVoiceSession? = null

    private fun startLocalSession(init: DesktopVoiceSession.Init) {
        val s = scope ?: return
        val session = DesktopVoiceSession(
            context = context,
            scope = s,
            creds = creds,
            init = init,
            listener = object : DesktopVoiceSession.Listener {
                override fun onState(state: State) {
                    _state.value = state
                }

                override fun onMicLevel(level: Float) {
                    _micLevel.value = level
                }

                override fun onFirstWord() {
                    if (!firstWordRecorded && tapAtMs > 0L) {
                        VoiceMetrics.recordFirstWordMs(context, System.currentTimeMillis() - tapAtMs)
                        firstWordRecorded = true
                    }
                }

                override fun onActiveRoute(route: String?) {
                    activeRouteFlow.value = route
                }

                override fun onFinished() {
                    teardown(reason = "local-turn-complete")
                }
            },
        )
        localSession = session
        session.beginCapture()
    }

    /// Arm a one-shot timeout job that fires when no user transcript
    /// has been received for `idleTimeoutMs`. Cancelled on teardown
    /// and rearmed every time the user says something. No-op when the
    /// pref is 0 (auto-disconnect disabled).
    private fun armIdleTimer() {
        idleTimerJob?.cancel()
        idleTimerJob = null
        val ms = idleTimeoutMs
        if (ms <= 0L) return
        val s = scope ?: return
        idleTimerJob = s.launch(Dispatchers.Main) {
            delay(ms)
            if (!isActive) return@launch
            val labelMin = (ms / 60_000L).coerceAtLeast(1)
            val msg = "Voice idle ${labelMin}m — tap to resume."
            Log.i(TAG, "idle timer fired: $msg")
            _state.value = State.Failed(msg, FailureKind.IdleTimeout)
            teardown(reason = "idle")
        }
    }

    /// Reset the idle timer's deadline. Called from onUserTranscript
    /// — explicitly NOT called from onAgentResponse so a chatty agent
    /// can't keep the session alive forever.
    private fun nudgeIdleTimer() {
        if (idleTimerJob != null) armIdleTimer()
    }

    /// Arm the hard session-max timer at session-start. Runs ONCE —
    /// does NOT reset on activity. Bounds worst-case billable
    /// duration regardless of how active the session is. Matches
    /// desktop voice-mode.ts armSessionMaxTimer.
    private fun armSessionMaxTimer() {
        sessionMaxTimerJob?.cancel()
        sessionMaxTimerJob = null
        val ms = sessionMaxMs
        if (ms <= 0L) return
        val s = scope ?: return
        sessionMaxTimerJob = s.launch(Dispatchers.Main) {
            delay(ms)
            if (!isActive) return@launch
            val labelMin = (ms / 60_000L).coerceAtLeast(1)
            val msg = "Voice session hit ${labelMin}m max — tap to start another."
            Log.i(TAG, "session-max fired: $msg")
            _state.value = State.Failed(msg, FailureKind.SessionMax)
            teardown(reason = "session-max")
        }
    }

    private fun teardown(reason: String) {
        val s = scope ?: return
        scope = null
        val local = localSession
        localSession = null
        local?.cancel()
        idleTimerJob?.cancel()
        idleTimerJob = null
        sessionMaxTimerJob?.cancel()
        sessionMaxTimerJob = null
        // Record session length for the Performance HUD before we
        // wipe tapAtMs. Only record when we actually connected
        // (firstWordRecorded == true) to avoid skewing the histogram
        // with aborted negotiations.
        if (firstWordRecorded && tapAtMs > 0L) {
            VoiceMetrics.recordSessionLenMs(context, System.currentTimeMillis() - tapAtMs)
        }
        tapAtMs = 0L
        firstWordRecorded = false
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
        // park at Idle so the UI shows "Listen" again. Exception:
        // agent-end is intentional (hybrid / single-utterance mode),
        // shown briefly so the user knows the agent hung up rather
        // than the user — UI consumes the Failed→Idle transition.
        if (reason == "agent-end") {
            _state.value = State.Failed(
                "Agent ended the conversation.",
                FailureKind.AgentEnded,
            )
        } else if (_state.value !is State.Failed) {
            _state.value = State.Idle
        }
        s.cancel()
    }

    /// Map a session-init Throwable to a typed Failed state. Reads
    /// status codes + response body from the message (fetchSessionInit
    /// throws with the format "session-init <code>: <body>") so we can
    /// distinguish 429 (cooldown) from 503 (concurrent) from 5xx
    /// (server) from network-level failures.
    private fun classifyInitFailure(t: Throwable): State.Failed {
        val msg = t.message ?: t.javaClass.simpleName
        return when {
            msg.contains("session-init 429") -> {
                // Body looks like: {"error":"mint_cooldown","retryAfterMs":4321,...}
                val secs = Regex(""""retryAfterMs"\s*:\s*(\d+)""")
                    .find(msg)?.groupValues?.getOrNull(1)?.toIntOrNull()
                    ?.let { (it / 1000).coerceAtLeast(1) }
                State.Failed(
                    secs?.let { "Cooling down — retry in ${it}s." }
                        ?: "Cooling down — retry in a moment.",
                    FailureKind.MintCooldown,
                    retryAfterSec = secs,
                )
            }
            msg.contains("session-init 503") &&
                (msg.contains("concurrent_limit") || msg.contains("Another tab")) ->
                State.Failed(
                    "Another device has voice. Pre-empt?",
                    FailureKind.ConcurrentLimit,
                )
            // 500/502/503/504 with no body or with PG/ECONNREFUSED markers =
            // operator desktop is offline (embedded-pg not reachable). Most
            // common cause of "server 500: unknown" the user actually sees.
            // Distinct UX from a generic transient error: user needs to
            // launch the desktop, not just retry.
            msg.contains("session-init 500") || msg.contains("session-init 502") ||
                msg.contains("session-init 504") -> {
                val looksDownstream = msg.contains("ECONNREFUSED", ignoreCase = true) ||
                    msg.contains("pg", ignoreCase = true) ||
                    msg.contains("postgres", ignoreCase = true) ||
                    msg.contains("desktop", ignoreCase = true) ||
                    msg.endsWith("unknown") || // server returned empty body
                    msg.endsWith(":") // even emptier
                if (looksDownstream)
                    State.Failed(
                        "Voice unavailable — operator desktop is offline. Launch Papercusp on your computer, then tap retry.",
                        FailureKind.NetworkUnreachable,
                    )
                else
                    State.Failed("Voice service error — tap to retry.", FailureKind.NetworkUnreachable)
            }
            msg.contains("session-init") ->
                State.Failed("Voice service error — tap to retry.", FailureKind.NetworkUnreachable)
            msg.contains("permission", ignoreCase = true) &&
                msg.contains("mic", ignoreCase = true) ->
                State.Failed("Mic permission denied.", FailureKind.MicPermission)
            else ->
                State.Failed("Voice unavailable — $msg", FailureKind.Unknown)
        }
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

        // Tool names MUST match the EL agent's tool catalog verbatim —
        // the SDK does a literal map lookup against the name the agent
        // emits, and onUnhandledClientToolCall has no return path
        // (the agent waits forever and ultimately apologizes).
        // EL normalizes to underscore-form at agent-creation time.
        return mapOf(
            // ── navigation ────────────────────────────────────────────
            "navigate" to clientTool { params ->
                val path = params["path"]?.toString().orEmpty()
                if (path.isBlank()) ClientToolResult.failure("missing path") else navigatePath(path)
            },

            // ── operator pause / resume ──────────────────────────────
            "operator_pause" to clientTool { _ -> _intents.tryEmit(Intent.Pause); ok },
            "operator_resume" to clientTool { _ -> _intents.tryEmit(Intent.Resume); ok },
            "operator_approve_pending" to clientTool { _ ->
                _intents.tryEmit(Intent.NavigateStandingApprovals()); ok
            },
            "operator_scan" to clientTool { _ -> unsupported("Run scans from the desktop") },
            "operator_across_workspaces" to clientTool { _ -> unsupported("Cross-workspace view is desktop-only") },

            // ── voice ────────────────────────────────────────────────
            "voice_claim" to clientTool { _ -> _intents.tryEmit(Intent.ClaimVoice); ok },
            "voice_set_mode" to clientTool { params ->
                val mode = params["mode"]?.toString().orEmpty()
                if (mode.isBlank()) ClientToolResult.failure("missing mode")
                else { _intents.tryEmit(Intent.VoiceSetMode(mode)); ok }
            },

            // ── workspace ────────────────────────────────────────────
            "workspace_switch" to clientTool { params ->
                val id = params["workspaceId"]?.toString().orEmpty()
                if (id.isBlank()) ClientToolResult.failure("missing workspaceId")
                else { _intents.tryEmit(Intent.WorkspaceSwitch(id)); ok }
            },

            // ── panel.* — desktop-only concept. Phone surfaces cards
            //    through the Standing Approvals tab; route panel_open /
            //    panel_toggle there. panel_cards / panel_state /
            //    panel_dispatch_card / panel_dismiss_card need server
            //    data → proxy. panel_close is a no-op. ───────────────
            "panel_open" to clientTool { _ -> _intents.tryEmit(Intent.NavigateStandingApprovals()); ok },
            "panel_close" to clientTool { _ -> ok },
            "panel_toggle" to clientTool { _ -> _intents.tryEmit(Intent.NavigateStandingApprovals()); ok },

            // ── chat pane — desktop-only, no-op ──────────────────────
            "chat_open_pane" to clientTool { _ -> ok },

            // ── delegate_to_claude — server-side from desktop; on
            //    phone we lack the chat surface; surface error ───────
            "delegate_to_claude" to clientTool { _ ->
                unsupported("Delegation isn't available from phone voice in V1")
            },

            // ── end_conversation — agent tears down session after a
            //    definitive answer in hybrid / single-utterance mode.
            //    Returns ok BEFORE tearing down so EL receives the ack.
            //    teardown() runs the same path as user tap, idle, or
            //    session-max.
            "end_conversation" to clientTool { _ ->
                // Defer the actual teardown so EL has time to receive
                // this tool result. 500ms is more than enough.
                scope?.launch {
                    delay(500)
                    teardown(reason = "agent-end")
                }
                ok
            },
        ) + proxyTools()
    }

    /// The EL agent has ~37 client tools configured at agent-creation
    /// time. The navigation / UI-mutation set is handled natively
    /// above so taps + route changes happen sub-100ms. The remaining
    /// query+brain tools (harness_status, harness_list, ask_operator,
    /// etc.) need server-side data we don't have locally. Each one
    /// proxies through POST /api/device/voice-tool/{name} — operator
    /// runs runQuery/runCommand server-side and returns JSON the
    /// agent speaks. Same authority surface as the desktop client
    /// (same registry, same per-tool schemas).
    private fun proxyTools(): Map<String, ClientTool> {
        // Mirrors every server-data tool in the EL agent's catalog.
        // Source of truth: GET /v1/convai/agents/<id>.conversation_config
        // .agent.prompt.tools — these are the names the SDK looks up
        // verbatim. Native handlers above cover the rest.
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
            "delegates_list", "delegates_get", "delegates_search",
            // panel_* that need server data — phone has no panel UI
            // but proxying gives the agent the data it'd narrate.
            "panel_cards", "panel_state",
            "panel_dispatch_card", "panel_dismiss_card",
        )
        return proxiedNames.associateWith { name ->
            clientTool { params ->
                // EL SDK invokes ClientTool.execute on the main thread.
                // OkHttp's synchronous execute() throws
                // NetworkOnMainThreadException immediately (latency ~80ms,
                // is_error=true) which the agent surfaces as "I had trouble
                // just then." Hop to IO explicitly.
                kotlinx.coroutines.withContext(Dispatchers.IO) {
                    runCatching { proxyVoiceTool(name, params) }
                        .map { ClientToolResult.success(it) }
                        .getOrElse { ClientToolResult.failure("proxy: ${it.message ?: it.javaClass.simpleName}") }
                }
            }
        }
    }

    /// Synchronous HTTP from inside ClientTool.execute (already a
    /// suspend context). Posts the EL params + tool name to the
    /// operator, returns the response body as the tool result. The
    /// agent reads it back as JSON the LLM can speak from.
    private fun proxyVoiceTool(name: String, params: Map<String, Any>): String {
        // Read timeout MUST be longer than the server-side ask_operator
        // timeout (25s) — otherwise the client errors before the server
        // returns its diagnostic fallback message. 35s is the ceiling
        // for any voice-tool round-trip; tools genuinely slower than
        // that need a different transport (job queue + poll), not a
        // synchronous EL tool call.
        val http = OkHttpClient.Builder()
            .connectTimeout(8, TimeUnit.SECONDS)
            .readTimeout(35, TimeUnit.SECONDS)
            .build()
        val bodyJson = JSONObject().apply {
            put("parameters", JSONObject(params))
        }.toString()
        val req = Request.Builder()
            .url("${creds.server}/api/device/voice-tool/$name")
            .header("Authorization", "Bearer ${creds.deviceToken}")
            .header("content-type", "application/json")
            .post(bodyJson.toRequestBody(JSON_MEDIA))
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
        // Pass device-local prefs as query params. Server resolves
        // device override > workspace default and clamps single-utterance
        // mode to idle ≤1 regardless of what we ask. Empty/zero values
        // omitted so the server falls back to PG defaults.
        val prefs = VoicePrefsStore(context).load()
        val params = buildString {
            append("?surface=mobile-android")
            append("&mode=").append(prefs.voiceMode.wire)
            if (prefs.idleTimeoutMin > 0) append("&idleMin=").append(prefs.idleTimeoutMin)
            if (prefs.sessionMaxMin > 0) append("&sessionMaxMin=").append(prefs.sessionMaxMin)
        }
        val req = Request.Builder()
            .url("${creds.server}/api/device/voice-session-init$params")
            .header("Authorization", "Bearer ${creds.deviceToken}")
            .build()
        http.newCall(req).execute().use { resp ->
            val body = resp.body?.string().orEmpty()
            if (!resp.isSuccessful) {
                error("session-init ${resp.code}: ${body.take(160)}")
            }
            val j = JSONObject(body)
            if (j.optString("mode") == "desktop-local") {
                return SessionInit.DesktopLocal(DesktopVoiceSession.Init.fromJson(j))
            }
            val dyn = j.optJSONObject("dynamicVariables") ?: JSONObject()
            return SessionInit.El(
                conversationToken = j.getString("conversationToken"),
                agentId = j.getString("agentId"),
                // Server defaults match VoicePrefs.DEFAULT — keep these
                // floors here as a belt-and-suspenders so a malformed
                // payload doesn't disable both timers silently.
                idleTimeoutMin = j.optInt("idleTimeoutMin", 2),
                sessionMaxMin = j.optInt("sessionMaxMin", 30),
                dynamicVariables = DynamicVars(
                    deviceId = dyn.optString("device_id"),
                    workspaceId = dyn.optString("workspace_id"),
                    surface = dyn.optString("surface", "mobile-android"),
                    desktopHost = dyn.optString("desktop_host", ""),
                ),
            )
        }
    }

    private sealed interface SessionInit {
        data class El(
            val conversationToken: String,
            val agentId: String,
            val idleTimeoutMin: Int,
            val sessionMaxMin: Int,
            val dynamicVariables: DynamicVars,
        ) : SessionInit

        data class DesktopLocal(val init: DesktopVoiceSession.Init) : SessionInit
    }

    private data class DynamicVars(
        val deviceId: String,
        val workspaceId: String,
        val surface: String,
        val desktopHost: String,
    )

    companion object {
        /// WI-4967: user-comprehensible copy for the two mic-denial shapes.
        /// A pure factory so unit tests can pin the UX contract: the kind
        /// routes to the banner's Open-Settings action, and the message
        /// tells the user HOW to recover without leaking raw internals.
        fun micDenialFailure(permanentlyDenied: Boolean): State.Failed =
            if (permanentlyDenied) {
                State.Failed(
                    "Microphone access is blocked for Papercup. Use Settings → " +
                        "Permissions → Microphone to allow it, then tap Listen again.",
                    FailureKind.MicPermission,
                )
            } else {
                State.Failed(
                    "Papercup needs the microphone for voice. Tap Listen again " +
                        "and choose Allow.",
                    FailureKind.MicPermission,
                )
            }

        private const val TAG = "PapercupVoice"
        private val JSON_MEDIA = "application/json".toMediaTypeOrNull()

        /// Active desktop route ("mesh · http://10.10.0.2:3070") chosen by
        /// the desktop-local transport probe (P-006). Process-wide so the
        /// Voice Settings screen can render it without plumbing.
        val activeRouteFlow = MutableStateFlow<String?>(null)
    }
}
