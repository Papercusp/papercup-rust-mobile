// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct WorkspaceSelectorView: View {
    let creds: DeviceCredentials
    let initialWorkspaces: [Workspace]?
    let onSwitchWorkspace: (Workspace) async throws -> Void

    @State private var workspaces: [Workspace]?
    @State private var error: String? = nil
    @State private var busyWorkspaceId: String? = nil

    init(
        creds: DeviceCredentials,
        initialWorkspaces: [Workspace]? = nil,
        onSwitchWorkspace: @escaping (Workspace) async throws -> Void
    ) {
        self.creds = creds
        self.initialWorkspaces = initialWorkspaces
        self.onSwitchWorkspace = onSwitchWorkspace
        _workspaces = State(initialValue: initialWorkspaces)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                headerCard

                if let error {
                    errorCard(error)
                }

                workspaceSection

                if let workspaces, workspaces.count > 1 {
                    footerCard
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 40)
        }
        .papercupScreenChrome()
        .navigationTitle("Workspace selector")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(PapercupTheme.inkRaised, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .task(id: creds.deviceToken) { await loadIfNeeded() }
    }

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Workspace selector")
                .font(.title3.weight(.semibold))
                .foregroundStyle(PapercupTheme.text)
            Text(headerSubtitle)
                .font(.caption)
                .foregroundStyle(PapercupTheme.textMuted)
        }
        .papercupCardContainer(accent: PapercupTheme.accent.opacity(0.14))
    }

    private var headerSubtitle: String {
        if workspaces == nil {
            return "Loading available workspaces…"
        }
        if let current = currentWorkspace {
            return "Current: \(current.name)"
        }
        return "Current: \(creds.workspaceId)"
    }

    @ViewBuilder
    private var workspaceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            PapercupSectionTitle(text: "Workspaces")
            VStack(spacing: 10) {
                if let workspaces {
                    if workspaces.isEmpty {
                        emptyCard("No workspaces available.")
                    } else {
                        ForEach(workspaces, id: \.id) { workspace in
                            workspaceCard(workspace)
                        }
                    }
                } else {
                    loadingCard
                }
            }
        }
    }

    private func workspaceCard(_ workspace: Workspace) -> some View {
        let isCurrent = workspace.id == currentWorkspaceId
        let isBusy = busyWorkspaceId == workspace.id

        return Button {
            guard !isCurrent, busyWorkspaceId == nil else { return }
            Task { await switchWorkspace(workspace) }
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(workspace.name)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(PapercupTheme.text)
                        Text(workspace.id)
                            .papercupMonoMeta()
                            .lineLimit(1)
                    }

                    Spacer(minLength: 12)

                    if isCurrent {
                        PapercupChip(text: "CURRENT", role: .accent)
                    } else if isBusy {
                        ProgressView()
                            .controlSize(.small)
                            .tint(PapercupTheme.accent)
                    } else {
                        Text("SWITCH")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(PapercupTheme.accentStrong)
                            .tracking(0.8)
                    }
                }

                HStack(alignment: .center, spacing: 12) {
                    if let activity = relativeActivityText(for: workspace.lastActivityAt) {
                        Text(activity)
                            .font(.caption)
                            .foregroundStyle(PapercupTheme.textMuted)
                    } else {
                        Text(isCurrent ? "This phone is already paired here." : "Switch this phone to this workspace.")
                            .font(.caption)
                            .foregroundStyle(PapercupTheme.textMuted)
                    }
                    Spacer(minLength: 12)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(
                PapercupTheme.cardBackground(
                    accent: isCurrent ? PapercupTheme.accent.opacity(0.18) : PapercupTheme.accent.opacity(0.08)
                )
            )
            .overlay(
                RoundedRectangle(cornerRadius: PapercupTheme.cardCornerRadius, style: .continuous)
                    .stroke(isCurrent ? PapercupTheme.accentStrong.opacity(0.45) : Color.clear, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: PapercupTheme.cardCornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isCurrent || busyWorkspaceId != nil)
    }

    private var loadingCard: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
                .tint(PapercupTheme.accent)
            Text(NSLocalizedString("loading", comment: ""))
                .font(.callout)
                .foregroundStyle(PapercupTheme.textMuted)
        }
        .papercupCardContainer(accent: PapercupTheme.accent.opacity(0.08))
    }

    private func emptyCard(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(PapercupTheme.textMuted)
            .papercupCardContainer(accent: PapercupTheme.accent.opacity(0.08))
    }

    private var footerCard: some View {
        Text("Switching workspaces re-issues this phone’s device token with the new workspace claim. Existing screens refresh automatically.")
            .font(.caption)
            .foregroundStyle(PapercupTheme.textMuted)
            .papercupCardContainer(accent: PapercupTheme.info.opacity(0.10))
    }

    private func errorCard(_ message: String) -> some View {
        Text(message)
            .font(.footnote.monospaced())
            .foregroundStyle(PapercupTheme.error)
            .papercupCardContainer(accent: PapercupTheme.error.opacity(0.16))
    }

    private var currentWorkspace: Workspace? {
        workspaces?.first(where: { $0.id == currentWorkspaceId })
    }

    private var currentWorkspaceId: String {
        workspaces?.first(where: { $0.current })?.id ?? creds.workspaceId
    }

    private func loadIfNeeded() async {
        guard workspaces == nil else { return }
        do {
            workspaces = try await creds.client().listWorkspaces()
            error = nil
        } catch {
            self.error = FriendlyError.message(error, doing: "loading workspaces")
        }
    }

    private func switchWorkspace(_ workspace: Workspace) async {
        busyWorkspaceId = workspace.id
        error = nil
        defer { busyWorkspaceId = nil }

        do {
            try await onSwitchWorkspace(workspace)
            workspaces = workspaces?.map {
                Workspace(
                    id: $0.id,
                    name: $0.name,
                    current: $0.id == workspace.id,
                    lastActivityAt: $0.lastActivityAt
                )
            }
        } catch {
            self.error = FriendlyError.message(error, doing: "switching workspaces")
        }
    }

    private func relativeActivityText(for lastActivityAt: Int64?) -> String? {
        guard let lastActivityAt else { return nil }
        let now = Date().timeIntervalSince1970
        let diff = now - TimeInterval(lastActivityAt)
        guard diff >= 0, diff.isFinite else { return nil }

        let seconds = Int(diff)
        if seconds < 60 { return "active just now" }
        let minutes = seconds / 60
        if minutes < 60 { return "active \(minutes)m ago" }
        let hours = minutes / 60
        if hours < 24 { return "active \(hours)h ago" }
        let days = hours / 24
        return "active \(days)d ago"
    }
}
