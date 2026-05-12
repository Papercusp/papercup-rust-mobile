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
    @State private var voicePrefs: VoicePrefs = VoicePrefsStore.load()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    screenHeader
                    if let err = error {
                        errorCard(err)
                    }
                    pairingSection
                    connectionSection
                    voiceSection
                    aboutSection
                    devicesSection
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 112)
            }
            .papercupScreenChrome()
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .task(id: creds.deviceToken) { await load() }
            .onAppear { voicePrefs = VoicePrefsStore.load() }
        }
    }

    private var screenHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Settings")
                .font(.title2.weight(.semibold))
                .foregroundStyle(PapercupTheme.text)
            Text("Pairing, connection, voice, and device controls.")
                .font(.caption)
                .foregroundStyle(PapercupTheme.textMuted)
        }
        .padding(.vertical, 10)
    }

    private var pairingSection: some View {
        sectionShell("Pairing") {
            infoRow("Desktop", value: creds.server)
            infoRow("Workspace", value: creds.workspaceId)
            infoRow("Device ID", value: creds.deviceId, mono: true)
            if let ip = creds.meshAssignedIp {
                infoRow("Mesh address", value: ip, mono: true, isLast: true)
            } else {
                infoRow("Mesh address", value: "not assigned", isLast: true)
            }
        }
    }

    private var connectionSection: some View {
        sectionShell("Connection") {
            NavigationLink {
                WorkspaceSelectorView(
                    creds: creds,
                    initialWorkspaces: workspaces,
                    onSwitchWorkspace: switchWorkspace
                )
            } label: {
                navRow(
                    title: "Switch workspace",
                    detail: currentWorkspaceDetail
                )
            }
            .buttonStyle(.plain)
            .accessibilityHint(Text("Opens the workspace selector."))

            dividerLine()

            NavigationLink {
                StandingApprovalsView(creds: creds)
            } label: {
                navRow(
                    title: NSLocalizedString("settings.standingApprovals", comment: ""),
                    detail: "Review candidates queued for silent dispatch."
                )
            }
            .buttonStyle(.plain)
            .accessibilityHint(Text("Opens standing approvals review."))

            dividerLine()

            Button(role: .destructive, action: onForget) {
                actionRow(
                    title: NSLocalizedString("settings.forgetDevice", comment: ""),
                    detail: "Clear credentials and return to pairing.",
                    destructive: true,
                    isLast: true
                )
            }
            .buttonStyle(.plain)
            .accessibilityHint(Text("Clears stored credentials and returns to pair view."))
        }
    }

    private var currentWorkspaceDetail: String {
        if let workspaces, let current = workspaces.first(where: \.current) {
            return current.name
        }
        return creds.workspaceId
    }

    private var voiceSection: some View {
        sectionShell("Voice") {
            NavigationLink {
                VoiceSettingsView()
            } label: {
                navRow(
                    title: NSLocalizedString("settings.voice", comment: ""),
                    detail: voicePrefs.wakeWord.isEmpty ? "Wake word, speech rate, pitch, and system voice." : "Wake word: \(voicePrefs.wakeWord)"
                )
            }
            .buttonStyle(.plain)
            .accessibilityHint(Text("Opens voice and wake-word settings."))
            dividerLine()
            infoRow("Speech", value: "Local TTS + wake-word tuning", isLast: true)
        }
    }

    private var aboutSection: some View {
        sectionShell("About") {
            infoRow("Version", value: version())
            dividerLine()
            NavigationLink {
                DiagnosticsView(creds: creds, monitor: monitor)
            } label: {
                navRow(
                    title: NSLocalizedString("settings.diagnostics", comment: ""),
                    detail: "Connection, pairing, mesh, push, and build info."
                )
            }
            .buttonStyle(.plain)
            .accessibilityHint(Text("Opens connection and build diagnostics."))
        }
    }

    @ViewBuilder
    private var devicesSection: some View {
        sectionShell("Paired devices") {
            if let dv = devices {
                if dv.isEmpty {
                    emptyRow("No paired devices found.")
                } else {
                    ForEach(Array(dv.enumerated()), id: \.element.deviceId) { index, device in
                        deviceRow(device, isLast: index == dv.count - 1)
                    }
                }
            } else {
                loadingRow(isLast: true)
            }
        }
    }


    private func deviceRow(_ d: Device, isLast: Bool) -> some View {
        let isSelf = d.deviceId == creds.deviceId
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(d.deviceLabel ?? String(d.deviceId.prefix(12)))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(PapercupTheme.text)
                    Text(d.deviceId)
                        .papercupMonoMeta()
                        .lineLimit(1)
                }
                Spacer(minLength: 12)
                if isSelf {
                    PapercupChip(text: "THIS PHONE", role: .muted)
                }
            }

            VStack(spacing: 0) {
                if let ls = d.lastSeen {
                    infoRow("Last seen", value: ls)
                    dividerLine()
                }
                if let pa = d.pairedAt {
                    infoRow("Paired", value: pa)
                    dividerLine()
                }
                infoRow("Workspace", value: d.workspaceId, isLast: isSelf)
            }

            if !isSelf {
                Button(role: .destructive) {
                    Task { await revokeDevice(d) }
                } label: {
                    HStack(spacing: 10) {
                        Circle()
                            .fill(PapercupTheme.error)
                            .frame(width: 6, height: 6)
                            .shadow(color: PapercupTheme.error.opacity(0.45), radius: 6)
                        Text(revoking == d.deviceId ? "Revoking…" : "Revoke")
                            .font(.caption.weight(.semibold))
                        Spacer()
                    }
                    .foregroundStyle(PapercupTheme.error)
                    .padding(.top, 2)
                }
                .buttonStyle(.plain)
                .disabled(revoking != nil)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(rowBackground)
        .overlay(alignment: .bottom) {
            if !isLast {
                separatorInset
            }
        }
    }

    private func infoRow(_ label: String, value: String, mono: Bool = false, isLast: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.caption)
                .foregroundStyle(PapercupTheme.textMuted)
            Spacer(minLength: 12)
            Text(value)
                .font(mono ? .caption.monospaced() : .caption)
                .foregroundStyle(PapercupTheme.text)
                .multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(rowBackground)
        .overlay(alignment: .bottom) {
            if !isLast {
                separatorInset
            }
        }
    }

    private func navRow(title: String, detail: String) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(PapercupTheme.text)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(PapercupTheme.textMuted)
            }
            Spacer(minLength: 12)
            Text("›")
                .font(.caption.weight(.semibold))
                .foregroundStyle(PapercupTheme.textMuted)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    private func actionRow(title: String, detail: String, destructive: Bool = false, isLast: Bool = false) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 10) {
                    Circle()
                        .fill(destructive ? PapercupTheme.error : PapercupTheme.accentStrong)
                        .frame(width: 6, height: 6)
                        .shadow(color: (destructive ? PapercupTheme.error : PapercupTheme.accentStrong).opacity(0.45), radius: 6)
                    Text(title)
                        .font(.subheadline.weight(.medium))
                }
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(PapercupTheme.textMuted)
            }
            .foregroundStyle(destructive ? PapercupTheme.error : PapercupTheme.text)
            Spacer(minLength: 12)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .background(rowBackground)
        .overlay(alignment: .bottom) {
            if !isLast {
                separatorInset
            }
        }
    }

    private func emptyRow(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(PapercupTheme.textMuted)
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(rowBackground)
    }

    private func loadingRow(isLast: Bool) -> some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
                .tint(PapercupTheme.accent)
            Text(NSLocalizedString("loading", comment: ""))
                .foregroundStyle(PapercupTheme.textMuted)
                .font(.callout)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground)
        .overlay(alignment: .bottom) {
            if !isLast {
                separatorInset
            }
        }
    }

    private func sectionShell<Content: View>(_ title: String, accent: Color = PapercupTheme.accent.opacity(0.10), @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            PapercupSectionTitle(text: title)
            VStack(spacing: 0) {
                content()
            }
            .background(PapercupTheme.cardBackground(accent: accent))
        }
    }


    private func dividerLine() -> some View {
        Rectangle()
            .fill(PapercupTheme.stroke.opacity(0.28))
            .frame(height: 1)
            .padding(.horizontal, 16)
    }

    private var separatorInset: some View {
        Rectangle()
            .fill(PapercupTheme.stroke.opacity(0.22))
            .frame(height: 1)
            .padding(.leading, 16)
            .padding(.trailing, 16)
    }

    private var rowBackground: some View {
        Color.clear
    }

    private func errorCard(_ message: String) -> some View {
        Text(message)
            .font(.footnote.monospaced())
            .foregroundStyle(PapercupTheme.error)
            .papercupCardContainer(accent: PapercupTheme.error.opacity(0.16))
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

    private func switchWorkspace(_ w: Workspace) async throws {
        let res = try await gatedClient().workspaceSwitch(workspaceId: w.id)
        var fresh = creds
        fresh.deviceToken = res.deviceToken
        fresh.workspaceId = res.workspaceId
        onWorkspaceSwitched(fresh)
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
