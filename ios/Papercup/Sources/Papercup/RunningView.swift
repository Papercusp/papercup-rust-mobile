// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import SwiftUI

struct RunningView: View {
    let creds: DeviceCredentials
    let invalidationTick: Int
    let onSelectHarness: (String) -> Void

    enum LoadState {
        case loading
        case ready(RunningSnapshot)
        case failed(String)
    }

    @State private var state: LoadState = .loading
    @State private var pauseBusy = false
    @State private var pauseDone = false
    @State private var pauseError: String?

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
                case .ready(let snapshot):
                    harnessSection(snapshot.harnesses)
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
            if case .ready(let snapshot) = state, let scan = snapshot.scan {
                operatorScanCard(scan)
            } else {
                Text("No active scan.")
                    .font(.callout)
                    .foregroundStyle(PapercupTheme.textMuted)
                    .papercupCardContainer(accent: PapercupTheme.info.opacity(0.08))
            }
        }
    }

    private func operatorScanCard(_ scan: RunningScan) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("scanning")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(PapercupTheme.accentStrong)
                    .tracking(0.8)
                    .textCase(.uppercase)
                Spacer()
                Text(relativeTime(scan.startedAt))
                    .papercupMonoMeta()
            }

            Text(displayRequestText(scan.requestText))
                .font(.subheadline)
                .foregroundStyle(PapercupTheme.text)
                .lineLimit(2)
                .truncationMode(.tail)

            Text(String(format: "$%.4f", scan.costUsd))
                .font(.caption2.monospaced())
                .foregroundStyle(PapercupTheme.textMuted)

            if pauseDone {
                Text("⏸ Paused — current scan will finish, no new dispatches.")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(PapercupTheme.warning)
            } else {
                Button { pauseOperator() } label: {
                    HStack {
                        Spacer()
                        Text(pauseBusy ? "Pausing…" : "⏸ Pause operator")
                            .font(.callout.weight(.semibold))
                        Spacer()
                    }
                    .padding(.vertical, 10)
                    .foregroundStyle(PapercupTheme.warning)
                    .background(PapercupTheme.warning.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(PapercupTheme.warning.opacity(0.42), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .disabled(pauseBusy)
            }

            if let pauseError {
                Text(pauseError)
                    .font(.caption.monospaced())
                    .foregroundStyle(PapercupTheme.error)
            }
        }
        .papercupCardContainer(accent: PapercupTheme.accent.opacity(0.12))
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
        let total = running.totalFeatures
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
                    if let lastActive = running.lastActiveTs {
                        Spacer()
                        Text(relativeTime(lastActive)).papercupMonoMeta()
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
            state = .ready(try await creds.client().runningSnapshot())
        } catch let err as ApiError {
            state = .failed("API: \(err)")
        } catch {
            state = .failed("Unexpected: \(error)")
        }
    }

    private func pauseOperator() {
        guard !pauseBusy else { return }
        pauseBusy = true
        pauseError = nil
        Task { @MainActor in
            do {
                _ = try await creds.client().pauseSet(paused: true)
                pauseDone = true
            } catch let err as ApiError {
                pauseError = "Pause failed: \(err)"
            } catch {
                pauseError = "Pause failed: \(error)"
            }
            pauseBusy = false
        }
    }

    private func displayRequestText(_ text: String?) -> String {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "(no request text)" : trimmed
    }

    private func relativeTime(_ timestampMs: Int64) -> String {
        let elapsed = max(0, Int(Date().timeIntervalSince1970 - (Double(timestampMs) / 1000.0)))
        if elapsed < 60 { return "\(elapsed)s" }
        if elapsed < 3_600 { return "\(elapsed / 60)m" }
        if elapsed < 86_400 { return "\(elapsed / 3_600)h" }
        return "\(elapsed / 86_400)d"
    }
}
