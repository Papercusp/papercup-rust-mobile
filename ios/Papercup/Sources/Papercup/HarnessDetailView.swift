// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct HarnessDetailView: View {
    let creds: DeviceCredentials
    let slug: String
    let invalidationTick: Int
    let onBack: () -> Void
    let onOpenRunLog: (() -> Void)?

    enum LoadState {
        case loading
        case ready(HarnessStatus)
        case failed(String)
    }

    @State private var state: LoadState = .loading

    init(
        creds: DeviceCredentials,
        slug: String,
        invalidationTick: Int,
        onBack: @escaping () -> Void,
        onOpenRunLog: (() -> Void)? = nil
    ) {
        self.creds = creds
        self.slug = slug
        self.invalidationTick = invalidationTick
        self.onBack = onBack
        self.onOpenRunLog = onOpenRunLog
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Harness")
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
                Text("Couldn't load status")
                    .font(.headline)
                    .foregroundStyle(PapercupTheme.error)
                Text(msg)
                    .font(.footnote.monospaced())
                    .foregroundStyle(PapercupTheme.error)
            }
            .padding()
            .background(PapercupTheme.cardBackground(accent: PapercupTheme.error.opacity(0.14)))
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(PapercupTheme.screenGradient.ignoresSafeArea())
        case .ready(let s):
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    overviewCard(s)
                    if s.escalated || s.smokeFail {
                        flagsSection(s)
                    }
                    missionSection(s)
                    if !s.counts.isEmpty {
                        featuresSection(s)
                    }
                    if let d = s.lastDecision, !d.isEmpty {
                        lastDecisionSection(d)
                    }
                }
                .padding(16)
                .padding(.bottom, 12)
            }
            .background(PapercupTheme.screenGradient.ignoresSafeArea())
        }
    }

    private func overviewCard(_ s: HarnessStatus) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    sectionBadge("Harness status")
                    Text(s.slug)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(PapercupTheme.text)
                    if !s.path.isEmpty {
                        Text(s.path)
                            .font(.caption.monospaced())
                            .foregroundStyle(PapercupTheme.textMuted)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 12)
                VStack(alignment: .trailing, spacing: 8) {
                    statusChips(s)
                    if let onOpenRunLog {
                        Button(action: onOpenRunLog) {
                            HStack(spacing: 6) {
                                Image(systemName: "terminal")
                                    .font(.caption.weight(.semibold))
                                Text("RUN LOG")
                                    .font(.caption.weight(.semibold))
                                    .tracking(0.8)
                            }
                            .foregroundStyle(PapercupTheme.accentStrong)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(PapercupTheme.accent.opacity(0.12), in: Capsule())
                            .overlay(
                                Capsule().stroke(PapercupTheme.accentStrong.opacity(0.40), lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            progressSection(s)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                statBlock("Phase", value: derivedStatus(s))
                statBlock("Iteration", value: "\(s.iteration)")
                statBlock("Features", value: "\(s.featureCount)")
                statBlock("Checkpoints", value: "\(s.pendingCheckpoints)")
                if s.activeCompetitions > 0 {
                    statBlock("Competitions", value: "\(s.activeCompetitions)")
                }
            }
        }
        .papercupCardContainer()
    }

    private func progressSection(_ s: HarnessStatus) -> some View {
        let done = statusCount(s.counts, matching: ["DONE", "PASSED", "COMPLETE"])
        let blocked = statusCount(s.counts, matching: ["BLOCKED"])
        let total = max(s.featureCount, 0)
        let progress = total > 0 ? min(max(Double(done) / Double(total), 0), 1) : 0

        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                sectionBadge("Progress")
                Spacer(minLength: 8)
                Text("\(done)/\(total)")
                    .font(.caption.monospaced().weight(.semibold))
                    .foregroundStyle(PapercupTheme.text)
            }

            VStack(alignment: .leading, spacing: 6) {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(PapercupTheme.ink.opacity(0.92))
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [PapercupTheme.success, PapercupTheme.accentStrong, PapercupTheme.warning.opacity(0.82)],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: geometry.size.width * progress)
                    }
                }
                .frame(height: 8)

                Text(progressSummary(done: done, blocked: blocked, pendingCheckpoints: s.pendingCheckpoints, total: total))
                    .font(.caption)
                    .foregroundStyle(PapercupTheme.textMuted)
            }
        }
    }

    private func missionSection(_ s: HarnessStatus) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            PapercupSectionTitle(text: "Mission")
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                statBlock("Cost", value: String(format: "$%.4f", s.missionCostUsd), accent: PapercupTheme.warning.opacity(0.14))
                statBlock("Input", value: formatNum(s.missionInputTokens), accent: PapercupTheme.info.opacity(0.12))
                statBlock("Output", value: formatNum(s.missionOutputTokens), accent: PapercupTheme.info.opacity(0.12))
            }
        }
    }

    private func featuresSection(_ s: HarnessStatus) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            PapercupSectionTitle(text: "Features by status")
            VStack(alignment: .leading, spacing: 10) {
                ForEach(s.counts.sorted { $0.value > $1.value }, id: \.key) { item in
                    featureRow(name: item.key, value: item.value, total: max(s.featureCount, 0))
                }
            }
            .papercupCardContainer(accent: PapercupTheme.info.opacity(0.08))
        }
    }

    private func lastDecisionSection(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            PapercupSectionTitle(text: "Last decision")
            VStack(alignment: .leading, spacing: 10) {
                sectionBadge("Latest")
                Text(text)
                    .font(.callout.monospaced())
                    .foregroundStyle(PapercupTheme.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(PapercupTheme.ink.opacity(0.96))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(PapercupTheme.stroke.opacity(0.80), lineWidth: 1)
                    )
            }
            .papercupCardContainer(accent: PapercupTheme.warning.opacity(0.10))
        }
    }

    private func flagsSection(_ s: HarnessStatus) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            PapercupSectionTitle(text: "Flags")
            VStack(alignment: .leading, spacing: 8) {
                if s.escalated {
                    flagRow(text: "Escalated — needs attention.", accent: PapercupTheme.error)
                }
                if s.smokeFail {
                    flagRow(text: "Smoke test failed.", accent: PapercupTheme.warning)
                }
            }
        }
    }

    private func featureRow(name: String, value: Int64, total: Int64) -> some View {
        let fraction = total > 0 ? min(max(Double(value) / Double(total), 0), 1) : 0
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(name.uppercased())
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(PapercupTheme.textMuted)
                    .tracking(0.7)
                Spacer(minLength: 8)
                Text("\(value)")
                    .font(.caption.monospaced().weight(.semibold))
                    .foregroundStyle(PapercupTheme.text)
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(PapercupTheme.ink.opacity(0.90))
                    Capsule()
                        .fill(PapercupTheme.accent.opacity(0.68))
                        .frame(width: geometry.size.width * fraction)
                }
            }
            .frame(height: 6)
        }
    }

    private func flagRow(text: String, accent: Color) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(accent)
                .frame(width: 8, height: 8)
            Text(text)
                .font(.caption.weight(.medium))
                .foregroundStyle(accent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(PapercupTheme.cardBackground(accent: accent.opacity(0.14)))
    }

    private func sectionBadge(_ text: String) -> some View {
        HStack(spacing: 7) {
            Circle()
                .fill(PapercupTheme.accentStrong)
                .frame(width: 6, height: 6)
            Text(text.uppercased())
                .font(.caption.weight(.semibold))
                .tracking(0.8)
        }
        .foregroundStyle(PapercupTheme.accentStrong)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(PapercupTheme.accent.opacity(0.12), in: Capsule())
        .overlay(Capsule().stroke(PapercupTheme.accentStrong.opacity(0.30), lineWidth: 1))
    }

    private func statusChips(_ s: HarnessStatus) -> some View {
        HStack(spacing: 4) {
            chip(s.alive ? "alive" : "idle", role: s.alive ? .success : .info)
            if s.escalated { chip("escalated", role: .error) }
            if s.smokeFail { chip("smoke fail", role: .warning) }
        }
    }

    private func chip(_ text: String, role: PapercupChipRole) -> some View {
        PapercupChip(text: text.uppercased(), role: role)
            .accessibilityLabel(Text("Status \(text)"))
    }

    private func statBlock(_ label: String, value: String, accent: Color = PapercupTheme.accent.opacity(0.10)) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(PapercupTheme.textMuted)
                .tracking(0.8)
            Text(value)
                .font(.system(size: 20, weight: .semibold, design: .default))
                .foregroundStyle(PapercupTheme.text)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, minHeight: 84, alignment: .leading)
        .padding(14)
        .background(PapercupTheme.cardBackground(accent: accent))
    }

    private func derivedStatus(_ s: HarnessStatus) -> String {
        if s.escalated { return "Escalated" }
        if s.smokeFail { return "Smoke fail" }
        return s.alive ? "Alive" : "Idle"
    }

    private func progressSummary(done: Int64, blocked: Int64, pendingCheckpoints: Int64, total: Int64) -> String {
        var parts: [String] = ["\(done) done"]
        if blocked > 0 { parts.append("\(blocked) blocked") }
        if pendingCheckpoints > 0 { parts.append("\(pendingCheckpoints) checkpoints waiting") }
        if total > 0 { parts.append("\(max(total - done, 0)) remaining") }
        return parts.joined(separator: " · ")
    }

    private func statusCount(_ counts: [String: Int64], matching keys: [String]) -> Int64 {
        let wanted = Set(keys.map { $0.uppercased() })
        return counts.reduce(into: Int64(0)) { total, item in
            if wanted.contains(item.key.uppercased()) {
                total += item.value
            }
        }
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
