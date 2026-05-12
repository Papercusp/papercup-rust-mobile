// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import os.log

/// Mirrors Android's PairedShell — Tauri-style tab nav (Operator /
/// Harness / Running / Inbox / Settings) plus pushed routes.
struct AppRoot: View {
    @State private var creds: DeviceCredentials? = CredentialStore.load()
    @State private var liveTick: Int = 0
    @State private var lastInvalidate: String? = nil
    @State private var pushedDetailSlug: String? = nil
    @State private var pushedRunLogSlug: String? = nil
    @EnvironmentObject private var deepLink: DeepLinkRouter

    enum Tab: Hashable { case operatorTab, harnesses, running, activity, settings }
    @State private var tab: Tab = .operatorTab

    var body: some View {
        Group {
            if let current = creds {
                PairedShell(
                    current: current,
                    tab: $tab,
                    liveTick: $liveTick,
                    lastInvalidate: $lastInvalidate,
                    pushedDetailSlug: $pushedDetailSlug,
                    pushedRunLogSlug: $pushedRunLogSlug,
                    deepLink: deepLink,
                    onForget: {
                        CredentialStore.clear()
                        creds = nil
                    },
                    onWorkspaceSwitched: { fresh in
                        CredentialStore.save(fresh)
                        creds = fresh
                    }
                )
                .id(current.deviceToken)
            } else {
                PairView { fresh in
                    CredentialStore.save(fresh)
                    creds = fresh
                    tab = .operatorTab
                }
                .onChange(of: deepLink.pendingPair) { _, new in
                    if let p = new { Task { await autoPair(p) } }
                }
                .onAppear {
                    if let p = deepLink.pendingPair { Task { await autoPair(p) } }
                }
            }
        }
    }

    /// Consume a pendingPair (papercup://pair?...) without going through
    /// PairView. Mirrors PairView.redeem(): generate WG key + POST
    /// /api/mobile/pair + persist DeviceCredentials. Used for pair-by-link
    /// (email, scanning a QR with the system camera, etc.).
    @MainActor
    private func autoPair(_ p: PendingPair) async {
        let log = OSLog(subsystem: "com.papercuspai.operator.mobile", category: "AutoPair")
        os_log(.info, log: log, "starting server=%{public}@ ws=%{public}@",
               p.server, p.workspaceId)
        deepLink.pendingPair = nil
        let keys = generateWgKeypair()
        let client = OperatorClient(baseUrl: p.server, deviceToken: nil)
        do {
            let outcome = try await client.pair(
                pairToken: p.pairToken,
                wireguardPubkeyB64: keys.publicKeyB64
            )
            os_log(.info, log: log, "pair OK deviceId=%{public}@", outcome.deviceId)
            let wgQuick = outcome.mesh.map { meshToWgQuick(privateKeyB64: keys.privateKeyB64, config: $0) }
            let fresh = DeviceCredentials(
                server: p.server,
                deviceToken: outcome.deviceToken,
                deviceId: outcome.deviceId,
                workspaceId: outcome.workspaceId,
                meshAssignedIp: outcome.mesh?.assignedIp,
                wgQuickConfig: wgQuick,
                wgPrivateKey: outcome.mesh != nil ? keys.privateKeyB64 : nil,
                meshUrl: outcome.desktopMeshUrl
            )
            CredentialStore.save(fresh)
            creds = fresh
            tab = .operatorTab
        } catch {
            os_log(.info, log: log, "FAILED %{public}@", String(describing: error))
        }
    }
}

private struct PairedShell: View {
    let current: DeviceCredentials
    @Binding var tab: AppRoot.Tab
    @Binding var liveTick: Int
    @Binding var lastInvalidate: String?
    @Binding var pushedDetailSlug: String?
    @Binding var pushedRunLogSlug: String?
    @ObservedObject var deepLink: DeepLinkRouter
    let onForget: () -> Void
    let onWorkspaceSwitched: (DeviceCredentials) -> Void

    @StateObject private var monitor: ConnectionMonitor
    @StateObject private var voice: VoiceManager
    @StateObject private var cacheHost: CacheHost
    private let wakeWord: WakeWordEngine

    init(current: DeviceCredentials,
         tab: Binding<AppRoot.Tab>,
         liveTick: Binding<Int>,
         lastInvalidate: Binding<String?>,
         pushedDetailSlug: Binding<String?>,
         pushedRunLogSlug: Binding<String?>,
         deepLink: DeepLinkRouter,
         onForget: @escaping () -> Void,
         onWorkspaceSwitched: @escaping (DeviceCredentials) -> Void) {
        self.current = current
        self._tab = tab
        self._liveTick = liveTick
        self._lastInvalidate = lastInvalidate
        self._pushedDetailSlug = pushedDetailSlug
        self._pushedRunLogSlug = pushedRunLogSlug
        self.deepLink = deepLink
        self.onForget = onForget
        self.onWorkspaceSwitched = onWorkspaceSwitched
        let voiceState = StateObject(wrappedValue: VoiceManager(creds: current))
        self._monitor = StateObject(wrappedValue: ConnectionMonitor(creds: current))
        self._voice = voiceState
        self._cacheHost = StateObject(wrappedValue: CacheHost(creds: current))
        let voiceRef = voiceState
        self.wakeWord = WakeWordEngine { [voiceRef] in
            Task { @MainActor in voiceRef.wrappedValue.start() }
        }
    }

    var body: some View {
        let onSelectHarness: (String) -> Void = { slug in
            pushedRunLogSlug = nil
            pushedDetailSlug = slug
        }

        VStack(spacing: 0) {
            if monitor.state.status == .offline {
                Text(NSLocalizedString("connection.lost", comment: ""))
                    .font(.caption)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(Color.red)
            }
            VoiceErrorBanner(voice: voice)
            ZStack {
                Group {
                    switch tab {
                    case .operatorTab:
                        OperatorView(
                            creds: current,
                            invalidationTick: liveTick,
                            onSelectHarness: onSelectHarness,
                            voice: voice
                        )
                    case .harnesses:
                        HarnessListView(
                            creds: current,
                            liveTick: liveTick,
                            lastInvalidate: lastInvalidate,
                            onSelect: onSelectHarness
                        )
                    case .running:
                        RunningView(
                            creds: current,
                            invalidationTick: liveTick,
                            onSelectHarness: onSelectHarness
                        )
                    case .activity:
                        ActivityView(
                            creds: current,
                            invalidationTick: liveTick,
                            onSelectHarness: onSelectHarness
                        )
                    case .settings:
                        SettingsView(
                            creds: current,
                            monitor: monitor,
                            onForget: onForget,
                            onWorkspaceSwitched: onWorkspaceSwitched
                        )
                    }
                }

                if let slug = pushedDetailSlug {
                    HarnessDetailView(
                        creds: current,
                        slug: slug,
                        invalidationTick: liveTick,
                        onBack: {
                            pushedRunLogSlug = nil
                            pushedDetailSlug = nil
                        },
                        onOpenRunLog: { pushedRunLogSlug = slug }
                    )
                    .transition(.move(edge: .trailing))
                }
                if let slug = pushedRunLogSlug {
                    RunLogView(
                        creds: current,
                        slug: slug,
                        onBack: { pushedRunLogSlug = nil }
                    )
                    .transition(.move(edge: .trailing))
                }

                VoicePill(voice: voice)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(.trailing, 16)
                    .padding(.bottom, 76)
            }
            MobileBottomNav(tab: $tab)
        }
        .task(id: current.deviceToken) { monitor.start(); await runSync() }
        .onReceive(cacheHost.$tick) { _ in
            // Bump the SSE-shared liveTick so existing screens that
            // observe `invalidationTick: liveTick` refresh when any
            // cache-tracked query refetches.
            liveTick += 1
        }
        .onChange(of: voice.state) { _, new in
            if new == .idle { wakeWord.start() } else { wakeWord.stop() }
        }
        .onChange(of: voice.pendingIntent) { _, new in
            // Voice intent dispatch — every `browser: 'required'` client-
            // tool call from the EL agent surfaces here and maps to a
            // native action. iOS uses the custom Tauri-style tab binding
            // plus pushedDetailSlug; voice-settings + standing-approvals
            // are sub-screens of the Settings tab, so we tab-switch to
            // Settings for those (user drills in one tap).
            guard let intent = new else { return }
            switch intent {
            case .navigateHarness(let slug):
                pushedDetailSlug = slug
            case .navigateTab(let target):
                tab = switch target {
                    case .operatorTab: .operatorTab
                    case .harnesses: .harnesses
                    case .activity: .activity
                    case .settings: .settings
                }
            case .navigateVoiceSettings, .navigateStandingApprovals:
                tab = .settings
            case .pause:
                Task { try? await current.client().pauseSet(paused: true) }
            case .resume:
                Task { try? await current.client().pauseSet(paused: false) }
            case .claimVoice:
                Task { try? await current.client().voiceLeaseClaim() }
            case .voiceSetMode(let mode):
                switch mode.lowercased() {
                case "on", "start", "listening": voice.start()
                case "off", "stop", "idle": voice.stop()
                default: break
                }
            case .workspaceSwitch(let id):
                Task { _ = try? await current.client().workspaceSwitch(workspaceId: id) }
            }
            voice.pendingIntent = nil
        }
        .onChange(of: deepLink.pendingSlug) { _, new in
            if let slug = new {
                pushedDetailSlug = slug
                deepLink.pendingSlug = nil
            }
        }
        .onAppear {
            if voice.state == .idle { wakeWord.start() }
            if let slug = deepLink.pendingSlug {
                pushedDetailSlug = slug
                deepLink.pendingSlug = nil
            }
        }
        .onDisappear { monitor.stop(); voice.stop(); wakeWord.stop() }
    }

    private func runSync() async {
        // Cache lives on cacheHost (@StateObject) so it survives SSE
        // reconnects + lets the UI observe deltas via cacheHost.tick.
        let stream = SyncStream(baseUrl: current.server, deviceToken: current.deviceToken)
        defer { stream.disconnect() }
        while !Task.isCancelled {
            do {
                let ev = try await stream.nextEvent()
                lastInvalidate = ev.name
                await cacheHost.handleInvalidate(ev.name)
                if ev.name.hasPrefix("harness") {
                    liveTick += 1
                }
            } catch {
                break
            }
        }
    }
}

private struct MobileBottomNav: View {
    @Binding var tab: AppRoot.Tab

    private var items: [(AppRoot.Tab, String, String)] {
        [
            (.operatorTab, "●", NSLocalizedString("tab.operator", comment: "")),
            (.harnesses, "⌘", NSLocalizedString("tab.harnesses", comment: "")),
            (.running, "▶", NSLocalizedString("tab.running", comment: "")),
            (.activity, "◆", NSLocalizedString("tab.activity", comment: "")),
            (.settings, "⚙", NSLocalizedString("tab.settings", comment: "")),
        ]
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(items, id: \.0) { item in
                let selected = tab == item.0
                let background = selected ? PapercupTheme.accent.opacity(0.10) : Color.clear
                Button {
                    tab = item.0
                } label: {
                    VStack(spacing: 1) {
                        Text(item.1)
                            .font(.system(size: 18, weight: .semibold))
                        Text(item.2.uppercased())
                            .font(.system(size: 10, weight: .semibold))
                            .tracking(0.8)
                    }
                    .foregroundStyle(selected ? PapercupTheme.accentStrong : PapercupTheme.textMuted)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background(
                        background,
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(item.2))
                .accessibilityAddTraits(selected ? [.isButton, .isSelected] : [.isButton])
            }
        }
        .padding(.horizontal, 6)
        .padding(.top, 6)
        .padding(.bottom, 4)
        .background(
            LinearGradient(
                colors: [PapercupTheme.inkRaised.opacity(0.96), PapercupTheme.ink.opacity(0.98)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .overlay(alignment: .top) {
            Rectangle()
                .fill(PapercupTheme.accentStrong.opacity(0.16))
                .frame(height: 1)
        }
    }
}

private struct VoicePill: View {
    @ObservedObject var voice: VoiceManager

    private var style: (glyph: String, label: String, background: Color, foreground: Color) {
        switch voice.state {
        case .idle:
            return ("◉", "Listen", PapercupTheme.inkRaised, PapercupTheme.accentStrong)
        case .connecting:
            return ("⋯", "Connecting", PapercupTheme.inkRaised, PapercupTheme.warning)
        case .listening:
            return ("◼", "Listening", PapercupTheme.accent, PapercupTheme.ink)
        case .speaking:
            return ("◼", "Speaking", PapercupTheme.accentStrong, PapercupTheme.ink)
        case .failed:
            return ("!", "Error", PapercupTheme.error, Color.white)
        }
    }

    private var isActive: Bool {
        switch voice.state {
        case .idle, .failed: return false
        case .connecting, .listening, .speaking: return true
        }
    }

    var body: some View {
        let s = style
        Button {
            if isActive {
                voice.stop()
            } else {
                voice.start()
            }
        } label: {
            VStack(spacing: 0) {
                Text(s.glyph)
                    .font(.system(size: 18, weight: .semibold))
                Text(s.label.uppercased())
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.8)
            }
            .foregroundStyle(s.foreground)
            .frame(width: 80, height: 56)
            .background(s.background, in: Capsule())
            .overlay(Capsule().stroke(s.foreground.opacity(0.48), lineWidth: 1))
            .shadow(color: Color.black.opacity(0.38), radius: 18, x: 0, y: 10)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Voice: \(s.label)\(isActive ? " (tap to stop)" : "")"))
    }
}
