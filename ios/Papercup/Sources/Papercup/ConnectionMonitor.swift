// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import PapercupCore

/// `unpaired` is distinct from `offline` (P-008 / WI-10004735): the desktop
/// ANSWERED and refused this phone's device token (revoked from desktop
/// Settings → Remote access, or expired). Treating that as "Desktop offline"
/// left a revoked phone on a perpetual offline banner with no way back to
/// pairing; it must instead offer "Pair again".
enum ConnStatus: Equatable { case unknown, online, offline, unpaired }

struct ConnState: Equatable {
    var status: ConnStatus = .unknown
    var offlineSinceMs: Int64? = nil
    var lastPingMs: Int? = nil
    /// True while `offline` because a BYOC cloud workspace's relay answered
    /// `workspace_offline` (P-015). The relay itself is reachable; the
    /// workspace behind it is stopped or starting. The pairing is kept.
    var cloudWorkspaceOffline: Bool = false

    /// Pure heartbeat-outcome transition, unit-tested in
    /// `ConnectionMonitorTests`. `roundTripMs` is the success latency;
    /// `error` the heartbeat failure. Exactly one of them is meaningful.
    static func next(after prev: ConnState, roundTripMs: Int?, error: Error?, nowMs: Int64) -> ConnState {
        guard let error else {
            return ConnState(status: .online, offlineSinceMs: nil, lastPingMs: roundTripMs)
        }
        if isUnpaired(error) {
            return ConnState(status: .unpaired, offlineSinceMs: nil, lastPingMs: nil)
        }
        let since = prev.status == .offline ? (prev.offlineSinceMs ?? nowMs) : nowMs
        return ConnState(
            status: .offline,
            offlineSinceMs: since,
            lastPingMs: nil,
            cloudWorkspaceOffline: FriendlyError.isCloudWorkspaceOffline(error)
        )
    }

    /// Offline banner title. A cloud workspace is not "your desktop".
    var offlineTitle: String {
        cloudWorkspaceOffline ? "Cloud workspace offline" : "Desktop offline"
    }

    /// The native client maps both 401 and 403 from the device API to
    /// `ApiError.Unauthorized` (measured on staging: heartbeat 403 after
    /// revoke). Anything else — transport, 5xx, decode — is reachability,
    /// not authorization, and stays `offline` so it can self-heal.
    static func isUnpaired(_ error: Error) -> Bool {
        guard let api = error as? ApiError, case .Unauthorized = api else { return false }
        return true
    }
}

@MainActor
final class ConnectionMonitor: ObservableObject {
    @Published private(set) var state = ConnState()
    private let heartbeat: () async throws -> Void
    private var task: Task<Void, Never>? = nil

    init(creds: DeviceCredentials) {
        let client = creds.client()
        self.heartbeat = { try await client.heartbeat() }
    }

    /// Test seam: drive the monitor with a scripted heartbeat.
    init(heartbeat: @escaping () async throws -> Void) {
        self.heartbeat = heartbeat
    }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while let self, !Task.isCancelled {
                await self.probe()
                try? await Task.sleep(nanoseconds: 20_000_000_000)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    /// One heartbeat round. Also called directly when the app returns to
    /// the foreground so a reconnect (or a revoke that happened while the
    /// app was suspended) is reflected immediately instead of up to 20s late.
    func probe() async {
        let t0 = Date()
        let nowMs = Int64(t0.timeIntervalSince1970 * 1000)
        do {
            try await heartbeat()
            let rt = Int(Date().timeIntervalSince(t0) * 1000)
            state = ConnState.next(after: state, roundTripMs: rt, error: nil, nowMs: nowMs)
        } catch {
            state = ConnState.next(after: state, roundTripMs: nil, error: error, nowMs: nowMs)
        }
    }
}
