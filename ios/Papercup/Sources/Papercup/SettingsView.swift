// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct SettingsView: View {
    let creds: DeviceCredentials
    let monitor: ConnectionMonitor
    let onForget: () -> Void
    let onWorkspaceSwitched: (DeviceCredentials) -> Void

    @State private var workspaces: [Workspace]? = nil
    @State private var devices: [Device]? = nil
    @State private var error: String? = nil
    @State private var revoking: String? = nil

    var body: some View {
        NavigationStack {
            List {
                if let err = error {
                    Section { Text(err).font(.footnote.monospaced()).foregroundStyle(.red) }
                }
                identitySection
                workspacesSection
                devicesSection
                Section {
                    NavigationLink(NSLocalizedString("settings.standingApprovals", comment: "")) {
                        StandingApprovalsView(creds: creds)
                    }
                    .accessibilityHint(Text("Opens standing approvals review."))
                    NavigationLink(NSLocalizedString("settings.voice", comment: "")) {
                        VoiceSettingsView()
                    }
                    .accessibilityHint(Text("Opens voice and wake-word settings."))
                    NavigationLink(NSLocalizedString("settings.diagnostics", comment: "")) {
                        DiagnosticsView(creds: creds, monitor: monitor)
                    }
                    .accessibilityHint(Text("Opens connection and build diagnostics."))
                }
                Section {
                    Button(role: .destructive, action: onForget) {
                        Text(NSLocalizedString("settings.forgetDevice", comment: ""))
                    }
                    .accessibilityHint(Text("Clears stored credentials and returns to pair view."))
                }
            }
            .navigationTitle("Settings")
            .task(id: creds.deviceToken) { await load() }
        }
    }

    private var identitySection: some View {
        Section("This device") {
            kv("server", creds.server)
            kv("device id", creds.deviceId)
            kv("workspace id", creds.workspaceId)
            if let ip = creds.meshAssignedIp { kv("mesh address", ip) }
        }
    }

    @ViewBuilder
    private var workspacesSection: some View {
        Section("Workspaces") {
            if let ws = workspaces {
                ForEach(ws, id: \.id) { w in workspaceRow(w) }
            } else {
                Text("Loading…").font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var devicesSection: some View {
        Section("Paired devices") {
            if let dv = devices {
                ForEach(dv, id: \.deviceId) { d in deviceRow(d) }
            } else {
                Text("Loading…").font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private func workspaceRow(_ w: Workspace) -> some View {
        Button {
            guard !w.current, revoking == nil else { return }
            Task { await switchWorkspace(w) }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(w.name).font(.subheadline)
                    Text(w.id).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                Spacer()
                if w.current {
                    Text("current").font(.caption).padding(.horizontal, 8).padding(.vertical, 4).background(.green.opacity(0.2), in: Capsule())
                } else if revoking == "switch:\(w.id)" {
                    ProgressView().controlSize(.small)
                } else {
                    Text("tap to switch").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(w.current || revoking != nil)
    }

    private func deviceRow(_ d: Device) -> some View {
        let isSelf = d.deviceId == creds.deviceId
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(d.deviceLabel ?? String(d.deviceId.prefix(12))).font(.subheadline)
                Spacer()
                if isSelf {
                    Text("this phone").font(.caption).padding(.horizontal, 8).padding(.vertical, 4).background(.gray.opacity(0.2), in: Capsule())
                }
            }
            if let ls = d.lastSeen { kv("last seen", ls) }
            if let pa = d.pairedAt { kv("paired at", pa) }
            kv("workspace", d.workspaceId)
            if !isSelf {
                Button(role: .destructive) {
                    Task { await revokeDevice(d) }
                } label: {
                    Text(revoking == d.deviceId ? "Revoking…" : "Revoke")
                        .font(.caption)
                }
                .disabled(revoking != nil)
            }
        }
    }

    private func kv(_ key: String, _ value: String) -> some View {
        HStack {
            Text(key).font(.footnote).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.footnote.monospaced())
        }
    }

    private func load() async {
        do {
            let client = creds.client()
            workspaces = try await client.listWorkspaces()
            devices = try await client.listDesktopDevices()
            error = nil
        } catch let err as ApiError {
            error = "API: \(err)"
        } catch let e {
            error = "Unexpected: \(e)"
        }
    }

    /// Build a client with the platform biometric prompt wired so
    /// gateable methods (workspace_switch=Medium, revoke_device=High)
    /// route through LAContext before hitting the network.
    private func gatedClient() -> OperatorClient {
        let c = creds.client()
        c.setBiometricPrompt(prompt: BiometricGate())
        return c
    }

    private func switchWorkspace(_ w: Workspace) async {
        revoking = "switch:\(w.id)"
        defer { revoking = nil }
        do {
            let res = try await gatedClient().workspaceSwitch(workspaceId: w.id)
            var fresh = creds
            fresh.deviceToken = res.deviceToken
            fresh.workspaceId = res.workspaceId
            onWorkspaceSwitched(fresh)
        } catch let e {
            self.error = "Switch failed: \(e)"
        }
    }

    private func revokeDevice(_ d: Device) async {
        revoking = d.deviceId
        defer { revoking = nil }
        do {
            try await gatedClient().revokeDevice(deviceId: d.deviceId)
            await load()
        } catch let e {
            self.error = "Revoke failed: \(e)"
        }
    }
}
