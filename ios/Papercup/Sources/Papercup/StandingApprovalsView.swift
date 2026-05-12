// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct StandingApprovalsView: View {
    let creds: DeviceCredentials

    @State private var candidates: [StandingCandidate]? = nil
    @State private var error: String? = nil
    @State private var pending: Set<String> = []
    @State private var hidden: Set<String> = []

    private func key(_ c: StandingCandidate) -> String { "\(c.capability)::\(c.targetHarness)" }

    private var visibleCandidates: [StandingCandidate] {
        (candidates ?? []).filter { !hidden.contains(key($0)) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                screenHeader
                blurbCard
                if let err = error {
                    errorCard(err)
                }
                contentSection
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 112)
        }
        .papercupScreenChrome()
        .navigationTitle("Standing approvals")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: creds.deviceToken) { await load() }
    }

    private var screenHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Standing approvals")
                .font(.title2.weight(.semibold))
                .foregroundStyle(PapercupTheme.text)
            HStack(spacing: 8) {
                Text("Review repeat silent-dispatch candidates.")
                    .font(.caption)
                    .foregroundStyle(PapercupTheme.textMuted)
                if candidates != nil {
                    PapercupChip(text: "\(visibleCandidates.count) PENDING", role: .muted)
                }
            }
        }
        .padding(.vertical, 10)
    }

    private var blurbCard: some View {
        Text("Patterns the operator has dispatched silently 3+ times in the last 24h. Approve to grant standing authority for this capability + target — future dispatches happen without prompting.")
            .font(.footnote)
            .foregroundStyle(PapercupTheme.textMuted)
            .papercupCardContainer(accent: PapercupTheme.info.opacity(0.10))
    }

    @ViewBuilder
    private var contentSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            PapercupSectionTitle(text: "Pending")
            if candidates == nil {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(PapercupTheme.accent)
                    Text(NSLocalizedString("loading", comment: ""))
                        .font(.callout)
                        .foregroundStyle(PapercupTheme.textMuted)
                }
                .papercupCardContainer(accent: PapercupTheme.info.opacity(0.08))
            } else if visibleCandidates.isEmpty {
                Text("No standing-approval candidates.")
                    .font(.callout)
                    .foregroundStyle(PapercupTheme.textMuted)
                    .papercupCardContainer(accent: PapercupTheme.info.opacity(0.08))
            } else {
                ForEach(Array(visibleCandidates.enumerated()), id: \.offset) { _, candidate in
                    candidateCard(candidate)
                }
            }
        }
    }

    private func candidateCard(_ c: StandingCandidate) -> some View {
        let k = key(c)
        let busy = pending.contains(k)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(c.capability)
                        .font(.system(.subheadline, design: .monospaced).weight(.medium))
                        .foregroundStyle(PapercupTheme.accentStrong)
                        .lineLimit(2)
                    Text("→ \(c.targetHarness)")
                        .font(.caption)
                        .foregroundStyle(PapercupTheme.textMuted)
                }
                Spacer(minLength: 12)
                PapercupChip(text: "\(c.count)×", role: .muted)
            }

            Text("Last seen \(c.lastSeenAt)")
                .papercupMonoMeta()

            HStack(spacing: 10) {
                Button { decide(c, approve: true) } label: {
                    decisionButtonLabel(
                        title: busy ? "…" : NSLocalizedString("standing.approve", comment: ""),
                        fill: LinearGradient(
                            colors: [PapercupTheme.accentStrong.opacity(0.96), PapercupTheme.accent.opacity(0.82)],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        foreground: PapercupTheme.ink
                    )
                }
                .buttonStyle(.plain)
                .disabled(busy)

                Button { decide(c, approve: false) } label: {
                    decisionButtonLabel(
                        title: NSLocalizedString("standing.dismiss", comment: ""),
                        fill: LinearGradient(
                            colors: [Color.white.opacity(0.08), Color.white.opacity(0.03)],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        foreground: PapercupTheme.text
                    )
                }
                .buttonStyle(.plain)
                .disabled(busy)
            }
        }
        .papercupCardContainer(accent: PapercupTheme.accent.opacity(0.08))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Candidate \(c.capability), target \(c.targetHarness), seen \(c.count) times."))
    }

    private func decisionButtonLabel(title: String, fill: LinearGradient, foreground: Color) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(foreground)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(fill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(PapercupTheme.stroke.opacity(0.65), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.24), radius: 10, x: 0, y: 6)
    }

    private func errorCard(_ message: String) -> some View {
        Text(message)
            .font(.footnote.monospaced())
            .foregroundStyle(PapercupTheme.error)
            .papercupCardContainer(accent: PapercupTheme.error.opacity(0.16))
    }

    private func load() async {
        do {
            candidates = try await creds.client().standingCandidates()
            error = nil
        } catch {
            self.error = "\(error)"
        }
    }

    private func decide(_ c: StandingCandidate, approve: Bool) {
        let k = key(c)
        pending.insert(k)
        hidden.insert(k)
        Task {
            do {
                try await creds.client()
                    .standingCandidateDecide(capability: c.capability, targetHarness: c.targetHarness, approve: approve)
            } catch {
                self.error = "\(error)"
                hidden.remove(k)
            }
            pending.remove(k)
        }
    }
}
