// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import AVFoundation

struct VoiceSettingsView: View {
    @State private var prefs: VoicePrefs = VoicePrefsStore.load()
    @State private var voices: [AVSpeechSynthesisVoice] = []
    @State private var synth = AVSpeechSynthesizer()
    @State private var probeResult: VoicePathProbeResult = .idle

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                screenHeader
                performanceSection
                voicePathDiagnosticSection
                conversationModeSection
                timersSection
                wakeWordSection
                speechRateSection
                pitchSection
                voiceSection
                actionsSection
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 112)
        }
        .papercupScreenChrome()
        .navigationTitle("Voice")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            voices = AVSpeechSynthesisVoice.speechVoices().filter {
                $0.language.hasPrefix(Locale.current.language.languageCode?.identifier ?? "en")
            }
        }
        .onChange(of: prefs) { _, new in VoicePrefsStore.save(new) }
    }

    private var screenHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Voice")
                .font(.title2.weight(.semibold))
                .foregroundStyle(PapercupTheme.text)
            Text("Tune wake word, speech rate, pitch, and voice output.")
                .font(.caption)
                .foregroundStyle(PapercupTheme.textMuted)
        }
        .padding(.vertical, 10)
    }

    private var performanceSection: some View {
        // Re-read each appear so stats reflect recent sessions.
        let firstWord = VoiceMetrics.firstWordStats()
        let sessionLen = VoiceMetrics.sessionLenStats()
        return sectionShell("Performance") {
            VStack(alignment: .leading, spacing: 8) {
                if firstWord.count == 0 && sessionLen.count == 0 {
                    Text("No samples yet. Use voice once and come back.")
                        .font(.caption)
                        .foregroundStyle(PapercupTheme.textMuted)
                } else {
                    statRow(label: "First word", stats: firstWord, formatMs: true)
                    statRow(label: "Session", stats: sessionLen, formatMs: false)
                }
                Button("Reset samples") { VoiceMetrics.reset() }
                    .font(.caption)
                    .foregroundStyle(PapercupTheme.textMuted)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }

    private func statRow(label: String, stats: VoiceMetrics.Stats, formatMs: Bool) -> some View {
        HStack {
            Text(label)
                .font(.body)
                .foregroundStyle(PapercupTheme.text)
            Spacer()
            let text = formatMs
                ? "p50 \(stats.p50)ms · p95 \(stats.p95)ms · n=\(stats.count)"
                : "p50 \(stats.p50 / 1000)s · p95 \(stats.p95 / 1000)s · n=\(stats.count)"
            Text(text)
                .font(.caption.monospaced())
                .foregroundStyle(PapercupTheme.textMuted)
        }
    }

    private var conversationModeSection: some View {
        sectionShell("Conversation mode") {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(VoiceMode.allCases, id: \.self) { mode in
                    Button {
                        prefs.voiceMode = mode
                    } label: {
                        HStack(alignment: .center, spacing: 12) {
                            Image(systemName: prefs.voiceMode == mode ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(prefs.voiceMode == mode ? PapercupTheme.accentStrong : PapercupTheme.textMuted)
                            Text(mode.label)
                                .font(.body)
                                .foregroundStyle(PapercupTheme.text)
                            Spacer()
                        }
                        .contentShape(Rectangle())
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                    }
                    .buttonStyle(.plain)
                    if mode != VoiceMode.allCases.last { dividerLine() }
                }
                dividerLine()
                Text(prefs.voiceMode.blurb)
                    .font(.caption)
                    .foregroundStyle(PapercupTheme.textMuted)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
            }
        }
    }

    private var timersSection: some View {
        sectionShell("Timers") {
            VStack(alignment: .leading, spacing: 0) {
                intInputRow(
                    label: "Auto-disconnect (min)",
                    helper: "User-silence cap. 0 uses workspace default.",
                    value: $prefs.idleTimeoutMin
                )
                dividerLine()
                intInputRow(
                    label: "Session max (min)",
                    helper: "Hard ceiling regardless of activity. 0 uses workspace default.",
                    value: $prefs.sessionMaxMin
                )
            }
        }
    }

    private func intInputRow(label: String, helper: String, value: Binding<Int>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(PapercupTheme.text)
            TextField(
                "default",
                text: Binding(
                    get: { value.wrappedValue == 0 ? "" : String(value.wrappedValue) },
                    set: { s in
                        let v = Int(s).map { max(0, min(240, $0)) } ?? 0
                        value.wrappedValue = v
                    }
                )
            )
            .keyboardType(.numberPad)
            .textInputAutocapitalization(.never)
            .font(.body)
            .foregroundStyle(PapercupTheme.text)
            Text(helper)
                .font(.caption)
                .foregroundStyle(PapercupTheme.textMuted)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var wakeWordSection: some View {
        sectionShell("Wake word") {
            VStack(alignment: .leading, spacing: 0) {
                TextField("hey operator", text: $prefs.wakeWord)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .font(.body)
                    .foregroundStyle(PapercupTheme.text)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                dividerLine()
                Text("3-syllable phrases work best — single words misfire.")
                    .font(.caption)
                    .foregroundStyle(PapercupTheme.textMuted)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
            }
        }
    }

    private var speechRateSection: some View {
        sectionShell("Speech rate") {
            rangeRow(value: $prefs.rate, range: 0.5...2.0, step: 0.05)
        }
    }

    private var pitchSection: some View {
        sectionShell("Pitch") {
            rangeRow(value: $prefs.pitch, range: 0.5...2.0, step: 0.05)
        }
    }

    private var voiceSection: some View {
        sectionShell("Voice") {
            if voices.isEmpty {
                Text("No system voices loaded.")
                    .font(.callout)
                    .foregroundStyle(PapercupTheme.textMuted)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Menu {
                    Button("System default") { prefs.voiceIdentifier = nil }
                    ForEach(voices, id: \.identifier) { voice in
                        Button("\(voice.name) (\(voice.language))") {
                            prefs.voiceIdentifier = voice.identifier
                        }
                    }
                } label: {
                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(selectedVoiceTitle)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(PapercupTheme.text)
                            Text(selectedVoiceSubtitle)
                                .font(.caption)
                                .foregroundStyle(PapercupTheme.textMuted)
                        }
                        Spacer(minLength: 12)
                        Text("›")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(PapercupTheme.textMuted)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var actionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            PapercupSectionTitle(text: "Test + reset")
            HStack(spacing: 10) {
                Button { test() } label: {
                    actionButtonLabel(
                        title: NSLocalizedString("voice.test", comment: ""),
                        fill: LinearGradient(
                            colors: [PapercupTheme.accentStrong.opacity(0.96), PapercupTheme.accent.opacity(0.82)],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        foreground: PapercupTheme.ink
                    )
                }
                .buttonStyle(.plain)

                Button { prefs = VoicePrefs() } label: {
                    actionButtonLabel(
                        title: NSLocalizedString("voice.reset", comment: ""),
                        fill: LinearGradient(
                            colors: [Color.white.opacity(0.08), Color.white.opacity(0.03)],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        foreground: PapercupTheme.text
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var selectedVoiceTitle: String {
        guard let id = prefs.voiceIdentifier,
              let voice = voices.first(where: { $0.identifier == id }) else {
            return "System default"
        }
        return voice.name
    }

    private var selectedVoiceSubtitle: String {
        guard let id = prefs.voiceIdentifier,
              let voice = voices.first(where: { $0.identifier == id }) else {
            return "Use the iPhone default voice."
        }
        return voice.language
    }

    private func sectionShell<Content: View>(_ title: String, accent: Color = PapercupTheme.accent.opacity(0.10), @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            PapercupSectionTitle(text: title)
            VStack(spacing: 0) {
                content()
            }
            .background(PapercupTheme.cardBackground(accent: accent))
        }
    }

    private func dividerLine() -> some View {
        Rectangle()
            .fill(PapercupTheme.stroke.opacity(0.28))
            .frame(height: 1)
            .padding(.horizontal, 16)
    }

    private func rangeRow(value: Binding<Float>, range: ClosedRange<Float>, step: Float) -> some View {
        HStack(spacing: 14) {
            Slider(
                value: Binding(
                    get: { Double(value.wrappedValue) },
                    set: { value.wrappedValue = Float($0) }
                ),
                in: Double(range.lowerBound)...Double(range.upperBound),
                step: Double(step)
            )
            .tint(PapercupTheme.accent)

            Text(String(format: "%.2f", value.wrappedValue))
                .font(.caption.monospaced())
                .foregroundStyle(PapercupTheme.text)
                .frame(width: 44, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private func actionButtonLabel(title: String, fill: LinearGradient, foreground: Color) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(foreground)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(fill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(PapercupTheme.stroke.opacity(0.65), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.24), radius: 10, x: 0, y: 6)
    }

    private func test() {
        let utt = AVSpeechUtterance(string: "Operator mobile voice test, one two three.")
        utt.rate = prefs.rate * AVSpeechUtteranceDefaultSpeechRate
        utt.pitchMultiplier = prefs.pitch
        if let id = prefs.voiceIdentifier, let v = voices.first(where: { $0.identifier == id }) {
            utt.voice = v
        }
        synth.stopSpeaking(at: .immediate)
        synth.speak(utt)
    }

    /// End-to-end probe — heartbeat + voice-session-init. Doesn't
    /// burn EL minutes. Helps users distinguish pair/server/EL faults.
    private var voicePathDiagnosticSection: some View {
        sectionShell("Voice path diagnostic") {
            VStack(alignment: .leading, spacing: 8) {
                Group {
                    switch probeResult {
                    case .idle:
                        Text("Runs a no-mint probe against heartbeat + session-init. Doesn't burn EL minutes.")
                            .font(.caption)
                            .foregroundStyle(PapercupTheme.textMuted)
                    case .running:
                        HStack(spacing: 8) {
                            ProgressView().scaleEffect(0.7)
                            Text("Probing…").font(.caption)
                        }
                    case .success(let hbMs, let initMs):
                        VStack(alignment: .leading, spacing: 4) {
                            Text("✓ all good").foregroundStyle(.green).font(.callout)
                            Text("heartbeat \(hbMs)ms · session-init \(initMs)ms")
                                .font(.caption).monospaced()
                                .foregroundStyle(PapercupTheme.textMuted)
                        }
                    case .failure(let stage, let detail):
                        VStack(alignment: .leading, spacing: 4) {
                            Text("✗ \(stage)").foregroundStyle(.red).font(.callout)
                            Text(detail).font(.caption).monospaced()
                                .foregroundStyle(.red.opacity(0.85))
                        }
                    }
                }
                Button(action: { Task { await runProbe() } }) {
                    Text(probeResult == .idle ? "Run probe" : "Run again")
                }
                .disabled(probeResult == .running)
            }
        }
    }

    @MainActor
    private func runProbe() async {
        probeResult = .running
        probeResult = await VoicePathProbe.run()
    }
}

enum VoicePathProbeResult: Equatable {
    case idle
    case running
    case success(heartbeatMs: Int, sessionInitMs: Int)
    case failure(stage: String, detail: String)
}

private enum VoicePathProbe {
    static func run() async -> VoicePathProbeResult {
        guard let creds = CredentialStore.load() else {
            return .failure(stage: "not paired", detail: "Pair this device first via the operator desktop.")
        }
        let session = URLSession(configuration: .ephemeral)

        // Heartbeat
        let hbStart = Date()
        guard let hbUrl = URL(string: "\(creds.server)/api/mobile/heartbeat") else {
            return .failure(stage: "bad server url", detail: creds.server)
        }
        var hbReq = URLRequest(url: hbUrl, timeoutInterval: 15)
        hbReq.httpMethod = "POST"
        hbReq.setValue("Bearer \(creds.deviceToken)", forHTTPHeaderField: "Authorization")
        hbReq.setValue("application/json", forHTTPHeaderField: "content-type")
        hbReq.httpBody = Data("{}".utf8)
        let hbCode: Int
        do {
            let (data, resp) = try await session.data(for: hbReq)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            hbCode = code
            if !(200...299).contains(code) {
                let body = String(data: data.prefix(120), encoding: .utf8) ?? ""
                if code == 401 {
                    return .failure(stage: "heartbeat 401", detail: "Token rejected — re-pair the device.")
                }
                return .failure(stage: "heartbeat \(code)", detail: body)
            }
        } catch {
            return .failure(
                stage: "heartbeat unreachable",
                detail: "Couldn't reach \(creds.server). Check Wi-Fi, Cloudflare tunnel, and that operator desktop is running."
            )
        }
        let heartbeatMs = Int(Date().timeIntervalSince(hbStart) * 1000)
        _ = hbCode

        // Session init
        let initStart = Date()
        guard let initUrl = URL(string: "\(creds.server)/api/mobile/voice-session-init?surface=mobile-ios&mode=continuous&probe=1") else {
            return .failure(stage: "bad server url", detail: creds.server)
        }
        var initReq = URLRequest(url: initUrl, timeoutInterval: 15)
        initReq.setValue("Bearer \(creds.deviceToken)", forHTTPHeaderField: "Authorization")
        do {
            let (data, resp) = try await session.data(for: initReq)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let body = String(data: data.prefix(120), encoding: .utf8) ?? ""
            switch code {
            case 200...299: break
            case 429: return .failure(stage: "cooldown", detail: "EL mint cooldown — wait a few seconds and rerun.")
            case 503 where body.contains("concurrent_limit"):
                return .failure(stage: "another device has voice", detail: "Close other voice sessions or pre-empt from the FAB.")
            case 404:
                return .failure(stage: "EL not configured", detail: "Open /settings/voice on the desktop and set the agent + API key.")
            case 500...599:
                return .failure(stage: "operator brain offline", detail: "\(creds.server) returned \(code). Launch Papercup on your computer.")
            default:
                return .failure(stage: "session-init \(code)", detail: body)
            }
        } catch {
            return .failure(stage: "session-init unreachable", detail: "\(error.localizedDescription)")
        }
        let initMs = Int(Date().timeIntervalSince(initStart) * 1000)

        return .success(heartbeatMs: heartbeatMs, sessionInitMs: initMs)
    }
}
