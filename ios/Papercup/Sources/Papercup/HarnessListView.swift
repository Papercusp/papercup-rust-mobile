// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct HarnessListView: View {
    let creds: DeviceCredentials
    let liveTick: Int
    let lastInvalidate: String?
    let onSelect: (String) -> Void


    enum LoadState {
        case loading
        case ready([Harness])
        case failed(String)
    }

    @State private var state: LoadState = .loading

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Harnesses")
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(PapercupTheme.inkRaised, for: .navigationBar)
                .toolbarColorScheme(.dark, for: .navigationBar)
                .task(id: "\(creds.deviceToken)|\(liveTick)") { await refetch() }
                .tint(PapercupTheme.accent)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .loading:
            ProgressView("Loading harnesses…")
                .tint(PapercupTheme.accent)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(PapercupTheme.screenGradient.ignoresSafeArea())
        case .failed(let msg):
            VStack(alignment: .leading, spacing: 8) {
                Text("Couldn't load harnesses").font(.headline).foregroundStyle(PapercupTheme.error)
                Text(msg).font(.footnote.monospaced()).foregroundStyle(PapercupTheme.error)
            }
            .padding()
            .background(PapercupTheme.cardBackground(accent: PapercupTheme.error.opacity(0.14)))
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(PapercupTheme.screenGradient.ignoresSafeArea())
        case .ready(let harnesses):
            List {
                Section {
                    HStack {
                        Text("\(harnesses.count) " +
                             (harnesses.count == 1 ? "harness" : "harnesses"))
                        .font(.headline)
                        Spacer()
                        if creds.defguardEnrollmentUrl != nil {
                            PapercupChip(text: "mesh", role: .accent)
                        }
                        PapercupChip(text: lastInvalidate.map { "live · \($0)" } ?? "live", role: .info)
                    }
                }
                    .papercupCardRow()
                Section {
                    ForEach(harnesses, id: \.slug) { h in
                        Button { onSelect(h.slug) } label: { HarnessRow(harness: h) }
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel(Text("Harness \(h.slug)\(h.status.map { ", status \($0)" } ?? ", no status")"))
                            .accessibilityHint(Text("Double-tap to open."))
                            .accessibilityAddTraits(.isButton)
                            .buttonStyle(.plain)
                    }
                }
                    .papercupCardRow()
                Section {
                    Text("core \(version()) · \(creds.server)")
                        .papercupMonoMeta()
                }
                    .papercupCardRow(accent: PapercupTheme.info.opacity(0.08))
            }
            .papercupScreenChrome()
        }
    }

    private func refetch() async {
        state = .loading
        do {
            let client = creds.client()
            let harnesses = try await client.listHarnesses()
            state = .ready(harnesses)
        } catch {
            state = .failed(FriendlyError.message(error, doing: "loading harnesses"))
        }
    }
}

private struct HarnessRow: View {
    let harness: Harness

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(harness.slug).font(.headline)
                Spacer()
                if let status = harness.status {
                    PapercupChip(text: status, role: .accent)
                }
            }
            if !harness.path.isEmpty {
                Text(harness.path).papercupMonoMeta()
            }
            let meta: [String] = {
                var bits: [String] = []
                if let k = harness.harnessKind { bits.append("kind=\(k)") }
                if let i = harness.iteration { bits.append("iter=\(i)") }
                if !harness.hasState { bits.append("no-state") }
                return bits
            }()
            if !meta.isEmpty {
                Text(meta.joined(separator: " · ")).font(.caption2).foregroundStyle(PapercupTheme.textMuted)
            }
        }
        .padding(.vertical, 2)
    }
}
