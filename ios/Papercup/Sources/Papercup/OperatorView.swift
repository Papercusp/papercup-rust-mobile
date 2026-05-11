// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct OperatorView: View {
    let creds: DeviceCredentials
    let invalidationTick: Int
    let onSelectHarness: (String) -> Void
    @ObservedObject var voice: VoiceManager

    @State private var paused: Bool? = nil
    @State private var lease: VoiceLease? = nil
    @State private var leaseUnknown: Bool = true
    @State private var running: [Running] = []
    @State private var harnesses: [Harness] = []
    @State private var toasts: [Toast] = []
    @State private var error: String? = nil

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    if let err = error { errorCard(err) }
                    HStack(spacing: 8) {
                        pauseCard
                        leaseCard
                    }
                    runningCard
                    if !harnesses.isEmpty { recentHarnessesCard }
                    if !toasts.isEmpty { recentNotificationsCard }
                    identityCard
                }
                .padding(16)
            }
            .navigationTitle("Operator")
            .task(id: "\(creds.deviceToken)|\(invalidationTick)") { await load() }
        }
    }

    private func errorCard(_ message: String) -> some View {
        Text(message)
            .font(.footnote.monospaced())
            .foregroundStyle(.red)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
    }

    private var pauseCard: some View {
        let isPaused = paused == true
        let label: String = paused == nil ? "…" : (isPaused ? "PAUSED" : "RUNNING")
        return Button {
            guard let p = paused else { return }
            Task {
                do {
                    paused = try await OperatorClient(baseUrl: creds.server, deviceToken: creds.deviceToken)
                        .pauseSet(paused: !p)
                } catch {
                    // Surface failures via the error card at the top of
                    // the screen rather than the previous silent swallow.
                    self.error = "pause toggle failed: \(error)"
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text("Operator").font(.caption)
                Text(label).font(.title3.bold())
                Text("tap to \(isPaused ? "resume" : "pause")").font(.caption)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(isPaused ? Color.red.opacity(0.15) : Color.gray.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .disabled(paused == nil)
    }

    private var leaseCard: some View {
        let title: String
        let sub: String
        let active = voice.state != .idle
        switch (leaseUnknown, lease, active) {
        case (_, _, true): title = "LISTENING"; sub = stateSub(voice.state)
        case (true, _, _): title = "…"; sub = ""
        case (false, nil, _): title = "IDLE"; sub = "tap to listen"
        case (_, let l?, _) where l.ownerId == creds.deviceId:
            title = "THIS PHONE"; sub = "tap to stop"
        case (_, let l?, _) where l.ownerKind == "mobile":
            title = "OTHER PHONE"; sub = String(l.ownerId.prefix(8)) + "…"
        case (_, let l?, _):
            title = "DESKTOP"; sub = String(l.ownerId.prefix(8)) + "…"
        }
        return Button {
            if active { voice.stop() } else { voice.start() }
        } label: {
            ZStack {
                if active {
                    Circle()
                        .fill(Color.cyan.opacity(0.25))
                        .frame(width: 80 + CGFloat(voice.micLevel) * 80,
                               height: 80 + CGFloat(voice.micLevel) * 80)
                        .animation(.easeOut(duration: 0.08), value: voice.micLevel)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Voice").font(.caption)
                    Text(title).font(.title3.bold())
                    Text(sub).font(.caption)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            }
            .background(active ? Color.cyan.opacity(0.15) : Color.gray.opacity(0.1),
                        in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
    }

    private func stateSub(_ s: VoiceManager.State) -> String {
        switch s {
        case .idle: return ""
        case .connecting: return "connecting…"
        case .listening: return "listening"
        case .speaking(_, let source): return "speaking · \(source)"
        case .failed(let m): return m.prefix(40) + ""
        }
    }

    private var runningCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Currently running").font(.headline)
                Spacer()
                Text("\(running.count)")
                    .font(.caption)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.gray.opacity(0.2), in: Capsule())
            }
            if running.isEmpty {
                Text("No active runs").font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(running, id: \.harnessSlug) { r in runningRow(r) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.gray.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
    }

    private func runningRow(_ r: Running) -> some View {
        Button { onSelectHarness(r.harnessSlug) } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(r.harnessSlug).font(.subheadline)
                    Spacer()
                    Text("\(r.phase) · \(r.status)").font(.caption)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(.gray.opacity(0.2), in: Capsule())
                }
                let blocked = r.blockedCount > 0 ? " · ⚠\(r.blockedCount)" : ""
                Text("✓\(r.passedCount) · ☐\(r.todoCount)\(blocked) · iter \(r.iteration)")
                    .font(.caption.monospaced())
                if !r.activeRoles.isEmpty {
                    Text("roles: \(r.activeRoles.joined(separator: ", "))").font(.caption)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }

    private var recentHarnessesCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recent harnesses").font(.headline)
            ForEach(harnesses.prefix(5), id: \.slug) { h in
                Button { onSelectHarness(h.slug) } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(h.slug).font(.subheadline)
                            let meta = harnessMeta(h)
                            if !meta.isEmpty {
                                Text(meta).font(.caption)
                            }
                        }
                        Spacer()
                        if let s = h.status {
                            Text(s).font(.caption).padding(.horizontal, 6).padding(.vertical, 2).background(.gray.opacity(0.2), in: Capsule())
                        }
                    }
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.gray.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
    }

    private var recentNotificationsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recent activity").font(.headline)
            ForEach(toasts.prefix(3), id: \.id) { t in
                VStack(alignment: .leading, spacing: 2) {
                    Text(t.message).font(.caption)
                    if let slug = t.harnessSlug {
                        Button(slug) { onSelectHarness(slug) }.font(.caption2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.gray.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
    }

    private var identityCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("This device").font(.headline)
            kv("workspace", creds.workspaceId)
            kv("device", String(creds.deviceId.prefix(12)) + "…")
            if let ip = creds.meshAssignedIp { kv("mesh", ip) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.gray.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
    }

    private func kv(_ key: String, _ value: String) -> some View {
        HStack {
            Text(key).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.caption.monospaced())
        }
    }

    private func harnessMeta(_ h: Harness) -> String {
        var bits: [String] = []
        if let k = h.harnessKind { bits.append("kind=\(k)") }
        if let i = h.iteration { bits.append("iter=\(i)") }
        if !h.hasState { bits.append("no-state") }
        return bits.joined(separator: " · ")
    }

    private func load() async {
        let client = OperatorClient(baseUrl: creds.server, deviceToken: creds.deviceToken)
        var anyOk = false
        var lastErr: String? = nil
        do { let p = try await client.pauseGet(); paused = p.paused; anyOk = true }
        catch { lastErr = "pause: \(error)" }
        do { lease = try await client.voiceLeaseGet(); leaseUnknown = false; anyOk = true }
        catch { lastErr = "lease: \(error)" }
        do { running = try await client.listRunning(); anyOk = true }
        catch { lastErr = "running: \(error)" }
        do {
            let raw = try await client.listHarnesses()
            harnesses = raw.sorted { ($0.lastActiveTs ?? 0) > ($1.lastActiveTs ?? 0) }
            anyOk = true
        } catch { lastErr = "harnesses: \(error)" }
        do { toasts = try await client.recentNotifications(); anyOk = true }
        catch { lastErr = "notifs: \(error)" }
        error = anyOk ? nil : lastErr
    }
}
