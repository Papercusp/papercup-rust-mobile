// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import PapercupCore

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
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(action: onBack) {
                            Image(systemName: "chevron.left")
                        }
                    }
                }
                .task(id: "\(slug)|\(invalidationTick)") { await refetch() }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .loading:
            ProgressView("Loading status…")
        case .failed(let msg):
            VStack(alignment: .leading, spacing: 8) {
                Text(msg).font(.footnote.monospaced()).foregroundStyle(.red)
            }
            .padding()
        case .ready(let s):
            List {
                Section {
                    HStack {
                        Text(s.slug).font(.title3.bold())
                        Spacer()
                        Text(s.status)
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.gray.opacity(0.2), in: Capsule())
                    }
                    KeyValueRow(key: "iteration", value: "\(s.iteration)")
                    if let ts = s.lastActiveTs {
                        let date = Date(timeIntervalSince1970: TimeInterval(ts))
                        KeyValueRow(key: "last active", value: Self.fmt.string(from: date))
                    }
                }
                Section("More detail coming") {
                    Text(
                        "Cost / tokens / last decision / pending checkpoints / smoke / " +
                        "alive — pending a backend update to /api/mobile/harnesses/:slug."
                    )
                    .font(.caption)
                }
            }
        }
    }

    private func refetch() async {
        state = .loading
        do {
            let client = OperatorClient(baseUrl: creds.server, deviceToken: creds.deviceToken)
            let s = try await client.getHarnessStatus(slug: slug)
            state = .ready(s)
        } catch let err as ApiError {
            state = .failed("API: \(err)")
        } catch {
            state = .failed("Unexpected: \(error)")
        }
    }

    private static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()
}

private struct KeyValueRow: View {
    let key: String
    let value: String
    var body: some View {
        HStack {
            Text(key).font(.footnote).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.footnote.monospaced())
        }
    }
}
