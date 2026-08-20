// SPDX-License-Identifier: GPL-3.0-or-later
//
// SwiftUI host for the UDL SyncCache.
//
// The server's SSE invalidation stream is retired (mobile-apps-revival
// D-001.1); the cache now POLLS GET /api/device/rest-query and notifies
// only when a payload actually changes (push notifications, D-004, cover
// interrupt latency). This host lifts the cache to a @StateObject scope
// so polling survives view churn, and bridges CacheSubscriber callbacks
// into a @Published `tick` so SwiftUI views observing the CacheHost
// re-evaluate after any registered query refetches.
//
// Each screen reading from the cache observes `cache.tick` and re-runs
// its fetch when it changes — same pattern as the existing `liveTick`.

import Foundation
import PapercupCore
import SwiftUI

@MainActor
final class CacheHost: ObservableObject {
    /// Bumps on every cache change (Updated only — polling stays quiet
    /// when the payload is unchanged). UI screens observe this to know
    /// when to re-pull from REST.
    @Published var tick: Int = 0
    @Published var lastInvalidate: String? = nil

    /// Foreground poll cadence. Push (D-004) handles the urgent-event
    /// latency; this is the steady-state refresh for an open screen.
    private static let pollIntervalMs: UInt64 = 5_000

    let cache: SyncCache

    init(creds: DeviceCredentials) {
        self.cache = SyncCache(client: creds.client())
        // Only names the bindings ClientFetcher maps onto a device route
        // are pollable; unmapped names would just Fail every tick.
        for name in [
            "toastLog.recent",
            "auditLog.recent",
            "operatorScans.running",
            "harnesses.list",
        ] {
            cache.registerQuery(name: name)
        }
        cache.subscribe(subscriber: BumpSubscriber { [weak self] update in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.tick += 1
                if case let .updated(name, _, _) = update {
                    self.lastInvalidate = name
                }
            }
        })
    }

    /// Begin polling. Idempotent — safe to call on every `.task` entry.
    func start() {
        cache.startPolling(intervalMs: Self.pollIntervalMs)
    }

    /// Stop polling (e.g. when the app backgrounds).
    func stop() {
        cache.stopPolling()
    }

    /// Force-refresh one query now (e.g. a push named a changed surface,
    /// or pull-to-refresh).
    func handleInvalidate(_ name: String) async {
        await cache.handleInvalidate(name: name)
    }
}

/// Adapter: closure-based CacheSubscriber.
private final class BumpSubscriber: CacheSubscriber {
    let body: (CacheUpdate) -> Void
    init(_ body: @escaping (CacheUpdate) -> Void) { self.body = body }
    func onUpdate(update: CacheUpdate) { body(update) }
}
