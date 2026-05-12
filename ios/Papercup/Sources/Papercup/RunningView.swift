// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct RunningView: View {
    let creds: DeviceCredentials
    let invalidationTick: Int
    let onSelectHarness: (String) -> Void

    enum LoadState {
        case loading
        case ready([Running])
        case failed(String)
    }

    @State private var state: LoadState = .loading

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                screenHeader
                operatorSection

                switch state {
                case .loading:
                    loadingCard
                case .failed(let message):
                    errorCard(message)
                case .ready(let running):
                    harnessSection(running)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 112)
        }
        .papercupScreenChrome()
        .task(id: "\(creds.deviceToken)|\(invalidationTick)") { await refetch() }
    }

    private var screenHeader: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Now running")
                .font(.title2.weight(.semibold))
                .foregroundStyle(PapercupTheme.text)
            if case .loading = state {
                Text("Loading…")
                    .font(.caption.monospaced())
                    .foregroundStyle(PapercupTheme.textMuted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 10)
    }

    private var operatorSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Operator")
            Text("No active scan.")
                .font(.callout)
                .foregroundStyle(PapercupTheme.textMuted)
                .papercupCardContainer(accent: PapercupTheme.info.opacity(0.08))
        }
    }

    private var loadingCard: some View {
        HStack(spacing: 12) {
            ProgressView().controlSize(.small)
            Text("Loading…").font(.callout)
        }
        .foregroundStyle(PapercupTheme.textMuted)
        .papercupCardContainer(accent: PapercupTheme.info.opacity(0.08))
    }

    private func errorCard(_ message: String) -> some View {
        Text(message)
            .font(.footnote.monospaced())
            .foregroundStyle(PapercupTheme.error)
            .papercupCardContainer(accent: PapercupTheme.error.opacity(0.16))
    }

    private func harnessSection(_ running: [Running]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Harnesses (\(running.count))")
            if running.isEmpty {
                Text("No harnesses currently running.")
                    .font(.callout)
                    .foregroundStyle(PapercupTheme.textMuted)
                    .papercupCardContainer(accent: PapercupTheme.info.opacity(0.08))
            } else {
                ForEach(running, id: \.harnessSlug) { item in
                    runningRow(item)
                }
            }
        }
    }

    private func runningRow(_ running: Running) -> some View {
        let total = running.passedCount + running.todoCount + running.blockedCount
        let passedPct = total > 0 ? Double(running.passedCount) / Double(total) : 0
        return Button { onSelectHarness(running.harnessSlug) } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(running.harnessSlug)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(PapercupTheme.text)
                    Spacer()
                    Text(running.phase.uppercased())
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(PapercupTheme.textMuted)
                        .tracking(0.8)
                }
                HStack(spacing: 12) {
                    Text(running.status)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(PapercupTheme.accentStrong)
                    Text("iter \(running.iteration)").papercupMonoMeta()
                    Text("\(running.passedCount)/\(total) done").papercupMonoMeta()
                    if running.blockedCount > 0 {
                        Text("\(running.blockedCount) blocked")
                            .font(.caption)
                            .foregroundStyle(PapercupTheme.warning)
                    }
                }
                ProgressView(value: passedPct)
                    .tint(PapercupTheme.accent)
                    .background(PapercupTheme.inkRaised, in: Capsule())
                if !running.activeRoles.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(running.activeRoles, id: \.self) { role in
                            PapercupChip(text: role, role: .muted)
                        }
                    }
                }
            }
            .papercupCardContainer(accent: PapercupTheme.accent.opacity(0.08))
        }
        .buttonStyle(.plain)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.caption.weight(.semibold))
            .foregroundStyle(PapercupTheme.textMuted)
            .tracking(0.8)
    }

    private func refetch() async {
        state = .loading
        do {
            state = .ready(try await creds.client().listRunning())
        } catch let err as ApiError {
            state = .failed("API: \(err)")
        } catch {
            state = .failed("Unexpected: \(error)")
        }
    }
}
