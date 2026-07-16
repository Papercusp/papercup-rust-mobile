// SPDX-License-Identifier: GPL-3.0-or-later
//
// Inbox — the actionable attention feed (mobile-apps-revival D-003), over
// GET /api/device/attention (D-002). Two layers:
//   • workItems — the work_items-native actionable list (needs-human /
//     blocked / failing features + open bugs/changes). Typed + reliable.
//   • groups    — the canonical attention groups (plan items + coord
//     escalations + smoke-fails + plan-reviews). Opaque/evolving shape,
//     surfaced generically here (count + best-effort titles).
// Push (D-004) deep-links here.

import SwiftUI

struct InboxView: View {
    let creds: DeviceCredentials
    let invalidationTick: Int
    let onSelectHarness: (String) -> Void

    enum LoadState {
        case loading
        case ready(AttentionFeed)
        case failed(String)
    }

    @State private var state: LoadState = .loading

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    header
                    switch state {
                    case .loading:
                        loadingCard
                    case .failed(let msg):
                        errorCard(msg)
                    case .ready(let feed):
                        content(feed)
                    }
                    NavigationLink {
                        ActivityView(
                            creds: creds,
                            invalidationTick: invalidationTick,
                            onSelectHarness: onSelectHarness
                        )
                    } label: {
                        Text("View all activity →")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(PapercupTheme.accentStrong)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 4)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .padding(.bottom, 112)
            }
            .papercupScreenChrome()
            .navigationTitle("Inbox")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(PapercupTheme.inkRaised, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .task(id: "\(creds.deviceToken)|\(invalidationTick)") { await load() }
        }
    }

    private var header: some View {
        let count: Int = {
            if case .ready(let f) = state { return Int(f.workItemCount + f.groupCount) }
            return 0
        }()
        return VStack(alignment: .leading, spacing: 2) {
            Text("Needs you")
                .font(.title2.weight(.semibold))
                .foregroundStyle(PapercupTheme.text)
            if case .ready = state {
                Text(count == 0 ? "All clear" : "\(count) awaiting you")
                    .font(.caption)
                    .foregroundStyle(PapercupTheme.textMuted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func content(_ feed: AttentionFeed) -> some View {
        if feed.workItems.isEmpty && feed.groupCount == 0 {
            emptyCard
        } else {
            if !feed.workItems.isEmpty {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(feed.workItems, id: \.id) { wi in
                        workItemCard(wi)
                    }
                }
            }
            ForEach(Array(attentionGroups(from: feed.groupsJson).enumerated()), id: \.offset) { _, g in
                groupCard(g)
            }
        }
    }

    private func workItemCard(_ wi: AttentionWorkItem) -> some View {
        let tappable = (wi.harness?.isEmpty == false)
        return Button {
            if let h = wi.harness, !h.isEmpty { onSelectHarness(h) }
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    PapercupChip(text: wi.id, role: .muted)
                    PapercupChip(text: wi.state.uppercased(), role: stateRole(wi.state))
                    if let sev = wi.severity, !sev.isEmpty {
                        PapercupChip(text: sev.uppercased(), role: .warning)
                    }
                    Spacer(minLength: 4)
                    if let h = wi.harness, !h.isEmpty {
                        Text(h)
                            .font(.caption2.monospaced())
                            .foregroundStyle(PapercupTheme.textMuted)
                            .lineLimit(1)
                    }
                }
                Text(wi.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(PapercupTheme.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .multilineTextAlignment(.leading)
                if !wi.summary.isEmpty {
                    Text(wi.summary)
                        .font(.caption)
                        .foregroundStyle(PapercupTheme.textMuted)
                        .lineLimit(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .papercupCardContainer(accent: accent(for: wi.state))
        }
        .buttonStyle(.plain)
        .disabled(!tappable)
    }

    private func groupCard(_ g: AttentionGroup) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle().fill(PapercupTheme.info).frame(width: 6, height: 6)
                Text(g.title.uppercased())
                    .font(.caption.weight(.semibold))
                    .tracking(0.6)
                    .foregroundStyle(PapercupTheme.info)
                Spacer(minLength: 4)
                if g.count > 0 {
                    Text("\(g.count)")
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .foregroundStyle(PapercupTheme.textMuted)
                }
            }
            if let detail = g.detail, !detail.isEmpty {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(PapercupTheme.text.opacity(0.85))
                    .lineLimit(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .papercupCardContainer(accent: PapercupTheme.info.opacity(0.10))
    }

    private var emptyCard: some View {
        Text("Nothing needs you right now. Completions, approvals, blocked work, and questions will land here.")
            .font(.callout)
            .foregroundStyle(PapercupTheme.textMuted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .papercupCardContainer(accent: PapercupTheme.success.opacity(0.08))
    }

    private var loadingCard: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small).tint(PapercupTheme.accent)
            Text("Loading…").font(.callout).foregroundStyle(PapercupTheme.textMuted)
        }
        .papercupCardContainer(accent: PapercupTheme.info.opacity(0.08))
    }

    private func errorCard(_ message: String) -> some View {
        Text(message)
            .font(.footnote.monospaced())
            .foregroundStyle(PapercupTheme.error)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(PapercupTheme.cardBackground(accent: PapercupTheme.error.opacity(0.16)))
    }

    private func load() async {
        do {
            state = .ready(try await creds.client().attention())
        } catch {
            state = .failed(FriendlyError.message(error, doing: "loading your inbox"))
        }
    }

    private func stateRole(_ state: String) -> PapercupChipRole {
        switch state.lowercased() {
        case "needs-human", "blocked": return .warning
        case "failing", "open": return .error
        case "passed", "done": return .success
        default: return .muted
        }
    }

    private func accent(for state: String) -> Color {
        switch state.lowercased() {
        case "failing", "open": return PapercupTheme.error.opacity(0.12)
        case "needs-human", "blocked": return PapercupTheme.warning.opacity(0.12)
        default: return PapercupTheme.accent.opacity(0.10)
        }
    }

    // MARK: - groups (opaque) → best-effort generic rows

    private struct AttentionGroup {
        let title: String
        let detail: String?
        let count: Int
    }

    /// Decode the opaque attention `groups` JSON into displayable rows
    /// without binding to a fixed server shape: pull a label/title/kind
    /// field if present, and a count from an `items` array if present.
    private func attentionGroups(from json: String) -> [AttentionGroup] {
        guard
            let data = json.data(using: .utf8),
            let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        return arr.map { obj in
            let title = (obj["label"] as? String)
                ?? (obj["title"] as? String)
                ?? (obj["kind"] as? String)
                ?? (obj["type"] as? String)
                ?? "Attention"
            let detail = (obj["summary"] as? String)
                ?? (obj["message"] as? String)
                ?? (obj["text"] as? String)
            let count = (obj["items"] as? [Any])?.count
                ?? (obj["count"] as? Int)
                ?? 0
            return AttentionGroup(title: title, detail: detail, count: count)
        }
    }
}
