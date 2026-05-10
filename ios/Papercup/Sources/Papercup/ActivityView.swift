// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct ActivityView: View {
    let creds: DeviceCredentials
    let invalidationTick: Int
    let onSelectHarness: (String) -> Void

    enum Tab: Int, CaseIterable, Identifiable {
        case notifications, actions
        var id: Int { rawValue }
        var label: String { self == .notifications ? "Notifications" : "Actions" }
    }

    @State private var tab: Tab = .notifications
    @State private var toasts: [Toast] = []
    @State private var actions: [AuditEntry] = []
    @State private var error: String? = nil

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Tab", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding()

                if let err = error {
                    Text(err).font(.footnote.monospaced()).foregroundStyle(.red).padding()
                }

                List {
                    switch tab {
                    case .notifications:
                        if toasts.isEmpty {
                            Text("No recent notifications").font(.callout).foregroundStyle(.secondary)
                        } else {
                            ForEach(toasts, id: \.id) { toastRow($0) }
                        }
                    case .actions:
                        if actions.isEmpty {
                            Text("No recent actions").font(.callout).foregroundStyle(.secondary)
                        } else {
                            ForEach(actions, id: \.id) { auditRow($0) }
                        }
                    }
                }
            }
            .navigationTitle("Activity")
            .task(id: "\(creds.deviceToken)|\(invalidationTick)") { await load() }
        }
    }

    private func toastRow(_ t: Toast) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(t.message).font(.subheadline)
                Spacer()
                Text(t.level)
                    .font(.caption)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(levelColor(t.level), in: Capsule())
            }
            if let d = t.description, !d.isEmpty {
                Text(d).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Text(formatTs(t.createdAt)).font(.caption.monospaced()).foregroundStyle(.secondary)
                Spacer()
                if let slug = t.harnessSlug {
                    Button(slug) { onSelectHarness(slug) }.font(.caption)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func auditRow(_ e: AuditEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(e.action).font(.subheadline)
                Spacer()
                Text(formatTs(e.ts)).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            Text("by \(e.actor)").font(.caption).foregroundStyle(.secondary)
            HStack {
                Text(e.subject).font(.caption.monospaced()).foregroundStyle(.secondary)
                Spacer()
                if let slug = harnessSlugFromSubject(e.subject) {
                    Button(slug) { onSelectHarness(slug) }.font(.caption)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func levelColor(_ level: String) -> Color {
        switch level.lowercased() {
        case "error": return .red.opacity(0.2)
        case "warning", "warn": return .orange.opacity(0.2)
        case "success": return .green.opacity(0.2)
        default: return .gray.opacity(0.2)
        }
    }

    private func harnessSlugFromSubject(_ s: String) -> String? {
        guard s.hasPrefix("harness:") else { return nil }
        let rest = s.dropFirst("harness:".count)
        let slug = rest.split(separator: ":").first.map(String.init) ?? String(rest)
        return slug.isEmpty ? nil : slug
    }

    private func formatTs(_ unix: Int64) -> String {
        let f = DateFormatter()
        f.dateFormat = "MMM d HH:mm"
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(unix)))
    }

    private func load() async {
        do {
            let client = OperatorClient(baseUrl: creds.server, deviceToken: creds.deviceToken)
            async let t = client.recentNotifications()
            async let a = client.recentActions()
            toasts = try await t
            actions = try await a
            error = nil
        } catch let err as ApiError {
            error = "API: \(err)"
        } catch let e {
            error = "Unexpected: \(e)"
        }
    }
}
