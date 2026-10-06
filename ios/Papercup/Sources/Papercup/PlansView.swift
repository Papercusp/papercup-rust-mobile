// SPDX-License-Identifier: GPL-3.0-or-later
//
// Plans tab (mobile-apps-revival D-003) over GET /api/device/plans (D-002):
// browse the PG-canonical plans → items, with item-level approve / nudge /
// gate. "All Pots" by default (harness=nil fans across every pot).

import SwiftUI
import PapercupCore

struct PlansView: View {
    let creds: DeviceCredentials
    let invalidationTick: Int

    enum LoadState {
        case loading
        case ready([PlanSummary])
        case failed(String)
    }

    @State private var state: LoadState = .loading

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    header
                    switch state {
                    case .loading:
                        loadingCard
                    case .failed(let msg):
                        errorCard(msg)
                    case .ready(let plans):
                        if plans.isEmpty {
                            emptyCard
                        } else {
                            LazyVStack(alignment: .leading, spacing: 8) {
                                ForEach(plans, id: \.slug) { p in
                                    NavigationLink {
                                        PlanDetailView(creds: creds, summary: p)
                                    } label: {
                                        planCard(p)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .padding(.bottom, 112)
            }
            .papercupScreenChrome()
            .navigationTitle("Plans")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(PapercupTheme.inkRaised, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .task(id: "\(creds.deviceToken)|\(invalidationTick)") { await load() }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Plans")
                .font(.title2.weight(.semibold))
                .foregroundStyle(PapercupTheme.text)
            if case .ready(let plans) = state {
                Text("\(plans.count) across all Pots")
                    .font(.caption)
                    .foregroundStyle(PapercupTheme.textMuted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
    }

    private func planCard(_ p: PlanSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                if let status = p.status, !status.isEmpty {
                    PapercupChip(text: status.uppercased(), role: statusRole(status))
                }
                Spacer(minLength: 4)
                Text(p.harness)
                    .font(.caption2.monospaced())
                    .foregroundStyle(PapercupTheme.textMuted)
                    .lineLimit(1)
            }
            Text(p.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(PapercupTheme.text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .multilineTextAlignment(.leading)
            if !p.itemCounts.isEmpty {
                Text(itemCountSummary(p.itemCounts))
                    .font(.caption2.monospaced())
                    .foregroundStyle(PapercupTheme.textMuted)
            }
            if let next = p.nowNext, !next.isEmpty {
                Text("→ \(next)")
                    .font(.caption)
                    .foregroundStyle(PapercupTheme.accentStrong.opacity(0.85))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .papercupCardContainer(accent: PapercupTheme.accent.opacity(0.10))
    }

    private var emptyCard: some View {
        Text("No plans yet.")
            .font(.callout)
            .foregroundStyle(PapercupTheme.textMuted)
            .papercupCardContainer(accent: PapercupTheme.info.opacity(0.08))
    }

    private var loadingCard: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small).tint(PapercupTheme.accent)
            Text("Loading plans…").font(.callout).foregroundStyle(PapercupTheme.textMuted)
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
            // All Pots, active plans (skip archived noise on the phone).
            let plans = try await creds.client().plansList(harness: nil, includeArchived: false)
            state = .ready(plans)
        } catch {
            state = .failed(FriendlyError.message(error, doing: "loading plans"))
        }
    }

    private func statusRole(_ status: String) -> PapercupChipRole {
        switch status.lowercased() {
        case "active": return .success
        case "shipped": return .info
        case "draft", "ready": return .warning
        case "superseded": return .muted
        default: return .muted
        }
    }

    private func itemCountSummary(_ counts: [String: Int64]) -> String {
        counts.sorted { $0.key < $1.key }
            .map { "\($0.key):\($0.value)" }
            .joined(separator: "  ")
    }
}

// MARK: - Plan detail + item actions

private struct PlanDetailView: View {
    let creds: DeviceCredentials
    let summary: PlanSummary

    struct PlanItem: Identifiable {
        let id: String
        let title: String
        let status: String
    }

    enum LoadState {
        case loading
        case ready(detail: PlanDetail, items: [PlanItem])
        case failed(String)
    }

    @State private var state: LoadState = .loading
    @State private var busyItem: String? = nil
    @State private var actionError: String? = nil
    @State private var reloadTick = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                switch state {
                case .loading:
                    ProgressView("Loading plan…").tint(PapercupTheme.accent)
                        .frame(maxWidth: .infinity).padding(.top, 40)
                case .failed(let msg):
                    Text(msg).font(.footnote.monospaced()).foregroundStyle(PapercupTheme.error)
                        .padding(12)
                        .background(PapercupTheme.cardBackground(accent: PapercupTheme.error.opacity(0.16)))
                case .ready(let detail, let items):
                    nowCard(detail)
                    if let err = actionError {
                        Text(err).font(.caption.monospaced()).foregroundStyle(PapercupTheme.error)
                    }
                    if items.isEmpty {
                        Text("No items.").font(.callout).foregroundStyle(PapercupTheme.textMuted)
                            .papercupCardContainer(accent: PapercupTheme.info.opacity(0.08))
                    } else {
                        ForEach(items) { item in itemCard(item) }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .padding(.bottom, 60)
        }
        .papercupScreenChrome()
        .navigationTitle(summary.harness)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: "\(creds.deviceToken)|\(reloadTick)") { await load() }
    }

    private func nowCard(_ d: PlanDetail) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(d.title)
                .font(.headline.weight(.semibold))
                .foregroundStyle(PapercupTheme.text)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let nowNext = nowField(d.nowJson, "next"), !nowNext.isEmpty {
                Text("→ \(nowNext)")
                    .font(.caption)
                    .foregroundStyle(PapercupTheme.accentStrong)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .papercupCardContainer(accent: PapercupTheme.accent.opacity(0.12))
    }

    private func itemCard(_ item: PlanItem) -> some View {
        let busy = busyItem == item.id
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                PapercupChip(text: item.id, role: .muted)
                PapercupChip(text: item.status.uppercased(), role: itemStatusRole(item.status))
            }
            Text(item.title)
                .font(.subheadline)
                .foregroundStyle(PapercupTheme.text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .multilineTextAlignment(.leading)
            HStack(spacing: 8) {
                actionButton("Approve", "done", item, busy: busy, fill: PapercupTheme.success.opacity(0.22))
                actionButton("Nudge", "wip", item, busy: busy, fill: PapercupTheme.accent.opacity(0.18))
                actionButton("Gate", "needs-human", item, busy: busy, fill: PapercupTheme.warning.opacity(0.18))
            }
        }
        .papercupCardContainer(accent: PapercupTheme.info.opacity(0.08))
    }

    private func actionButton(_ label: String, _ status: String, _ item: PlanItem, busy: Bool, fill: Color) -> some View {
        Button {
            Task { await setStatus(item, status) }
        } label: {
            Text(busy ? "…" : label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(PapercupTheme.text)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(fill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(PapercupTheme.stroke.opacity(0.5), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(busy)
    }

    private func load() async {
        do {
            let detail = try await creds.client().planGet(slug: summary.slug, harness: summary.harness)
            state = .ready(detail: detail, items: parseItems(detail.itemsJson))
        } catch {
            state = .failed(FriendlyError.message(error, doing: "loading the plan"))
        }
    }

    private func setStatus(_ item: PlanItem, _ status: String) async {
        guard busyItem == nil else { return }
        busyItem = item.id
        actionError = nil
        defer { busyItem = nil }
        do {
            _ = try await creds.client().planItemSetStatus(
                slug: summary.slug,
                itemId: item.id,
                status: status,
                note: nil,
                harness: summary.harness
            )
            reloadTick += 1 // re-pull so the flipped status shows
        } catch {
            actionError = "\(item.id): " + FriendlyError.message(error, doing: "updating the item")
        }
    }

    private func itemStatusRole(_ status: String) -> PapercupChipRole {
        switch status.lowercased() {
        case "done": return .success
        case "wip": return .info
        case "blocked", "needs-human": return .warning
        case "dropped": return .error
        default: return .muted
        }
    }

    // MARK: - parse the opaque items/now JSON

    private func parseItems(_ json: String) -> [PlanItem] {
        guard
            let data = json.data(using: .utf8),
            let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        return arr.compactMap { obj in
            guard let id = obj["id"] as? String else { return nil }
            let title = (obj["text"] as? String)
                ?? (obj["title"] as? String)
                ?? (obj["name"] as? String)
                ?? id
            // The operator's parsed items carry the authored status as
            // `storedStatus` (there is no `status` key). Current operators add a
            // computed `effectiveStatus`; older or BYOC builds may not, so fall
            // back to `storedStatus` rather than showing every item as todo.
            // Same order as Android PlansScreen.kt.
            let status = (obj["effectiveStatus"] as? String)
                ?? (obj["storedStatus"] as? String)
                ?? (obj["status"] as? String)
                ?? "todo"
            return PlanItem(id: id, title: title, status: status)
        }
    }

    private func nowField(_ json: String, _ key: String) -> String? {
        guard
            let data = json.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj[key] as? String
    }
}
