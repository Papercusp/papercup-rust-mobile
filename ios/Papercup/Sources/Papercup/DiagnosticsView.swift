// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import UIKit

struct DiagnosticsView: View {
    let creds: DeviceCredentials
    @ObservedObject var monitor: ConnectionMonitor
    @State private var pinging: Bool = false

    var body: some View {
        List {
            Section("Connection") {
                HStack {
                    Text(NSLocalizedString("diagnostics.status", comment: "")).foregroundStyle(.secondary)
                    Spacer()
                    statusPill(monitor.state.status)
                }
                if let ms = monitor.state.lastPingMs {
                    kv("Last ping", "\(ms) ms")
                }
                if let since = monitor.state.offlineSinceMs {
                    kv("Offline since", Date(timeIntervalSince1970: TimeInterval(since) / 1000).description)
                }
                Button {
                    pinging = true
                    Task { await monitor.probe(); pinging = false }
                } label: {
                    Text(pinging ? "Pinging…" : "Ping desktop")
                }
                .disabled(pinging)
            }
            Section("Pairing") {
                kv("Device ID", creds.deviceId, mono: true)
                kv("Workspace", creds.workspaceId)
                kv("Server", creds.server)
                kv("Token (first 12)", creds.deviceToken.prefix(12) + "…", mono: true)
                kv("Token length", "\(creds.deviceToken.count) chars")
                if let ip = creds.meshAssignedIp {
                    kv("Mesh address", ip)
                }
            }
            Section("Build") {
                kv("Core version", PapercupCoreVersion())
                kv("iOS", UIDevice.current.systemVersion)
                kv("Device", UIDevice.current.model)
            }
        }
        .navigationTitle("Diagnostics")
    }

    private func kv(_ k: String, _ v: some StringProtocol, mono: Bool = false) -> some View {
        HStack {
            Text(k).font(.caption).foregroundStyle(.secondary)
            Spacer()
            if mono {
                Text(String(v)).font(.caption.monospaced())
            } else {
                Text(String(v)).font(.caption)
            }
        }
    }

    private func statusPill(_ s: ConnStatus) -> some View {
        let (label, color): (String, Color) = switch s {
        case .online:  ("ONLINE",  .green)
        case .offline: ("OFFLINE", .red)
        case .unknown: ("UNKNOWN", .secondary)
        }
        return Text(label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(color.opacity(0.2))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }
}

@inline(__always)
private func PapercupCoreVersion() -> String {
    #if canImport(Papercup)
    return version()
    #else
    return version()
    #endif
}
