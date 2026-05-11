// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import Foundation

struct LogLine: Identifiable, Equatable {
    let id = UUID()
    let ts: String
    let source: String
    let level: String
    let msg: String
}

private let MAX_LINES = 500

struct RunLogView: View {
    let creds: DeviceCredentials
    let slug: String

    @State private var lines: [LogLine] = []
    @State private var error: String? = nil
    @State private var filter: String = "all"
    @State private var streamTask: Task<Void, Never>? = nil

    private var visible: [LogLine] {
        switch filter {
        case "warn":  return lines.filter { $0.level == "warn" || $0.level == "error" }
        case "error": return lines.filter { $0.level == "error" }
        default:      return lines
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $filter) {
                    Text("all").tag("all")
                    Text("warn").tag("warn")
                    Text("error").tag("error")
                }
                .pickerStyle(.segmented)
                Spacer()
                Text("\(visible.count)/\(lines.count)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)

            if let err = error {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.1))
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(visible) { l in lineRow(l) }
                    }
                    .padding(.horizontal, 6)
                }
                .background(Color.black)
                .onChange(of: lines.count) { _, _ in
                    if let last = visible.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }
        }
        .navigationTitle("Run log")
        .task(id: slug + creds.deviceToken) { await stream() }
        .onDisappear { streamTask?.cancel() }
    }

    private func lineRow(_ l: LogLine) -> some View {
        let color: Color = switch l.level {
        case "error":     .red
        case "warn":      .orange
        case "decision":  .cyan
        case "iteration": .green
        case "plan":      .purple
        default:          Color(white: 0.85)
        }
        let time = String(l.ts.suffix(13).prefix(8))
        return Text("\(time) \(l.source) \(l.msg)")
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func stream() async {
        streamTask?.cancel()
        lines = []
        error = nil
        streamTask = Task {
            guard let url = URL(string: "\(creds.server)/api/mobile/harnesses/\(slug)/log/stream?tail=\(MAX_LINES)") else {
                error = "bad url"; return
            }
            var req = URLRequest(url: url)
            req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            req.setValue("Bearer \(creds.deviceToken)", forHTTPHeaderField: "Authorization")
            req.timeoutInterval = TimeInterval.infinity
            do {
                let (bytes, resp) = try await URLSession.shared.bytes(for: req)
                if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
                    if http.statusCode == 401 {
                        error = "log stream not available to mobile (cookie-auth only). Awaiting backend mobile-JWT variant."
                    } else {
                        error = "stream failed: HTTP \(http.statusCode)"
                    }
                    return
                }
                var currentEvent = ""
                for try await line in bytes.lines {
                    if Task.isCancelled { return }
                    if line.hasPrefix("event:") {
                        currentEvent = String(line.dropFirst("event:".count)).trimmingCharacters(in: .whitespaces)
                    } else if line.hasPrefix("data:") {
                        let data = String(line.dropFirst("data:".count)).trimmingCharacters(in: .whitespaces)
                        if currentEvent == "log",
                           let d = data.data(using: .utf8),
                           let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                            let ll = LogLine(
                                ts: obj["ts"] as? String ?? "",
                                source: obj["source"] as? String ?? "",
                                level: obj["level"] as? String ?? "info",
                                msg: obj["msg"] as? String ?? data
                            )
                            await MainActor.run {
                                lines.append(ll)
                                if lines.count > MAX_LINES { lines.removeFirst(lines.count - MAX_LINES) }
                            }
                        }
                    }
                }
            } catch {
                if !Task.isCancelled { self.error = "\(error)" }
            }
        }
    }
}
