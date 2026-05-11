// SPDX-License-Identifier: GPL-3.0-or-later
//
// Phase 3 — SwiftUI host for the UDL SyncCache.
//
// Lifts the cache to a @StateObject scope so it survives SSE reconnects
// (previous wiring put SyncCache in a function-local of runSync(),
// which dropped + recreated on every retry). Bridges CacheSubscriber
// callbacks into a @Published `tick` so SwiftUI views observing the
// CacheHost re-evaluate after any registered query refetches.
//
// Each screen reading from the cache should add `@EnvironmentObject
// var cache: CacheHost` and re-run their fetch when `cache.tick`
// changes — same pattern as the existing `liveTick` for SSE events.

import Foundation
import SwiftUI

@MainActor
final class CacheHost: ObservableObject {
    /// Bumps on every cache refetch (Updated or Failed). UI screens
    /// observe this to know when to re-pull from REST.
    @Published var tick: Int = 0
    @Published var lastInvalidate: String? = nil

    let cache: SyncCache

    init(creds: DeviceCredentials) {
        self.cache = SyncCache(client: creds.client())
        // Backend Rust server emits these 4 invalidate names today.
        // (Verified against papercup-rust-server sync_invalidate::notify
        //  call sites.) Names that aren't on this list silently no-op.
        for name in [
            "toastLog.recent",
            "auditLog.recent",
            "operatorPauseFlag",
            "harnessIdentity",
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
