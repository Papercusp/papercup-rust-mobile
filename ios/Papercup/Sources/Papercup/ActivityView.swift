// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct ActivityView: View {
    let creds: DeviceCredentials
    let invalidationTick: Int
    let onSelectHarness: (String) -> Void

    @State private var toasts: [Toast] = []
    @State private var actions: [AuditEntry] = []
    @State private var error: String? = nil
    @State private var isLoading = false

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    headerCard
                    if let err = error {
                        errorCard(err)
                    }
                    if isLoading && toasts.isEmpty && actions.isEmpty {
                        loadingCard
                    }
                    notificationsSection
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .papercupScreenChrome()
            .navigationTitle("Notifications")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(PapercupTheme.inkRaised, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .task(id: "\(creds.deviceToken)|\(invalidationTick)") { await load() }
        }
    }

    private var headerCard: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                PapercupSectionTitle(text: "Inbox")
                Text("Notifications")
                    .font(.title3.bold())
                    .foregroundStyle(PapercupTheme.text)
                Text(notificationSubtitle)
                    .font(.caption)
                    .foregroundStyle(PapercupTheme.textMuted)
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 8) {
                linkPill("History", destination: NotificationHistoryView(toasts: toasts, isLoading: isLoading, onSelectHarness: onSelectHarness))
                linkPill("Recent actions", destination: RecentActionsView(actions: actions, isLoading: isLoading, onSelectHarness: onSelectHarness))
            }
        }
        .papercupCardContainer(accent: PapercupTheme.info.opacity(0.08))
    }

    private var notificationsSection: some View {
        sectionShell("Recent") {
            if !isLoading && toasts.isEmpty {
                emptyState("No recent notifications.", accent: PapercupTheme.info.opacity(0.08))
            } else {
                cardList(accent: levelAccent(toasts.first?.level).opacity(0.10)) {
                    ForEach(Array(toasts.enumerated()), id: \.element.id) { index, toast in
                        ActivityToastRow(toast: toast, onSelectHarness: onSelectHarness, isLast: index == toasts.count - 1)
                    }
                }
            }
        }
    }

    private var notificationSubtitle: String {
        if isLoading { return "Loading…" }
        return "\(toasts.count) recent"
    }

    private func linkPill<Destination: View>(_ title: String, destination: Destination) -> some View {
        NavigationLink(destination: destination) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(PapercupTheme.accentStrong)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(PapercupTheme.accent.opacity(0.12), in: Capsule())
                .overlay(
                    Capsule().stroke(PapercupTheme.accentStrong.opacity(0.35), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }


    private func sectionShell<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            PapercupSectionTitle(text: title)
            content()
        }
    }

    private func cardList<Content: View>(accent: Color = PapercupTheme.accent.opacity(0.10), @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            content()
        }
        .background(PapercupTheme.cardBackground(accent: accent))
    }

    private func emptyState(_ text: String, accent: Color) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(PapercupTheme.textMuted)
            .papercupCardContainer(accent: accent)
    }

    private var loadingCard: some View {
        HStack(spacing: 10) {
            ProgressView()
                .tint(PapercupTheme.accentStrong)
            Text("Loading notifications and recent actions…")
                .font(.callout)
                .foregroundStyle(PapercupTheme.textMuted)
        }
        .papercupCardContainer(accent: PapercupTheme.info.opacity(0.08))
    }

    private func errorCard(_ message: String) -> some View {
        Text(message)
            .font(.caption.monospaced())
            .foregroundStyle(PapercupTheme.error)
            .papercupCardContainer(accent: PapercupTheme.error.opacity(0.16))
    }


    private func levelAccent(_ level: String?) -> Color {
        switch ActivityRowFormatting.chipRole(for: level ?? "") {
        case .error:
            return PapercupTheme.error
        case .warning:
            return PapercupTheme.warning
        case .success:
            return PapercupTheme.success
        default:
            return PapercupTheme.accent
        }
    }


    @MainActor
    private func load() async {
        isLoading = true
        defer { isLoading = false }

        do {
            let client = creds.client()
            async let recentNotifications = client.recentNotifications()
            async let recentActions = client.recentActions()
            toasts = try await recentNotifications
            actions = try await recentActions
            error = nil
        } catch let err as ApiError {
            error = "API: \(err)"
        } catch {
            self.error = "Unexpected: \(error)"
        }
    }
}

private struct NotificationHistoryView: View {
    let toasts: [Toast]
    let isLoading: Bool
    let onSelectHarness: (String) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                header
                if !isLoading && toasts.isEmpty {
                    Text("No history yet.")
                        .font(.callout)
                        .foregroundStyle(PapercupTheme.textMuted)
                        .papercupCardContainer(accent: PapercupTheme.info.opacity(0.08))
                } else {
                    section
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .papercupScreenChrome()
        .navigationTitle("Notification history")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(PapercupTheme.inkRaised, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            PapercupSectionTitle(text: "Archive")
            Text("Notification history")
                .font(.title3.bold())
                .foregroundStyle(PapercupTheme.text)
            Text(isLoading ? "Loading…" : "\(toasts.count) entries")
                .font(.caption)
                .foregroundStyle(PapercupTheme.textMuted)
        }
        .papercupCardContainer(accent: PapercupTheme.info.opacity(0.08))
    }

    private var section: some View {
        VStack(alignment: .leading, spacing: 8) {
            PapercupSectionTitle(text: "History")
            VStack(spacing: 0) {
                ForEach(Array(toasts.enumerated()), id: \.element.id) { index, toast in
                    ActivityToastRow(toast: toast, onSelectHarness: onSelectHarness, isLast: index == toasts.count - 1)
                }
            }
            .background(PapercupTheme.cardBackground(accent: PapercupTheme.info.opacity(0.08)))
        }
    }
}

private struct RecentActionsView: View {
    let actions: [AuditEntry]
    let isLoading: Bool
    let onSelectHarness: (String) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                header
                if !isLoading && actions.isEmpty {
                    Text("No recent actions.")
                        .font(.callout)
                        .foregroundStyle(PapercupTheme.textMuted)
                        .papercupCardContainer(accent: PapercupTheme.info.opacity(0.08))
                } else {
                    section
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .papercupScreenChrome()
        .navigationTitle("Recent actions")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(PapercupTheme.inkRaised, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            PapercupSectionTitle(text: "Audit")
            Text("Recent actions")
                .font(.title3.bold())
                .foregroundStyle(PapercupTheme.text)
            Text(isLoading ? "Loading…" : "\(actions.count) entries")
                .font(.caption)
                .foregroundStyle(PapercupTheme.textMuted)
        }
        .papercupCardContainer(accent: PapercupTheme.success.opacity(0.07))
    }

    private var section: some View {
        VStack(alignment: .leading, spacing: 8) {
            PapercupSectionTitle(text: "Recent")
            VStack(spacing: 0) {
                ForEach(Array(actions.enumerated()), id: \.element.id) { index, entry in
                    ActivityAuditRow(entry: entry, onSelectHarness: onSelectHarness, isLast: index == actions.count - 1)
                }
            }
            .background(PapercupTheme.cardBackground(accent: PapercupTheme.success.opacity(0.08)))
        }
    }
}


private struct ActivityToastRow: View {
    let toast: Toast
    let onSelectHarness: (String) -> Void
    let isLast: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(toast.message)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(PapercupTheme.text)
                    if let description = toast.description, !description.isEmpty {
                        Text(description)
                            .font(.caption)
                            .foregroundStyle(PapercupTheme.textMuted)
                    }
                }
                Spacer(minLength: 12)
                Text(ActivityRowFormatting.relativeTime(from: toast.createdAt).uppercased())
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(PapercupTheme.textMuted)
            }

            HStack(spacing: 8) {
                PapercupChip(text: toast.level.uppercased(), role: ActivityRowFormatting.chipRole(for: toast.level))
                Text(ActivityRowFormatting.formatTs(toast.createdAt))
                    .papercupMonoMeta()
                Spacer(minLength: 12)
                if let slug = toast.harnessSlug {
                    Button(slug) { onSelectHarness(slug) }
                        .font(.caption.monospaced())
                        .foregroundStyle(PapercupTheme.accentStrong)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .overlay(alignment: .bottom) {
            if !isLast {
                ActivityRowFormatting.separatorInset
            }
        }
    }
}

private struct ActivityAuditRow: View {
    let entry: AuditEntry
    let onSelectHarness: (String) -> Void
    let isLast: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(entry.actor)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(PapercupTheme.accentStrong)
                Spacer(minLength: 12)
                Text(ActivityRowFormatting.relativeTime(from: entry.ts).uppercased())
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(PapercupTheme.textMuted)
            }

            Text(entry.action)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(PapercupTheme.text)

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(entry.subject)
                    .font(.caption.monospaced())
                    .foregroundStyle(PapercupTheme.textMuted)
                    .lineLimit(2)
                Spacer(minLength: 12)
                if let slug = ActivityRowFormatting.harnessSlug(from: entry.subject) {
                    Button(slug) { onSelectHarness(slug) }
                        .font(.caption.monospaced())
                        .foregroundStyle(PapercupTheme.accentStrong)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .overlay(alignment: .bottom) {
            if !isLast {
                ActivityRowFormatting.separatorInset
            }
        }
    }
}

private enum ActivityRowFormatting {
    static var separatorInset: some View {
        Rectangle()
            .fill(PapercupTheme.stroke.opacity(0.22))
            .frame(height: 1)
            .padding(.horizontal, 16)
    }

    static func chipRole(for level: String) -> PapercupChipRole {
        switch level.lowercased() {
        case "error":
            return .error
        case "warning", "warn":
            return .warning
        case "success":
            return .success
        default:
            return .muted
        }
    }
    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d HH:mm"
        return formatter
    }()

    static func harnessSlug(from subject: String) -> String? {
        guard subject.hasPrefix("harness:") else { return nil }
        let rest = subject.dropFirst("harness:".count)
        let slug = rest.split(separator: ":").first.map(String.init) ?? String(rest)
        return slug.isEmpty ? nil : slug
    }

    static func formatTs(_ unix: Int64) -> String {
        timestampFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(unix)))
    }

    static func relativeTime(from unix: Int64) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince1970) - Int(unix))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3_600 { return "\(seconds / 60)m" }
        if seconds < 86_400 { return "\(seconds / 3_600)h" }
        return "\(seconds / 86_400)d"
    }
}