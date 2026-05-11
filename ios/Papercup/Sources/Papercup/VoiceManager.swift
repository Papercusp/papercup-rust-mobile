// SPDX-License-Identifier: GPL-3.0-or-later
//
// Voice coordinator — V1 (ElevenLabs Conversational AI).
//
// Phone is an ElevenLabs Conv AI client of the SAME agent the desktop
// uses. Phone fetches a short-lived conversation token from
// /api/mobile/voice-session-init (operator mints via EL API key),
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
import ElevenLabs

@MainActor
final class VoiceManager: ObservableObject {
    enum State: Equatable {
        case idle
        case connecting
        case listening
        case speaking(text: String, source: String)
        case failed(message: String)
    }

    @Published private(set) var state: State = .idle
    /// 0…1 normalized agent audio level (used by the FAB halo).
    @Published private(set) var micLevel: Float = 0

    /// Single-shot intent the UI consumes via .onChange. Set to nil
    /// after handling so the next intent of the same kind still fires.
    @Published var pendingIntent: LocalIntent? = nil

    enum LocalIntent: Equatable {
        case navigate(slug: String)
        case pause
        case resume
        case claimVoice
    }

    private let creds: DeviceCredentials
    private var conversation: Conversation? = nil
    private var toolPump: Task<Void, Never>? = nil
    private var statePump: Task<Void, Never>? = nil
    private var levelPump: Task<Void, Never>? = nil

    init(creds: DeviceCredentials) {
        self.creds = creds
    }

    func start() {
        guard conversation == nil else { return }
        state = .connecting
        Task { @MainActor in
            let init_: SessionInit
            do {
                init_ = try await fetchSessionInit()
            } catch {
                state = .failed(message: "Voice unavailable — \(error.localizedDescription)")
                return
            }
            do {
                let config = ConversationConfig(
                    onAgentResponse: { [weak self] text, _ in
                        Task { @MainActor in self?.state = .speaking(text: text, source: "agent") }
                    },
                    onUserTranscript: { _, _ in /* logged by the SDK */ }
                )
                let conv = try await ElevenLabs.startConversation(
                    conversationToken: init_.conversationToken,
                    config: config
                )
                conversation = conv
                wirePumps(conv)
            } catch {
                state = .failed(message: "Voice unavailable — \(error.localizedDescription)")
            }
        }
    }

    func stop() {
        toolPump?.cancel(); toolPump = nil
        statePump?.cancel(); statePump = nil
        levelPump?.cancel(); levelPump = nil
        if let conv = conversation {
            conversation = nil
            Task { await conv.endConversation() }
        }
        micLevel = 0
        state = .idle
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
                case .error: self.state = .failed(message: "Voice error")
                }
            }
        }
        // Agent audio level for the FAB halo. The SDK exposes this on
        // the conversation as a Published Float-ish value.
        levelPump = Task { @MainActor [weak self] in
            for await level in conv.$agentAudioLevel.values {
                self?.micLevel = level
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
        switch call.toolName {
        case "nav.openHarness":
            if let slug = params["slug"] as? String, !slug.isEmpty {
                pendingIntent = .navigate(slug: slug)
                try? await conv.sendToolResult(for: call.toolCallId, result: ["ok": true])
            } else {
                try? await conv.sendToolResult(
                    for: call.toolCallId,
                    result: ["error": "missing slug"],
                    isError: true
                )
            }
        case "operator.pause":
            pendingIntent = .pause
            try? await conv.sendToolResult(for: call.toolCallId, result: ["ok": true])
        case "operator.resume":
            pendingIntent = .resume
            try? await conv.sendToolResult(for: call.toolCallId, result: ["ok": true])
        case "voice.claim":
            pendingIntent = .claimVoice
            try? await conv.sendToolResult(for: call.toolCallId, result: ["ok": true])
        default:
            // Unhandled client tools — return an error so the agent
            // knows not to retry locally; webhook-routable tools land
            // on the server, not here.
            try? await conv.sendToolResult(
                for: call.toolCallId,
                result: ["error": "unknown client tool: \(call.toolName)"],
                isError: true
            )
        }
    }

    private func fetchSessionInit() async throws -> SessionInit {
        guard let url = URL(string: "\(creds.server)/api/mobile/voice-session-init?surface=mobile-ios") else {
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
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = obj["conversationToken"] as? String,
              let agentId = obj["agentId"] as? String else {
            throw NSError(
                domain: "VoiceSessionInit",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "malformed session-init response"]
            )
        }
        let dyn = obj["dynamicVariables"] as? [String: Any] ?? [:]
        return SessionInit(
            conversationToken: token,
            agentId: agentId,
            deviceId: dyn["device_id"] as? String ?? "",
            workspaceId: dyn["workspace_id"] as? String ?? "",
            surface: dyn["surface"] as? String ?? "mobile-ios",
            desktopHost: dyn["desktop_host"] as? String ?? ""
        )
    }

    private struct SessionInit {
        let conversationToken: String
        let agentId: String
        let deviceId: String
        let workspaceId: String
        let surface: String
        let desktopHost: String
    }
}
