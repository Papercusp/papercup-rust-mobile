// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import PapercupCore

struct HarnessListView: View {
    let creds: DeviceCredentials
    let liveTick: Int
    let lastInvalidate: String?
    let onSelect: (String) -> Void
    let onForget: () -> Void

    enum LoadState {
        case loading
        case ready([Harness])
        case failed(String)
    }

    @State private var state: LoadState = .loading

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Papercup")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button("Forget device", role: .destructive, action: onForget)
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                }
                .task(id: "\(creds.deviceToken)|\(liveTick)") { await refetch() }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .loading:
            ProgressView("Loading harnesses…")
        case .failed(let msg):
            VStack(alignment: .leading, spacing: 8) {
                Text("Couldn't load harnesses").font(.headline)
                Text(msg).font(.footnote.monospaced())
            }
            .padding()
        case .ready(let harnesses):
            List {
                Section {
                    HStack {
                        Text("\(harnesses.count) " +
                             (harnesses.count == 1 ? "harness" : "harnesses"))
                        .font(.headline)
                        Spacer()
                        if let ip = creds.meshAssignedIp {
                            Text("mesh · \(ip)")
                                .font(.caption)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(.gray.opacity(0.2), in: Capsule())
                        }
                        Text(lastInvalidate.map { "live · \($0)" } ?? "live")
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.gray.opacity(0.2), in: Capsule())
                    }
                }
                Section {
                    ForEach(harnesses, id: \.slug) { h in
                        Button { onSelect(h.slug) } label: { HarnessRow(harness: h) }
                            .buttonStyle(.plain)
                    }
                }
                Section {
                    Text("core \(version()) · \(creds.server)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func refetch() async {
        state = .loading
        do {
            let client = OperatorClient(baseUrl: creds.server, deviceToken: creds.deviceToken)
            let harnesses = try await client.listHarnesses()
            state = .ready(harnesses)
        } catch let err as ApiError {
            state = .failed("API: \(err)")
        } catch {
            state = .failed("Unexpected: \(error)")
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
                    Text(status)
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.gray.opacity(0.2), in: Capsule())
                }
            }
            if !harness.path.isEmpty {
                Text(harness.path).font(.caption.monospaced())
            }
            let meta: [String] = {
                var bits: [String] = []
                if let k = harness.harnessKind { bits.append("kind=\(k)") }
                if let i = harness.iteration { bits.append("iter=\(i)") }
                if !harness.hasState { bits.append("no-state") }
                return bits
            }()
            if !meta.isEmpty {
                Text(meta.joined(separator: " · ")).font(.caption2)
            }
        }
        .padding(.vertical, 2)
    }
}
