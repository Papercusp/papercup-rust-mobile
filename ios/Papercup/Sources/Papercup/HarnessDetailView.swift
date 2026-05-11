// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct HarnessDetailView: View {
    let creds: DeviceCredentials
    let slug: String
    let invalidationTick: Int
    let onBack: () -> Void

    enum LoadState {
        case loading
        case ready(HarnessStatus)
        case failed(String)
    }

    @State private var state: LoadState = .loading

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(slug)
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(PapercupTheme.inkRaised, for: .navigationBar)
                .toolbarColorScheme(.dark, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(action: onBack) {
                            Image(systemName: "chevron.left")
                        }
                    }
                }
                .task(id: "\(slug)|\(invalidationTick)") { await refetch() }
                .tint(PapercupTheme.accent)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .loading:
            ProgressView("Loading status…")
                .tint(PapercupTheme.accent)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(PapercupTheme.screenGradient.ignoresSafeArea())
        case .failed(let msg):
            VStack(alignment: .leading, spacing: 8) {
                Text("Couldn't load status").font(.headline).foregroundStyle(PapercupTheme.error)
                Text(msg).font(.footnote.monospaced()).foregroundStyle(PapercupTheme.error)
            }
            .padding()
            .background(PapercupTheme.cardBackground(accent: PapercupTheme.error.opacity(0.14)))
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(PapercupTheme.screenGradient.ignoresSafeArea())
        case .ready(let s):
            List {
                headerSection(s)
                missionSection(s)
                if !s.counts.isEmpty { featuresSection(s) }
                if let d = s.lastDecision, !d.isEmpty { lastDecisionSection(d) }
            }
            .papercupScreenChrome()
        }
    }

    private func headerSection(_ s: HarnessStatus) -> some View {
        Section {
            HStack {
                Text(s.slug).font(.title3.bold())
                Spacer()
                statusChips(s)
            }
            if !s.path.isEmpty {
                Text(s.path).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            KeyValueRow(key: "iteration", value: "\(s.iteration)")
            KeyValueRow(key: "features", value: "\(s.featureCount)")
            KeyValueRow(key: "pending checkpoints", value: "\(s.pendingCheckpoints)")
            if s.activeCompetitions > 0 {
                KeyValueRow(key: "active competitions", value: "\(s.activeCompetitions)")
            }
        }
            .papercupCardRow()
    }

    private func statusChips(_ s: HarnessStatus) -> some View {
        HStack(spacing: 4) {
            chip(s.alive ? "alive" : "idle", role: s.alive ? .success : .info)
            if s.escalated { chip("escalated", role: .error) }
            if s.smokeFail { chip("smoke fail", role: .error) }
        }
    }

    private func chip(_ text: String, role: PapercupChipRole) -> some View {
        PapercupChip(text: text, role: role)
            .accessibilityLabel(Text("Status \(text)"))
    }

    private func missionSection(_ s: HarnessStatus) -> some View {
        Section("Mission") {
            KeyValueRow(key: "cost", value: String(format: "$%.4f", s.missionCostUsd))
            KeyValueRow(key: "input tokens", value: formatNum(s.missionInputTokens))
            KeyValueRow(key: "output tokens", value: formatNum(s.missionOutputTokens))
        }
            .papercupCardRow(accent: PapercupTheme.accent.opacity(0.08))
    }

    private func featuresSection(_ s: HarnessStatus) -> some View {
        Section("Features by status") {
            ForEach(s.counts.sorted { $0.value > $1.value }, id: \.key) { (k, v) in
                KeyValueRow(key: k, value: "\(v)")
            }
        }
            .papercupCardRow(accent: PapercupTheme.info.opacity(0.08))
    }

    private func lastDecisionSection(_ text: String) -> some View {
        Section("Last decision") {
            Text(text).font(.callout)
        }
            .papercupCardRow(accent: PapercupTheme.warning.opacity(0.08))
    }

    private func formatNum(_ n: Int64) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    private func refetch() async {
        state = .loading
        do {
            let client = creds.client()
            let s = try await client.getHarnessStatus(slug: slug)
            state = .ready(s)
        } catch let err as ApiError {
            state = .failed("API: \(err)")
        } catch {
            state = .failed("Unexpected: \(error)")
        }
    }
}

private struct KeyValueRow: View {
    let key: String
    let value: String
    var body: some View {
        HStack {
            Text(key).font(.footnote).foregroundStyle(PapercupTheme.textMuted)
            Spacer()
            Text(value).font(.footnote.monospaced()).foregroundStyle(PapercupTheme.text)
        }
    }
}
