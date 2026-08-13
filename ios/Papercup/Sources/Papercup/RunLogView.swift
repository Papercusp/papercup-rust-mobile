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
    let onBack: () -> Void

    @State private var lines: [LogLine] = []
    @State private var error: String? = nil
    @State private var filter: String = "all"
    @State private var streamTask: Task<Void, Never>? = nil

    private var visible: [LogLine] {
        switch filter {
        case "warn":
            return lines.filter { $0.level == "warn" || $0.level == "error" }
        case "error":
            return lines.filter { $0.level == "error" }
        default:
            return lines
        }
    }

    var body: some View {
        ZStack {
            PapercupTheme.screenGradient.ignoresSafeArea()

            VStack(spacing: 12) {
                header
                    .padding(.horizontal, 16)
                    .padding(.top, 8)

                filterTray
                    .padding(.horizontal, 16)

                if let err = error {
                    errorBanner(err)
                        .padding(.horizontal, 16)
                }

                terminalBody
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
            }
        }
        .task(id: slug + creds.deviceToken) { await stream() }
        .onDisappear { streamTask?.cancel() }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(PapercupTheme.accentStrong)
                    .frame(width: 36, height: 36)
                    .background(PapercupTheme.accent.opacity(0.10), in: Circle())
                    .overlay(Circle().stroke(PapercupTheme.accentStrong.opacity(0.32), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Back"))

            VStack(alignment: .leading, spacing: 4) {
                Text("Run log")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(PapercupTheme.text)
                Text(slug)
                    .font(.caption.monospaced())
                    .foregroundStyle(PapercupTheme.textMuted)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 4) {
                headerBadge("Live")
                Text("\(visible.count)/\(lines.count)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(PapercupTheme.textMuted)
            }
        }
        .padding(14)
        .background(PapercupTheme.cardBackground(accent: PapercupTheme.accent.opacity(0.12)))
    }

    private var filterTray: some View {
        HStack(spacing: 8) {
            filterPill("all", label: "ALL")
            filterPill("warn", label: "WARN+")
            filterPill("error", label: "ERROR")
            Spacer(minLength: 8)
            Text(lines.isEmpty ? "Awaiting events" : "Streaming")
                .font(.caption.weight(.medium))
                .foregroundStyle(PapercupTheme.textMuted)
        }
        .padding(10)
        .background(PapercupTheme.cardBackground(accent: PapercupTheme.info.opacity(0.08)))
    }

    private var terminalBody: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color.black.opacity(0.95))
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(PapercupTheme.stroke.opacity(0.80), lineWidth: 1)
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 8) {
                        Circle().fill(PapercupTheme.error).frame(width: 8, height: 8)
                        Circle().fill(PapercupTheme.warning).frame(width: 8, height: 8)
                        Circle().fill(PapercupTheme.success).frame(width: 8, height: 8)
                        Text("STREAM")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(PapercupTheme.textMuted)
                            .tracking(0.8)
                        Spacer(minLength: 8)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(PapercupTheme.ink.opacity(0.85))

                    if lines.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(error == nil ? "No log lines yet." : "Log stream unavailable.")
                                .font(.callout.weight(.medium))
                                .foregroundStyle(PapercupTheme.text)
                            Text(error == nil ? "Waiting for the next harness event." : "Check your connection or pair this iPhone again if access expired.")
                                .font(.caption)
                                .foregroundStyle(PapercupTheme.textMuted)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                        .padding(18)
                    } else if visible.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("No lines match the current filter.")
                                .font(.callout.weight(.medium))
                                .foregroundStyle(PapercupTheme.text)
                            Text("Showing \(lines.count) captured events. Switch back to ALL to inspect the full stream.")
                                .font(.caption)
                                .foregroundStyle(PapercupTheme.textMuted)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                        .padding(18)
                    } else {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 6) {
                                ForEach(visible) { line in
                                    lineRow(line)
                                        .id(line.id)
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 12)
                        }
                        .onChange(of: visible.count) { _, _ in
                            if let last = visible.last {
                                withAnimation(.easeOut(duration: 0.16)) {
                                    proxy.scrollTo(last.id, anchor: .bottom)
                                }
                            }
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            }
        }
    }

    private func filterPill(_ value: String, label: String) -> some View {
        let selected = filter == value
        let foreground = selected ? PapercupTheme.ink : PapercupTheme.textMuted
        let background = selected ? PapercupTheme.accentStrong : PapercupTheme.inkRaised.opacity(0.92)
        let stroke = selected ? PapercupTheme.accentStrong.opacity(0.20) : PapercupTheme.stroke.opacity(0.80)
        return Button {
            filter = value
        } label: {
            Text(label)
                .font(.caption.weight(.semibold))
                .tracking(0.8)
                .foregroundStyle(foreground)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(background, in: Capsule())
                .overlay(Capsule().stroke(stroke, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func headerBadge(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.caption2.weight(.semibold))
            .foregroundStyle(PapercupTheme.accentStrong)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(PapercupTheme.accent.opacity(0.12), in: Capsule())
            .overlay(Capsule().stroke(PapercupTheme.accentStrong.opacity(0.32), lineWidth: 1))
    }

    private func errorBanner(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(PapercupTheme.error)
                .frame(width: 8, height: 8)
                .padding(.top, 4)
            Text(text)
                .font(.caption.monospaced())
                .foregroundStyle(PapercupTheme.error)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(PapercupTheme.cardBackground(accent: PapercupTheme.error.opacity(0.14)))
    }

    private func lineRow(_ line: LogLine) -> some View {
        let tone: Color = switch line.level {
        case "error":
            PapercupTheme.error
        case "warn":
            PapercupTheme.warning
        case "decision":
            PapercupTheme.accentStrong
        case "iteration":
            PapercupTheme.success
        case "plan":
            Color.purple
        default:
            Color(red: 0.82, green: 0.87, blue: 0.92)
        }

        let time = String(line.ts.suffix(13).prefix(8))

        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(time)
                    .foregroundStyle(PapercupTheme.textMuted)
                Text(line.source.isEmpty ? "system" : line.source)
                    .foregroundStyle(PapercupTheme.textMuted.opacity(0.90))
                Text(line.level.uppercased())
                    .foregroundStyle(tone.opacity(0.92))
            }
            Text(line.msg)
                .foregroundStyle(tone)
                .textSelection(.enabled)
        }
        .font(.system(.caption, design: .monospaced))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 1)
    }

    private func stream() async {
        streamTask?.cancel()
        lines = []
        error = nil
        streamTask = Task {
            guard let url = URL(string: "\(creds.server)/api/device/harnesses/\(slug)/log/stream?tail=\(MAX_LINES)") else {
                error = "bad url"
                return
            }
            var req = URLRequest(url: url)
            req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            req.setValue("Bearer \(creds.deviceToken)", forHTTPHeaderField: "Authorization")
            req.timeoutInterval = TimeInterval.infinity
            do {
                let (bytes, resp) = try await URLSession.shared.bytes(for: req)
                if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
                    if http.statusCode == 401 {
                        error = "Pairing authorization expired. Pair this iPhone again to restore run-log access."
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
                           let payload = data.data(using: .utf8),
                           let obj = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] {
                            let next = LogLine(
                                ts: obj["ts"] as? String ?? "",
                                source: obj["source"] as? String ?? "",
                                level: obj["level"] as? String ?? "info",
                                msg: obj["msg"] as? String ?? data
                            )
                            await MainActor.run {
                                lines.append(next)
                                if lines.count > MAX_LINES {
                                    lines.removeFirst(lines.count - MAX_LINES)
                                }
                            }
                        }
                    }
                }
            } catch {
                if !Task.isCancelled {
                    self.error = FriendlyError.message(error, doing: "streaming the run log")
                }
            }
        }
    }
}
