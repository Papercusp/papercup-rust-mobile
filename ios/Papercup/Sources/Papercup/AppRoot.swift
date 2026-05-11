// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import os.log

/// Mirrors Android's PairedShell — tab-nav (Operator / Harnesses /
/// Activity / Settings) plus pushed routes (Detail / RunLog).
struct AppRoot: View {
    @State private var creds: DeviceCredentials? = CredentialStore.load()
    @State private var liveTick: Int = 0
    @State private var lastInvalidate: String? = nil
    @State private var pushedDetailSlug: String? = nil
    @EnvironmentObject private var deepLink: DeepLinkRouter

    enum Tab: Hashable { case operatorTab, harnesses, activity, settings }
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
         deepLink: DeepLinkRouter,
         onForget: @escaping () -> Void,
         onWorkspaceSwitched: @escaping (DeviceCredentials) -> Void) {
        self.current = current
        self._tab = tab
        self._liveTick = liveTick
        self._lastInvalidate = lastInvalidate
        self._pushedDetailSlug = pushedDetailSlug
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
        let onSelectHarness: (String) -> Void = { slug in pushedDetailSlug = slug }

        VStack(spacing: 0) {
            if monitor.state.status == .offline {
                Text(NSLocalizedString("connection.lost", comment: ""))
                    .font(.caption)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(Color.red)
            }
            ZStack {
                TabView(selection: $tab) {
                    OperatorView(
                        creds: current,
                        invalidationTick: liveTick,
                        onSelectHarness: onSelectHarness,
                        voice: voice
                    )
                    .tabItem { Label(NSLocalizedString("tab.operator", comment: ""), systemImage: "rectangle.grid.2x2.fill") }
                    .tag(AppRoot.Tab.operatorTab)

                    HarnessListView(
                        creds: current,
                        liveTick: liveTick,
                        lastInvalidate: lastInvalidate,
                        onSelect: onSelectHarness
                    )
                    .tabItem { Label(NSLocalizedString("tab.harnesses", comment: ""), systemImage: "square.stack.3d.up.fill") }
                    .tag(AppRoot.Tab.harnesses)

                    ActivityView(
                        creds: current,
                        invalidationTick: liveTick,
                        onSelectHarness: onSelectHarness
                    )
                    .tabItem { Label(NSLocalizedString("tab.activity", comment: ""), systemImage: "bell.fill") }
                    .tag(AppRoot.Tab.activity)

                    SettingsView(
                        creds: current,
                        monitor: monitor,
                        onForget: onForget,
                        onWorkspaceSwitched: onWorkspaceSwitched
                    )
                    .tabItem { Label(NSLocalizedString("tab.settings", comment: ""), systemImage: "gearshape.fill") }
                    .tag(AppRoot.Tab.settings)
                }

                if let slug = pushedDetailSlug {
                    HarnessDetailView(
                        creds: current,
                        slug: slug,
                        invalidationTick: liveTick,
                        onBack: { pushedDetailSlug = nil }
                    )
                    .transition(.move(edge: .trailing))
                }
            }
        }
        .task(id: current.deviceToken) { monitor.start(); await runSync() }
        .onChange(of: voice.state) { _, new in
            if new == .idle { wakeWord.start() } else { wakeWord.stop() }
        }
        .onChange(of: voice.pendingIntent) { _, new in
            // Phase 4 voice intent dispatch — navigate intents push
            // the harness detail; pause/resume hit pause_set directly.
            guard let intent = new else { return }
            switch intent {
            case .navigate(let slug):
                pushedDetailSlug = slug
            case .pause:
                Task { try? await current.client().pauseSet(paused: true) }
            case .resume:
                Task { try? await current.client().pauseSet(paused: false) }
            case .claimVoice:
                Task { try? await current.client().voiceLeaseClaim() }
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
