// SPDX-License-Identifier: GPL-3.0-or-later
//
// Voice coordinator — V1 (ElevenLabs Conversational AI).
//
// Phone is an ElevenLabs Conv AI client of the SAME agent the desktop
// uses. Phone fetches a short-lived conversation token from
// /api/device/voice-session-init (operator mints via EL API key),
// then starts a WebRTC session via ElevenLabsSDK. All STT/TTS/VAD/AEC
// happen on the EL side. Tools the agent calls fall into:
//   • browser:'required' → invoked here via the SDK's pendingToolCalls
//     stream, mapped to native UI actions (navigate, pause, etc.)
//   • browser:'none'/'optional' → webhook → operator runCommand()
//     server-side; no phone involvement
//
// State surface preserved across the WSS → EL migration so the rest
// of the app didn't have to change: state / pendingIntent / micLevel
// / start() / stop().

import Foundation
import PapercupCore
import ElevenLabs

@MainActor
final class VoiceManager: ObservableObject {
    enum State: Equatable {
        case idle
        case connecting
        case listening
        case speaking(text: String, source: String)
        case failed(message: String, kind: FailureKind = .unknown, retryAfterSec: Int? = nil)
    }

    /// Drives the per-error UX:
    ///   - micPermission     → "Allow mic" + Open-Settings button
    ///   - quotaExceeded     → "EL limit hit" + link
    ///   - concurrentLimit   → "Another device has voice" + Pre-empt
    ///   - mintCooldown      → "Cool-down — auto-retry in Xs"
    ///   - networkUnreachable→ "Lost connection — tap to retry"
    ///   - idleTimeout       → user-facing "tap to resume" via FAB
    ///   - sessionMax        → user-facing "tap to start another"
    ///   - agentEnded        → quiet — agent ended via end_conversation
    ///   - unknown           → generic fallback
    enum FailureKind: Equatable {
        case micPermission
        case quotaExceeded
        case concurrentLimit
        case mintCooldown
        case networkUnreachable
        case idleTimeout
        case sessionMax
        case agentEnded
        case unknown
    }

    @Published private(set) var state: State = .idle
    /// True only while an ElevenLabs token is held but no microphone data
    /// has been sent. The UI must resolve this explicit consent gate before
    /// `ElevenLabs.startConversation` can run.
    @Published private(set) var cloudConsentRequired = false
    /// 0…1 normalized agent audio level (used by the FAB halo).
    @Published private(set) var micLevel: Float = 0

    /// Single-shot intent the UI consumes via .onChange. Set to nil
    /// after handling so the next intent of the same kind still fires.
    @Published var pendingIntent: LocalIntent? = nil

    enum Tab: Equatable { case operatorTab, harnesses, activity, settings }

    enum LocalIntent: Equatable {
        case navigateTab(Tab)
        case navigateHarness(slug: String)
        case navigateVoiceSettings
        case navigateStandingApprovals
        case pause
        case resume
        case claimVoice
        case voiceSetMode(String)
        case workspaceSwitch(workspaceId: String)
    }

    private let creds: DeviceCredentials
    private var conversation: Conversation? = nil
    private var pendingCloudInit: SessionInit? = nil
    private var toolPump: Task<Void, Never>? = nil
    private var statePump: Task<Void, Never>? = nil
    private var levelPump: Task<Void, Never>? = nil

    /// Idle / session-max timers — bound EL Conv AI billable time on
    /// the mobile client the same way voice-mode.ts does on desktop
    /// and VoiceManager.kt does on Android. Values come from the
    /// server's voice-session-init response (idleTimeoutMin /
    /// sessionMaxMin) so they track operator_voice_prefs centrally.
    /// Idle resets on USER transcript only; session-max is set once
    /// at session-start and never reset.
    private var idleTimerTask: Task<Void, Never>? = nil
    private var sessionMaxTimerTask: Task<Void, Never>? = nil
    private var idleTimeoutSecs: TimeInterval = 0
    private var sessionMaxSecs: TimeInterval = 0

    /// Performance HUD samples (Phase D). tapAtMs is the user's
    /// intent-to-listen wall-clock time. firstWordRecorded gates the
    /// "first onAgentResponse since start()" measurement so each
    /// session contributes one sample.
    private var tapAt: Date? = nil
    private var firstWordRecorded: Bool = false

    init(creds: DeviceCredentials) {
        self.creds = creds
    }

    func start() {
        guard conversation == nil, localSession == nil, pendingCloudInit == nil else { return }
        switch state {
        case .connecting, .listening, .speaking: return
        case .idle, .failed: break
        }
        state = .connecting
        tapAt = Date()
        firstWordRecorded = false
        Task { @MainActor in
            let initResult: SessionInitResult
            do {
                initResult = try await fetchSessionInit()
            } catch {
                state = Self.classifyInitFailure(error)
                return
            }
            // Desktop-local pipeline (free, EL-less) — dispatched by the
            // session-init `mode` (on-desktop-direct-lan-voice-2026-07-14).
            // ElevenLabs keeps the entire path below unchanged (D-010).
            if case .desktopLocal(let payload) = initResult {
                startLocalSession(payload)
                return
            }
            guard case .el(let init_) = initResult else { return }
            if VoicePrivacyConsentStore.isGranted() {
                await connectCloudVoice(init_)
            } else {
                // Do not start the SDK until the user has explicitly allowed
                // this third-party data transfer. Holding the short-lived
                // token does not transmit microphone audio.
                pendingCloudInit = init_
                cloudConsentRequired = true
                state = .idle
            }
        }
    }

    func approveCloudVoice() {
        guard let init_ = pendingCloudInit else { return }
        VoicePrivacyConsentStore.grant()
        pendingCloudInit = nil
        cloudConsentRequired = false
        state = .connecting
        Task { @MainActor in await connectCloudVoice(init_) }
    }

    func declineCloudVoice() {
        pendingCloudInit = nil
        cloudConsentRequired = false
        tapAt = nil
        firstWordRecorded = false
        state = .idle
    }

    func revokeCloudVoiceConsent() {
        VoicePrivacyConsentStore.revoke()
        stop()
    }

    private func connectCloudVoice(_ init_: SessionInit) async {
        idleTimeoutSecs = max(0, TimeInterval(init_.idleTimeoutMin) * 60)
        sessionMaxSecs = max(0, TimeInterval(init_.sessionMaxMin) * 60)
        do {
            let config = ConversationConfig(
                onAgentResponse: { [weak self] text, _ in
                    // Idle = USER idle. Intentionally NOT calling
                    // nudgeIdleTimer here — matches desktop
                    // voice-mode.ts onAssistantText behavior (EL
                    // credit-burn audit fix #2). A chatty agent
                    // shouldn't keep the session billable forever.
                    Task { @MainActor in
                        guard let self else { return }
                        if !self.firstWordRecorded, let t = self.tapAt {
                            let ms = Int(Date().timeIntervalSince(t) * 1000)
                            VoiceMetrics.recordFirstWordMs(ms)
                            self.firstWordRecorded = true
                        }
                        self.state = .speaking(text: text, source: "agent")
                    }
                },
                onUserTranscript: { [weak self] _, _ in
                    // User said something — reset the idle clock.
                    Task { @MainActor in self?.nudgeIdleTimer() }
                }
            )
            let conv = try await ElevenLabs.startConversation(
                conversationToken: init_.conversationToken,
                config: config
            )
            conversation = conv
            // Connected — arm both timers. Mirrors Android
            // VoiceManager.onConnect which arms after the EL SDK
            // surfaces a CONNECTED status.
            armIdleTimer()
            armSessionMaxTimer()
            wirePumps(conv)
        } catch {
            let msg = error.localizedDescription
            let kind: FailureKind = {
                let lower = msg.lowercased()
                if lower.contains("quota") || lower.contains("limit exceeded")
                    || lower.contains("1011") || lower.contains("1002") {
                    return .quotaExceeded
                }
                if lower.contains("network") || lower.contains("unreachable")
                    || lower.contains("timeout") {
                    return .networkUnreachable
                }
                return .unknown
            }()
            state = .failed(message: "Voice unavailable — \(msg)", kind: kind)
        }
    }

    func stop() {
        pendingCloudInit = nil
        cloudConsentRequired = false
        if let local = localSession {
            localSession = nil
            local.cancel()
        }
        toolPump?.cancel(); toolPump = nil
        statePump?.cancel(); statePump = nil
        levelPump?.cancel(); levelPump = nil
        idleTimerTask?.cancel(); idleTimerTask = nil
        sessionMaxTimerTask?.cancel(); sessionMaxTimerTask = nil
        // Record session length for the HUD before wiping tapAt.
        // Only record when we actually connected (firstWordRecorded)
        // so aborted negotiations don't skew the histogram.
        if firstWordRecorded, let t = tapAt {
            VoiceMetrics.recordSessionLenMs(Int(Date().timeIntervalSince(t) * 1000))
        }
        tapAt = nil
        firstWordRecorded = false
        if let conv = conversation {
            conversation = nil
            Task { await conv.endConversation() }
        }
        micLevel = 0
        state = .idle
    }

    /// FAB tap while a session is active. Desktop-local PTT: a tap during
    /// .listening ENDS the utterance and sends the turn; any other active
    /// state cancels the turn. EL mode: always a hard stop (unchanged).
    func tapStop() {
        if let local = localSession, case .listening = state {
            local.endUtteranceAndSend()
        } else {
            stop()
        }
    }

    /// Desktop-local session (mode:'desktop-local') — see DesktopVoiceSession.
    private var localSession: DesktopVoiceSession? = nil

    private func startLocalSession(_ payload: DesktopVoiceSession.InitPayload) {
        let session = DesktopVoiceSession(
            creds: creds,
            payload: payload,
            callbacks: .init(
                onState: { [weak self] s in
                    Task { @MainActor in self?.state = s }
                },
                onMicLevel: { [weak self] level in
                    Task { @MainActor in self?.micLevel = level }
                },
                onFirstWord: { [weak self] in
                    Task { @MainActor in
                        guard let self, !self.firstWordRecorded, let t = self.tapAt else { return }
                        VoiceMetrics.recordFirstWordMs(Int(Date().timeIntervalSince(t) * 1000))
                        self.firstWordRecorded = true
                    }
                },
                onActiveRoute: { route in
                    Task { @MainActor in DesktopRouteStatus.shared.route = route }
                },
                onFinished: { [weak self] in
                    Task { @MainActor in self?.finishLocalSession() }
                }
            )
        )
        localSession = session
        session.beginCapture()
    }

    private func finishLocalSession() {
        guard localSession != nil else { return }
        localSession = nil
        if firstWordRecorded, let t = tapAt {
            VoiceMetrics.recordSessionLenMs(Int(Date().timeIntervalSince(t) * 1000))
        }
        tapAt = nil
        firstWordRecorded = false
        micLevel = 0
        // A .failed the session set survives; .idle was already emitted.
    }

    /// Arm a one-shot timeout that fires when no user transcript has
    /// been received for `idleTimeoutSecs`. Cancelled on stop() and
    /// rearmed every time the user says something. No-op when the
    /// pref is 0 (auto-disconnect disabled).
    /// Map a session-init Throwable to a typed Failed state. The
    /// fetchSessionInit throws NSError with `code` set to the HTTP
    /// status code and `userInfo[NSLocalizedDescriptionKey]` set to
    /// `"session-init <code>: <body>"`. We pattern-match on both to
    /// distinguish 429 (cooldown) from 503 (concurrent) from network
    /// failures.
    private static func classifyInitFailure(_ error: Error) -> State {
        let ns = error as NSError
        let msg = ns.localizedDescription
        let code = ns.code
        switch code {
        case 429:
            // Body looks like: {"error":"mint_cooldown","retryAfterMs":4321,...}
            let secs: Int? = {
                if let r = msg.range(of: #""retryAfterMs"\s*:\s*(\d+)"#, options: .regularExpression) {
                    let n = msg[r].components(separatedBy: ":").last?.trimmingCharacters(in: .whitespacesAndNewlines)
                    return Int(n ?? "").map { max(1, $0 / 1000) }
                }
                return nil
            }()
            return .failed(
                message: secs.map { "Cooling down — retry in \($0)s." } ?? "Cooling down — retry in a moment.",
                kind: .mintCooldown,
                retryAfterSec: secs
            )
        case 503:
            if msg.contains("concurrent_limit") || msg.contains("Another tab") {
                return .failed(message: "Another device has voice. Pre-empt?", kind: .concurrentLimit)
            }
            return .failed(message: "Voice service error — tap to retry.", kind: .networkUnreachable)
        case 500, 502, 504:
            // 5xx with no body or with downstream markers = operator
            // desktop is offline (embedded-pg unreachable). Distinct
            // UX from a generic transient: user needs to launch
            // desktop, not just retry.
            let lower = msg.lowercased()
            let looksDownstream = lower.contains("econnrefused") ||
                lower.contains("postgres") || lower.contains("pg ") ||
                lower.contains("desktop") ||
                lower.hasSuffix("unknown") || lower.hasSuffix(":")
            if looksDownstream {
                return .failed(
                    message: "Voice unavailable — operator desktop is offline. Launch Papercusp on your computer, then tap retry.",
                    kind: .networkUnreachable
                )
            }
            return .failed(message: "Voice service error — tap to retry.", kind: .networkUnreachable)
        default:
            let lower = msg.lowercased()
            if lower.contains("permission") && lower.contains("mic") {
                return .failed(message: "Mic permission denied.", kind: .micPermission)
            }
            if lower.contains("session-init") {
                return .failed(message: "Voice service error — tap to retry.", kind: .networkUnreachable)
            }
            return .failed(message: "Voice unavailable — \(msg)", kind: .unknown)
        }
    }

    private func armIdleTimer() {
        idleTimerTask?.cancel()
        idleTimerTask = nil
        let secs = idleTimeoutSecs
        guard secs > 0 else { return }
        idleTimerTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(secs * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            let labelMin = max(1, Int(secs / 60))
            self.state = .failed(message: "Voice idle \(labelMin)m — tap to resume.", kind: .idleTimeout)
            self.tearDownAfterTimer()
        }
    }

    /// Reset the idle timer's deadline. Called from onUserTranscript
    /// — explicitly NOT called from onAgentResponse so a chatty agent
    /// can't keep the session alive forever.
    private func nudgeIdleTimer() {
        if idleTimerTask != nil { armIdleTimer() }
    }

    /// Arm the hard session-max timer at session-start. Runs ONCE —
    /// does NOT reset on activity. Bounds worst-case billable
    /// duration regardless of how active the session is.
    private func armSessionMaxTimer() {
        sessionMaxTimerTask?.cancel()
        sessionMaxTimerTask = nil
        let secs = sessionMaxSecs
        guard secs > 0 else { return }
        sessionMaxTimerTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(secs * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            let labelMin = max(1, Int(secs / 60))
            self.state = .failed(message: "Voice session hit \(labelMin)m max — tap to start another.", kind: .sessionMax)
            self.tearDownAfterTimer()
        }
    }

    /// Internal teardown variant used by the timers — preserves the
    /// .failed state set by the caller so the UI can surface the
    /// reason. Otherwise identical to stop().
    private func tearDownAfterTimer() {
        toolPump?.cancel(); toolPump = nil
        statePump?.cancel(); statePump = nil
        levelPump?.cancel(); levelPump = nil
        idleTimerTask?.cancel(); idleTimerTask = nil
        sessionMaxTimerTask?.cancel(); sessionMaxTimerTask = nil
        if let conv = conversation {
            conversation = nil
            Task { await conv.endConversation() }
        }
        micLevel = 0
    }

    private func wirePumps(_ conv: Conversation) {
        // State changes drive our coarse-grained State enum.
        statePump = Task { @MainActor [weak self] in
            for await s in conv.$state.values {
                guard let self else { return }
                switch s {
                case .idle: self.state = .idle
                case .connecting: self.state = .connecting
                case .active: if case .speaking = self.state {} else { self.state = .listening }
                case .ended:
                    if case .failed = self.state {} else { self.state = .idle }
                case .error: self.state = .failed(message: "Voice error — tap to retry.", kind: .networkUnreachable)
                }
            }
        }
        // Agent audio "level" for the FAB halo. ElevenLabs Swift SDK
        // 3.1+ dropped $agentAudioLevel in favor of a coarse $agentState
        // enum (listening / speaking). We translate state → level so
        // the existing UI keeps animating: full glow while the agent
        // speaks, half while listening, zero when idle. Imperfect but
        // visually equivalent for FAB feedback.
        levelPump = Task { @MainActor [weak self] in
            for await s in conv.$agentState.values {
                guard let self else { return }
                switch s {
                case .speaking: self.micLevel = 1.0
                case .listening: self.micLevel = 0.4
                @unknown default: self.micLevel = 0.0
                }
            }
        }
        // Client-tool dispatch. EL calls these for browser:'required'
        // commands. We translate the call into a local intent and emit;
        // the rest of the app picks it up via .onChange(of: pendingIntent).
        toolPump = Task { @MainActor [weak self] in
            for await calls in conv.$pendingToolCalls.values {
                for call in calls { await self?.handleToolCall(call, conv: conv) }
            }
        }
    }

    private func handleToolCall(_ call: ClientToolCallEvent, conv: Conversation) async {
        let params = (try? call.getParameters()) ?? [:]
        let toolId = call.toolCallId
        func ok() async { try? await conv.sendToolResult(for: toolId, result: ["ok": true]) }
        func fail(_ msg: String) async {
            try? await conv.sendToolResult(for: toolId, result: ["error": msg], isError: true)
        }
        func unsupported(_ reason: String) async {
            await fail("not-supported-on-mobile: \(reason)")
        }

        switch call.toolName {
        // ── navigation ────────────────────────────────────────────────
        case "navigate":
            let path = (params["path"] as? String) ?? ""
            let clean = path.trimmingCharacters(in: .whitespaces)
                            .replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
            switch clean {
            case "", "/", "/harness", "/installed/harnesses":
                pendingIntent = .navigateTab(.harnesses); await ok()
            case "/settings":
                pendingIntent = .navigateTab(.settings); await ok()
            case "/settings/voice":
                pendingIntent = .navigateVoiceSettings; await ok()
            case "/marketplace": await unsupported("Marketplace isn't on the phone yet")
            case "/docs": await unsupported("Docs aren't on the phone")
            case "/settings/api-keys": await unsupported("API keys are desktop-only")
            case "/settings/shortcuts": await unsupported("Shortcuts are desktop-only")
            default:
                if clean.hasPrefix("/harness/") {
                    let slug = String(clean.dropFirst("/harness/".count))
                    if slug.isEmpty { await fail("empty harness slug") }
                    else { pendingIntent = .navigateHarness(slug: slug); await ok() }
                } else { await fail("unknown path: \(path)") }
            }
        // ── operator pause / resume / scan ───────────────────────────
        case "operator_pause": pendingIntent = .pause; await ok()
        case "operator_resume": pendingIntent = .resume; await ok()
        case "operator_approve_pending":
            pendingIntent = .navigateStandingApprovals; await ok()
        case "operator_scan": await unsupported("Run scans from the desktop")
        case "operator_across_workspaces": await unsupported("Cross-workspace view is desktop-only")

        // ── voice ────────────────────────────────────────────────────
        case "voice_claim": pendingIntent = .claimVoice; await ok()
        case "voice_set_mode":
            let mode = (params["mode"] as? String) ?? ""
            if mode.isEmpty { await fail("missing mode") }
            else { pendingIntent = .voiceSetMode(mode); await ok() }

        // ── workspace ────────────────────────────────────────────────
        case "workspace_switch":
            let wid = (params["workspaceId"] as? String) ?? ""
            if wid.isEmpty { await fail("missing workspaceId") }
            else { pendingIntent = .workspaceSwitch(workspaceId: wid); await ok() }

        // ── panel.* — phone has no panel UI; route open/toggle to
        //    the Standing Approvals tab, no-op close, proxy the
        //    data-returning ones (cards/state/dispatch/dismiss). ────
        case "panel_open", "panel_toggle":
            pendingIntent = .navigateStandingApprovals; await ok()
        case "panel_close":
            await ok()

        // ── chat / delegate — desktop-only, accept for the flow ──────
        case "chat_open_pane": await ok()
        case "delegate_to_claude":
            await unsupported("Delegation isn't available from phone voice in V1")

        // ── end_conversation — agent ends session in hybrid /
        //    single-utterance mode. Ack EL first, then tear down
        //    after a short delay so the result lands.
        case "end_conversation":
            await ok()
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 500_000_000)
                self?.stop()
                // Surface so the UI knows the agent ended the session
                // rather than the user tapping stop. UI auto-dismisses
                // after 2s (mirrors Android VoiceErrorBanner behavior).
                self?.state = .failed(message: "Agent ended the conversation.", kind: .agentEnded)
            }

        default:
            // Every remaining EL-registered tool (~26: harness_*,
            // ask_operator, agents_across_workspace, chat_list,
            // voice_prefs, issues_list, escalations_get,
            // pending_reviews_list, actions_recent, notifications_recent,
            // scans_*, delegates_*, panel_cards/state/dispatch/dismiss,
            // workspace_list) is server data — proxy through
            // /api/device/voice-tool/<name>. Same registry, same auth,
            // same shape as desktop. Server has special handling for
            // ask_operator (drains operator-converse SSE). The SDK
            // invokes us on the main actor; URLSession.shared.data is
            // already async, so no NetworkOnMainThreadException risk
            // like Android.
            await proxyTool(call.toolName, params: params, toolId: toolId, conv: conv)
        }
    }

    /// Forward an unhandled-on-phone tool call to the operator's
    /// /api/device/voice-tool/<name> proxy and surface the response
    /// back to ElevenLabs. Mirrors the Android proxy flow but uses
    /// async URLSession — no thread hop needed.
    private func proxyTool(_ name: String, params: [String: Any], toolId: String, conv: Conversation) async {
        do {
            guard let url = URL(string: "\(creds.server)/api/device/voice-tool/\(name)") else {
                try? await conv.sendToolResult(for: toolId, result: ["error": "bad-url"], isError: true)
                return
            }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("Bearer \(creds.deviceToken)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "content-type")
            // Must outlive server-side ask_operator timeout (25s) so we
            // receive the server's diagnostic fallback message rather
            // than timing out client-side.
            req.timeoutInterval = 35
            req.httpBody = try JSONSerialization.data(
                withJSONObject: ["parameters": params]
            )
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let body = String(data: data, encoding: .utf8) ?? ""
            if !(200..<300).contains(code) {
                try? await conv.sendToolResult(
                    for: toolId,
                    result: ["error": "proxy \(name) \(code): \(body.prefix(160))"],
                    isError: true
                )
                return
            }
            // Body is the JSON the registry tool / ask_operator returned —
            // forward verbatim wrapped as the tool result. EL agents read
            // this back through their LLM, so plain string or JSON both
            // work — passing the raw text keeps the wire format identical
            // to what desktop already feeds them.
            try? await conv.sendToolResult(for: toolId, result: ["value": body])
        } catch {
            try? await conv.sendToolResult(
                for: toolId,
                result: ["error": "proxy: \(error.localizedDescription)"],
                isError: true
            )
        }
    }

    private func fetchSessionInit() async throws -> SessionInitResult {
        // Pass device-local prefs as query params. Server resolves
        // device override > workspace default and clamps single-utterance
        // mode to idle ≤1 regardless of what we ask. Zero values are
        // omitted so the server's PG default applies.
        let prefs = VoicePrefsStore.load()
        var params = "?surface=mobile-ios&mode=\(prefs.voiceMode.rawValue)"
        if prefs.idleTimeoutMin > 0 { params += "&idleMin=\(prefs.idleTimeoutMin)" }
        if prefs.sessionMaxMin > 0 { params += "&sessionMaxMin=\(prefs.sessionMaxMin)" }
        guard let url = URL(string: "\(creds.server)/api/device/voice-session-init\(params)") else {
            throw URLError(.badURL)
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Bearer \(creds.deviceToken)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 8
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let body = String(data: data, encoding: .utf8) ?? ""
            throw NSError(
                domain: "VoiceSessionInit",
                code: code,
                userInfo: [NSLocalizedDescriptionKey: "session-init \(code): \(body.prefix(160))"]
            )
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(
                domain: "VoiceSessionInit",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "malformed session-init response"]
            )
        }
        // Desktop-local pipeline (free, EL-less; D-010 keeps EL beside it).
        if (obj["mode"] as? String) == "desktop-local" {
            return .desktopLocal(DesktopVoiceSession.InitPayload.from(json: obj))
        }
        guard let token = obj["conversationToken"] as? String,
              let agentId = obj["agentId"] as? String else {
            throw NSError(
                domain: "VoiceSessionInit",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "malformed session-init response"]
            )
        }
        let dyn = obj["dynamicVariables"] as? [String: Any] ?? [:]
        // Server defaults match VoicePrefs.DEFAULT — keep these floors
        // here as belt-and-suspenders so a malformed payload doesn't
        // disable both timers silently.
        let idleMin = (obj["idleTimeoutMin"] as? Int) ?? 2
        let maxMin = (obj["sessionMaxMin"] as? Int) ?? 30
        return .el(SessionInit(
            conversationToken: token,
            agentId: agentId,
            idleTimeoutMin: idleMin,
            sessionMaxMin: maxMin,
            deviceId: dyn["device_id"] as? String ?? "",
            workspaceId: dyn["workspace_id"] as? String ?? "",
            surface: dyn["surface"] as? String ?? "mobile-ios",
            desktopHost: dyn["desktop_host"] as? String ?? ""
        ))
    }

    private struct SessionInit {
        let conversationToken: String
        let agentId: String
        let idleTimeoutMin: Int
        let sessionMaxMin: Int
        let deviceId: String
        let workspaceId: String
        let surface: String
        let desktopHost: String
    }

    private enum SessionInitResult {
        case el(SessionInit)
        case desktopLocal(DesktopVoiceSession.InitPayload)
    }
}
