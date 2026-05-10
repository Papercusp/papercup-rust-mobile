// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

/// Mirrors Android's PairedShell — tab-nav (Operator / Harnesses /
/// Activity / Settings) plus pushed routes (Detail / RunLog).
struct AppRoot: View {
    @State private var creds: DeviceCredentials? = CredentialStore.load()
    @State private var liveTick: Int = 0
    @State private var lastInvalidate: String? = nil
    @State private var pushedDetailSlug: String? = nil

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
            }
        }
    }
}

private struct PairedShell: View {
    let current: DeviceCredentials
    @Binding var tab: AppRoot.Tab
    @Binding var liveTick: Int
    @Binding var lastInvalidate: String?
    @Binding var pushedDetailSlug: String?
    let onForget: () -> Void
    let onWorkspaceSwitched: (DeviceCredentials) -> Void

    @StateObject private var monitor: ConnectionMonitor
    @StateObject private var voice: VoiceManager
    private let wakeWord: WakeWordEngine

    init(current: DeviceCredentials,
         tab: Binding<AppRoot.Tab>,
         liveTick: Binding<Int>,
         lastInvalidate: Binding<String?>,
         pushedDetailSlug: Binding<String?>,
         onForget: @escaping () -> Void,
         onWorkspaceSwitched: @escaping (DeviceCredentials) -> Void) {
        self.current = current
        self._tab = tab
        self._liveTick = liveTick
        self._lastInvalidate = lastInvalidate
        self._pushedDetailSlug = pushedDetailSlug
        self.onForget = onForget
        self.onWorkspaceSwitched = onWorkspaceSwitched
        let voiceState = StateObject(wrappedValue: VoiceManager(creds: current))
        self._monitor = StateObject(wrappedValue: ConnectionMonitor(creds: current))
        self._voice = voiceState
        let voiceRef = voiceState
        self.wakeWord = WakeWordEngine { [voiceRef] in
            Task { @MainActor in voiceRef.wrappedValue.start() }
        }
    }

    var body: some View {
        let onSelectHarness: (String) -> Void = { slug in pushedDetailSlug = slug }

        VStack(spacing: 0) {
            if monitor.state.status == .offline {
                Text("Lost desktop connection")
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
                    .tabItem { Label("Operator", systemImage: "rectangle.grid.2x2.fill") }
                    .tag(AppRoot.Tab.operatorTab)

                    HarnessListView(
                        creds: current,
                        liveTick: liveTick,
                        lastInvalidate: lastInvalidate,
                        onSelect: onSelectHarness
                    )
                    .tabItem { Label("Harnesses", systemImage: "square.stack.3d.up.fill") }
                    .tag(AppRoot.Tab.harnesses)

                    ActivityView(
                        creds: current,
                        invalidationTick: liveTick,
                        onSelectHarness: onSelectHarness
                    )
                    .tabItem { Label("Activity", systemImage: "bell.fill") }
                    .tag(AppRoot.Tab.activity)

                    SettingsView(
                        creds: current,
                        monitor: monitor,
                        onForget: onForget,
                        onWorkspaceSwitched: onWorkspaceSwitched
                    )
                    .tabItem { Label("Settings", systemImage: "gearshape.fill") }
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
        .onAppear { if voice.state == .idle { wakeWord.start() } }
        .onDisappear { monitor.stop(); voice.stop(); wakeWord.stop() }
    }

    private func runSync() async {
        let stream = SyncStream(baseUrl: current.server, deviceToken: current.deviceToken)
        defer { stream.disconnect() }
        while !Task.isCancelled {
            do {
                let ev = try await stream.nextEvent()
                lastInvalidate = ev.name
                if ev.name.hasPrefix("harness") {
                    liveTick += 1
                }
            } catch {
                break
            }
        }
    }
}
