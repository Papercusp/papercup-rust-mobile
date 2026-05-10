// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

enum ConnStatus { case unknown, online, offline }

struct ConnState: Equatable {
    var status: ConnStatus = .unknown
    var offlineSinceMs: Int64? = nil
    var lastPingMs: Int? = nil
}

@MainActor
final class ConnectionMonitor: ObservableObject {
    @Published private(set) var state = ConnState()
    private let creds: DeviceCredentials
    private var task: Task<Void, Never>? = nil

    init(creds: DeviceCredentials) { self.creds = creds }

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

    func probe() async {
        let client = OperatorClient(baseUrl: creds.server, deviceToken: creds.deviceToken)
        let t0 = Date()
        do {
            try await client.heartbeat()
            let rt = Int(Date().timeIntervalSince(t0) * 1000)
            state = ConnState(status: .online, offlineSinceMs: nil, lastPingMs: rt)
        } catch {
            let since = state.status == .offline ? state.offlineSinceMs : Int64(Date().timeIntervalSince1970 * 1000)
            state = ConnState(status: .offline, offlineSinceMs: since, lastPingMs: nil)
        }
    }
}
