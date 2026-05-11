// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct StandingApprovalsView: View {
    let creds: DeviceCredentials

    @State private var candidates: [StandingCandidate]? = nil
    @State private var error: String? = nil
    @State private var pending: Set<String> = []
    @State private var hidden: Set<String> = []

    private func key(_ c: StandingCandidate) -> String { "\(c.capability)::\(c.targetHarness)" }

    var body: some View {
        List {
            Section {
                Text("Patterns the operator has dispatched silently 3+ times in the last 24h. Approve to grant standing authority for this capability + target.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let err = error {
                Section { Text(err).font(.footnote.monospaced()).foregroundStyle(.red) }
            }
            let visible = (candidates ?? []).filter { !hidden.contains(key($0)) }
            if let cs = candidates, cs.isEmpty || visible.isEmpty {
                Section { Text("No standing-approval candidates.").foregroundStyle(.secondary) }
            } else if candidates == nil {
                Section { ProgressView() }
            } else {
                ForEach(visible, id: \.capability) { c in row(c) }
            }
        }
        .navigationTitle("Standing approvals")
        .task(id: creds.deviceToken) { await load() }
    }

    @ViewBuilder
    private func row(_ c: StandingCandidate) -> some View {
        let k = key(c)
        let busy = pending.contains(k)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                Text(c.capability).font(.system(.body, design: .monospaced)).lineLimit(2)
                Spacer()
                Text("\(c.count)×").font(.caption).foregroundStyle(.secondary)
            }
            Text("→ \(c.targetHarness)").font(.caption).foregroundStyle(.secondary)
            Text("last seen \(c.lastSeenAt)").font(.caption2).foregroundStyle(.tertiary)
            HStack(spacing: 8) {
                Button { decide(c, approve: true) } label: {
                    Text(busy ? "…" : "Approve").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(busy)

                Button { decide(c, approve: false) } label: {
                    Text(NSLocalizedString("standing.dismiss", comment: "")).frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(busy)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Candidate \(c.capability), target \(c.targetHarness), seen \(c.count) times."))
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
