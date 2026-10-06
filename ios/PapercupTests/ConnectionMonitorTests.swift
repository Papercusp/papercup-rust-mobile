// SPDX-License-Identifier: GPL-3.0-or-later
//
// P-008 / WI-10004735: a revoked or expired device token is NOT "Desktop
// offline". The desktop answered and refused the token, so the shell must
// offer "Pair again" instead of an offline banner that never clears. These
// tests pin the heartbeat-outcome classification and the reconnect path.

import XCTest
import PapercupCore
@testable import Papercup

final class ConnectionMonitorTests: XCTestCase {

    private struct Boom: Error {}

    // ── pure transition ──

    func testUnauthorizedHeartbeatIsUnpairedNotOffline() {
        let s = ConnState.next(after: ConnState(), roundTripMs: nil,
                               error: ApiError.Unauthorized, nowMs: 1_000)
        XCTAssertEqual(s.status, .unpaired)
        XCTAssertNil(s.offlineSinceMs, "unpaired must not start an offline timer")
    }

    func testTransportFailureIsOfflineAndKeepsFirstOfflineInstant() {
        let first = ConnState.next(after: ConnState(), roundTripMs: nil,
                                   error: ApiError.Network(detail: "connect refused"), nowMs: 1_000)
        XCTAssertEqual(first.status, .offline)
        XCTAssertEqual(first.offlineSinceMs, 1_000)
        let later = ConnState.next(after: first, roundTripMs: nil,
                                   error: ApiError.Server(status: 502, detail: "bad gateway"), nowMs: 9_000)
        XCTAssertEqual(later.status, .offline, "5xx is reachability, not authorization")
        XCTAssertEqual(later.offlineSinceMs, 1_000, "offline duration counts from the first failure")
    }

    func testNonApiErrorIsOffline() {
        let s = ConnState.next(after: ConnState(), roundTripMs: nil, error: Boom(), nowMs: 5)
        XCTAssertEqual(s.status, .offline)
    }

    func testSuccessAfterOfflineReconnects() {
        let offline = ConnState(status: .offline, offlineSinceMs: 1_000, lastPingMs: nil)
        let s = ConnState.next(after: offline, roundTripMs: 42, error: nil, nowMs: 2_000)
        XCTAssertEqual(s, ConnState(status: .online, offlineSinceMs: nil, lastPingMs: 42))
    }

    // ── monitor driven by a scripted heartbeat ──

    @MainActor
    func testProbeSequenceOfflineThenReconnectThenRevoked() async {
        var outcomes: [Error?] = [ApiError.Network(detail: "x"), nil, ApiError.Unauthorized]
        let monitor = ConnectionMonitor(heartbeat: {
            let next = outcomes.removeFirst()
            if let next { throw next }
        })
        XCTAssertEqual(monitor.state.status, .unknown)
        await monitor.probe()
        XCTAssertEqual(monitor.state.status, .offline)
        await monitor.probe()
        XCTAssertEqual(monitor.state.status, .online)
        XCTAssertNotNil(monitor.state.lastPingMs)
        await monitor.probe()
        XCTAssertEqual(monitor.state.status, .unpaired)
    }
}

/// P-008: Keychain items survive app deletion; UserDefaults do not. A clean
/// reinstall must start at pairing, not on the previous install's token.
final class CredentialInstallResetTests: XCTestCase {

    private func freshDefaults() -> UserDefaults {
        let name = "papercup.tests.install-reset.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    func testFirstLaunchOfAnInstallClearsStoredCredentialsOnce() {
        let defaults = freshDefaults()
        var clears = 0
        XCTAssertTrue(CredentialStore.resetIfFreshInstall(defaults: defaults) { clears += 1 })
        XCTAssertEqual(clears, 1)
        XCTAssertTrue(defaults.bool(forKey: CredentialStore.installMarkerKey))
    }

    func testLaterLaunchesKeepThePairing() {
        let defaults = freshDefaults()
        var clears = 0
        CredentialStore.resetIfFreshInstall(defaults: defaults) { clears += 1 }
        XCTAssertFalse(CredentialStore.resetIfFreshInstall(defaults: defaults) { clears += 1 })
        XCTAssertFalse(CredentialStore.resetIfFreshInstall(defaults: defaults) { clears += 1 })
        XCTAssertEqual(clears, 1, "Keychain persistence across relaunch must not be wiped")
    }
}
