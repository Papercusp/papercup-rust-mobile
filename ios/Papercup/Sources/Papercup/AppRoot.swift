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
                paired(current)
            } else {
                PairView { fresh in
                    CredentialStore.save(fresh)
                    creds = fresh
                    tab = .operatorTab
                }
            }
        }
    }

    @ViewBuilder
    private func paired(_ current: DeviceCredentials) -> some View {
        let onSelectHarness: (String) -> Void = { slug in pushedDetailSlug = slug }
        let onForget: () -> Void = {
            CredentialStore.clear()
            creds = nil
        }
        let onWorkspaceSwitched: (DeviceCredentials) -> Void = { fresh in
            CredentialStore.save(fresh)
            creds = fresh
        }

        ZStack {
            TabView(selection: $tab) {
                OperatorView(
                    creds: current,
                    invalidationTick: liveTick,
                    onSelectHarness: onSelectHarness
                )
                .tabItem { Label("Operator", systemImage: "rectangle.grid.2x2.fill") }
                .tag(Tab.operatorTab)

                HarnessListView(
                    creds: current,
                    liveTick: liveTick,
                    lastInvalidate: lastInvalidate,
                    onSelect: onSelectHarness
                )
                .tabItem { Label("Harnesses", systemImage: "square.stack.3d.up.fill") }
                .tag(Tab.harnesses)

                ActivityView(
                    creds: current,
                    invalidationTick: liveTick,
                    onSelectHarness: onSelectHarness
                )
                .tabItem { Label("Activity", systemImage: "bell.fill") }
                .tag(Tab.activity)

                SettingsView(
                    creds: current,
                    onForget: onForget,
                    onWorkspaceSwitched: onWorkspaceSwitched
                )
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
                .tag(Tab.settings)
            }
            .task(id: current.deviceToken) { await runSync(current) }

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

    private func runSync(_ current: DeviceCredentials) async {
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
