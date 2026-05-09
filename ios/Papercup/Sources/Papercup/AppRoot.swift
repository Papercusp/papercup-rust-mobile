// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import PapercupCore

/// Mirrors Android's `AppRoot`: routes between Pair / List / Detail and
/// owns the long-lived SSE subscription so it survives navigation.
struct AppRoot: View {
    @State private var creds: DeviceCredentials? = CredentialStore.load()
    @State private var route: Route = .list
    @State private var liveTick: Int = 0
    @State private var lastInvalidate: String? = nil

    enum Route: Equatable {
        case list
        case detail(String)
    }

    var body: some View {
        Group {
            if let current = creds {
                paired(current)
            } else {
                PairView { fresh in
                    CredentialStore.save(fresh)
                    creds = fresh
                    route = .list
                }
            }
        }
    }

    @ViewBuilder
    private func paired(_ current: DeviceCredentials) -> some View {
        switch route {
        case .list:
            HarnessListView(
                creds: current,
                liveTick: liveTick,
                lastInvalidate: lastInvalidate,
                onSelect: { slug in route = .detail(slug) },
                onForget: {
                    CredentialStore.clear()
                    creds = nil
                }
            )
            .task(id: current.deviceToken) { await runSync(current) }
        case .detail(let slug):
            HarnessDetailView(
                creds: current,
                slug: slug,
                invalidationTick: liveTick,
                onBack: { route = .list }
            )
            .task(id: current.deviceToken) { await runSync(current) }
        }
    }

    /// Open the SSE stream and pump events until the task is cancelled.
    /// Cancellation happens automatically when `creds.deviceToken` changes
    /// or the view goes away.
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
