// SPDX-License-Identifier: GPL-3.0-or-later
//
// WireGuard mesh tunnel scaffold for iOS. Mirror of Android's
// MeshController + WireGuardVpnService. **Inert until the
// NetworkExtension entitlement and a NEPacketTunnelProvider extension
// target are configured (Apple Developer Program required).**
//
// To enable:
//   1. Enroll in the Apple Developer Program.
//   2. Add a Packet Tunnel Provider extension target to project.yml.
//   3. Add the SwiftPM package https://github.com/WireGuard/wireguard-apple
//      (product `WireGuardKit`) to BOTH the app and the extension targets.
//   4. Add Papercup.entitlements with:
//        com.apple.developer.networking.networkextension = [packet-tunnel-provider]
//        com.apple.security.application-groups = [group.com.papercuspai.operator]
//      and matching entitlements on the extension target.
//   5. Replace the `#if canImport(NetworkExtension) && canImport(WireGuardKit)`
//      block below with calls to NETunnelProviderManager + the
//      WireGuardKit tunnelConfiguration parser.
//
// The state machine + observability shape mirrors Android's MeshState
// so the SwiftUI Diagnostics screen can render it identically.

import Foundation
import os.log
#if canImport(NetworkExtension)
import NetworkExtension
#endif

enum MeshStatus: Equatable {
    case down
    case connecting
    case up(peerEndpoint: String?)
    case failed(message: String)
}

@MainActor
final class MeshManager: ObservableObject {
    private let log = OSLog(subsystem: "com.papercuspai.operator.mobile", category: "Mesh")
    @Published private(set) var status: MeshStatus = .down

    /// Bring the tunnel up using the wg-quick INI we received from the
    /// pair broker (creds.wgQuickConfig). No-op if any required iOS
    /// piece (entitlement, NetworkExtension, WireGuardKit) is missing.
    func start(creds: DeviceCredentials) {
        guard let config = creds.wgQuickConfig, !config.isEmpty else {
            os_log(.info, log: log, "mesh: no wg-quick config in credentials, staying down")
            status = .down
            return
        }
        #if canImport(NetworkExtension) && canImport(WireGuardKit)
        status = .connecting
        // Real impl pending: parse `config` via WireGuardKit's
        // TunnelConfiguration, install via NETunnelProviderManager,
        // observe NEVPNStatusDidChange, surface peer endpoint.
        os_log(.info, log: log, "mesh: WireGuardKit canImport=true, full impl pending")
        #else
        os_log(.info, log: log, "mesh: WireGuardKit not linked — entitlement/extension required")
        status = .failed(message: "WireGuard not linked (Apple Dev Program required)")
        #endif
    }

    func stop() {
        #if canImport(NetworkExtension) && canImport(WireGuardKit)
        // NETunnelProviderManager.stopVPNTunnel() etc.
        #endif
        status = .down
    }
}
