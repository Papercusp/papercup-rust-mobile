// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import UIKit
import UserNotifications

struct DiagnosticsView: View {
    let creds: DeviceCredentials
    @ObservedObject var monitor: ConnectionMonitor
    let onOpenPushRoute: (PushTapTestRoute) -> Void
    @State private var pinging: Bool = false
    @State private var pushAuth: String = "checking…"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                screenHeader
                connectionSection
                pairingSection
                meshSection
                pushSection
                buildSection
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 112)
        }
        .papercupScreenChrome()
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            pushAuth = switch settings.authorizationStatus {
                case .notDetermined: "not determined"
                case .denied: "denied"
                case .authorized: "authorized"
                case .provisional: "provisional"
                case .ephemeral: "ephemeral"
                @unknown default: "unknown"
            }
        }
    }

    private var screenHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Diagnostics")
                .font(.title2.weight(.semibold))
                .foregroundStyle(PapercupTheme.text)
            Text("Connection, pairing, mesh, push, and build state for this device.")
                .font(.caption)
                .foregroundStyle(PapercupTheme.textMuted)
        }
        .padding(.vertical, 10)
    }

    private var connectionSection: some View {
        sectionShell("Connection") {
            pillRow("Status", label: monitor.state.statusLabel, role: statusRole(monitor.state.status))
            if let since = monitor.state.offlineSinceMs {
                dividerLine()
                infoRow("Offline since", value: Date(timeIntervalSince1970: TimeInterval(since) / 1000).formatted())
            }
            if let ms = monitor.state.lastPingMs {
                dividerLine()
                infoRow("Last ping", value: "\(ms) ms")
            }
            dividerLine()
            infoRow("App shell", value: "native iOS", isLast: false)
            dividerLine()
            Button {
                pinging = true
                Task {
                    await monitor.probe()
                    pinging = false
                }
            } label: {
                actionRow(
                    title: pinging ? "Pinging…" : "Ping desktop",
                    detail: "Trigger a fresh heartbeat check.",
                    role: .accent,
                    isLast: true
                )
            }
            .buttonStyle(.plain)
            .disabled(pinging)
        }
    }

    private var pairingSection: some View {
        sectionShell("Pairing") {
            infoRow("Device ID", value: creds.deviceId, mono: true)
            dividerLine()
            infoRow("Workspace", value: creds.workspaceId)
            dividerLine()
            infoRow("Desktop host", value: creds.server)
            dividerLine()
            infoRow("Token (first 12)", value: String(creds.deviceToken.prefix(12)) + "…", mono: true)
            dividerLine()
            infoRow("Token length", value: "\(creds.deviceToken.count) chars", isLast: true)
        }
    }

    private var meshSection: some View {
        sectionShell("Mesh (Defguard)") {
            infoRow(
                "Enrollment",
                value: creds.defguardEnrollmentUrl ?? "not provided",
                mono: creds.defguardEnrollmentUrl != nil
            )
            dividerLine()
            infoRow(
                "Reachability",
                value: creds.defguardEnrollmentUrl != nil
                    ? "Defguard mesh + public tunnel / LAN fallback"
                    : "public tunnel / LAN",
                isLast: true
            )
        }
    }

    private var pushSection: some View {
        sectionShell("Push") {
            pillRow("Authorization", label: pushAuth.uppercased(), role: pushRole(pushAuth))
            dividerLine()
            NavigationLink {
                PushTapTestView(onNavigate: onOpenPushRoute)
            } label: {
                navRow(
                    title: "Push tap test",
                    detail: "Simulate notification taps against the native route model."
                )
            }
            .buttonStyle(.plain)
            .accessibilityHint(Text("Opens the push tap-routing test screen."))
        }
    }

    private var buildSection: some View {
        sectionShell("Build") {
            infoRow("Mobile app version", value: version())
            dividerLine()
            infoRow("Core version", value: PapercupCoreVersion())
            dividerLine()
            infoRow("iOS", value: UIDevice.current.systemVersion)
            dividerLine()
            infoRow("Device", value: UIDevice.current.model, isLast: true)
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
        .background(Color.clear)
        .overlay(alignment: .bottom) {
            if !isLast {
                separatorInset
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(label): \(value)"))
    }

    private func pillRow(_ label: String, label pillLabel: String, role: PapercupChipRole, isLast: Bool = false) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Text(label)
                .font(.caption)
                .foregroundStyle(PapercupTheme.textMuted)
            Spacer(minLength: 12)
            PapercupChip(text: pillLabel, role: role)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) {
            if !isLast {
                separatorInset
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(label): \(pillLabel)"))
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

    private func actionRow(title: String, detail: String, role: PapercupChipRole, isLast: Bool) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 10) {
                    Circle()
                        .fill(role.foreground)
                        .frame(width: 6, height: 6)
                        .shadow(color: role.foreground.opacity(0.45), radius: 6)
                    Text(title)
                        .font(.subheadline.weight(.medium))
                }
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(PapercupTheme.textMuted)
            }
            .foregroundStyle(PapercupTheme.text)
            Spacer(minLength: 12)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) {
            if !isLast {
                separatorInset
            }
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
            .padding(.horizontal, 16)
    }

    private func statusRole(_ status: ConnStatus) -> PapercupChipRole {
        switch status {
        case .online:
            return .success
        case .offline:
            return .error
        case .unknown:
            return .muted
        }
    }

    private func pushRole(_ state: String) -> PapercupChipRole {
        switch state {
        case "authorized", "provisional", "ephemeral":
            return .success
        case "denied":
            return .error
        case "not determined":
            return .warning
        default:
            return .muted
        }
    }
}

private extension ConnState {
    var statusLabel: String {
        switch status {
        case .online:
            return "ONLINE"
        case .offline:
            return "OFFLINE"
        case .unknown:
            return "UNKNOWN"
        }
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
