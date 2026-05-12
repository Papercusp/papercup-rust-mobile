// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import os.log

/// Mirrors Android's PairedShell — Tauri-style tab nav (Operator /
/// Harness / Running / Inbox / Settings) plus pushed routes.
struct AppRoot: View {
    @State private var creds: DeviceCredentials? = CredentialStore.load()
    @State private var liveTick: Int = 0
    @State private var lastInvalidate: String? = nil
    @State private var pushedDetailSlug: String? = nil
    @State private var pushedRunLogSlug: String? = nil
    @EnvironmentObject private var deepLink: DeepLinkRouter

    enum Tab: Hashable { case operatorTab, harnesses, running, activity, settings }
    @State private var tab: Tab = .operatorTab

    var body: some View {
        Group {
            if let current = creds {
                PairedShell(
                    current: current,
                    tab: $tab,
                    liveTick: $liveTick,
                    lastInvalidate: $lastInvalidate,
                    pushedDetailSlug: $pushedDetailSlug,
                    pushedRunLogSlug: $pushedRunLogSlug,
                    deepLink: deepLink,
                    onForget: {
                        CredentialStore.clear()
                        creds = nil
                    },
                    onWorkspaceSwitched: { fresh in
                        CredentialStore.save(fresh)
                        creds = fresh
                    }
                )
                .id(current.deviceToken)
            } else {
                PairView { fresh in
                    CredentialStore.save(fresh)
                    creds = fresh
                    tab = .operatorTab
                }
                .onChange(of: deepLink.pendingPair) { _, new in
                    if let p = new { Task { await autoPair(p) } }
                }
                .onAppear {
                    if let p = deepLink.pendingPair { Task { await autoPair(p) } }
                }
            }
        }
    }

    /// Consume a pendingPair (papercup://pair?...) without going through
    /// PairView. Mirrors PairView.redeem(): generate WG key + POST
    /// /api/mobile/pair + persist DeviceCredentials. Used for pair-by-link
    /// (email, scanning a QR with the system camera, etc.).
    @MainActor
    private func autoPair(_ p: PendingPair) async {
        let log = OSLog(subsystem: "com.papercuspai.operator.mobile", category: "AutoPair")
        os_log(.info, log: log, "starting server=%{public}@ ws=%{public}@",
               p.server, p.workspaceId)
        deepLink.pendingPair = nil
        let keys = generateWgKeypair()
        let client = OperatorClient(baseUrl: p.server, deviceToken: nil)
        do {
            let outcome = try await client.pair(
                pairToken: p.pairToken,
                wireguardPubkeyB64: keys.publicKeyB64
            )
            os_log(.info, log: log, "pair OK deviceId=%{public}@", outcome.deviceId)
            let wgQuick = outcome.mesh.map { meshToWgQuick(privateKeyB64: keys.privateKeyB64, config: $0) }
            let fresh = DeviceCredentials(
                server: p.server,
                deviceToken: outcome.deviceToken,
                deviceId: outcome.deviceId,
                workspaceId: outcome.workspaceId,
                meshAssignedIp: outcome.mesh?.assignedIp,
                wgQuickConfig: wgQuick,
                wgPrivateKey: outcome.mesh != nil ? keys.privateKeyB64 : nil,
                meshUrl: outcome.desktopMeshUrl
            )
            CredentialStore.save(fresh)
            creds = fresh
            tab = .operatorTab
        } catch {
            os_log(.info, log: log, "FAILED %{public}@", String(describing: error))
        }
    }
}

private struct PairedShell: View {
    let current: DeviceCredentials
    @Binding var tab: AppRoot.Tab
    @Binding var liveTick: Int
    @Binding var lastInvalidate: String?
    @Binding var pushedDetailSlug: String?
    @Binding var pushedRunLogSlug: String?
    @ObservedObject var deepLink: DeepLinkRouter
    let onForget: () -> Void
    let onWorkspaceSwitched: (DeviceCredentials) -> Void

    @StateObject private var monitor: ConnectionMonitor
    @StateObject private var voice: VoiceManager
    @StateObject private var cacheHost: CacheHost
    @StateObject private var badgeHost: ShellBadgeHost
    private let wakeWord: WakeWordEngine

    init(current: DeviceCredentials,
         tab: Binding<AppRoot.Tab>,
         liveTick: Binding<Int>,
         lastInvalidate: Binding<String?>,
         pushedDetailSlug: Binding<String?>,
         pushedRunLogSlug: Binding<String?>,
         deepLink: DeepLinkRouter,
         onForget: @escaping () -> Void,
         onWorkspaceSwitched: @escaping (DeviceCredentials) -> Void) {
        self.current = current
        self._tab = tab
        self._liveTick = liveTick
        self._lastInvalidate = lastInvalidate
        self._pushedDetailSlug = pushedDetailSlug
        self._pushedRunLogSlug = pushedRunLogSlug
        self.deepLink = deepLink
        self.onForget = onForget
        self.onWorkspaceSwitched = onWorkspaceSwitched
        let voiceState = StateObject(wrappedValue: VoiceManager(creds: current))
        self._monitor = StateObject(wrappedValue: ConnectionMonitor(creds: current))
        self._voice = voiceState
        self._cacheHost = StateObject(wrappedValue: CacheHost(creds: current))
        self._badgeHost = StateObject(wrappedValue: ShellBadgeHost(creds: current))
        let voiceRef = voiceState
        self.wakeWord = WakeWordEngine { [voiceRef] in
            Task { @MainActor in voiceRef.wrappedValue.start() }
        }
    }

    var body: some View {
        let onSelectHarness: (String) -> Void = { slug in
            pushedRunLogSlug = nil
            pushedDetailSlug = slug
        }
        let onOpenPushRoute: (PushTapTestRoute) -> Void = { route in
            switch route {
            case .harnessDetail(let slug):
                tab = .harnesses
                pushedRunLogSlug = nil
                pushedDetailSlug = slug
            case .runLog(let slug):
                tab = .running
                pushedDetailSlug = nil
                pushedRunLogSlug = slug
            case .operatorTab:
                pushedDetailSlug = nil
                pushedRunLogSlug = nil
                tab = .operatorTab
            case .inbox:
                pushedDetailSlug = nil
                pushedRunLogSlug = nil
                tab = .activity
            }
        }


        VStack(spacing: 0) {
            if monitor.state.status == .offline {
                OfflineBanner(state: monitor.state)
            }
            PausedBanner(creds: current)
            VoiceErrorBanner(voice: voice)
            ZStack {
                Group {
                    switch tab {
                    case .operatorTab:
                        OperatorView(
                            creds: current,
                            invalidationTick: liveTick,
                            onSelectHarness: onSelectHarness,
                            voice: voice
                        )
                    case .harnesses:
                        HarnessListView(
                            creds: current,
                            liveTick: liveTick,
                            lastInvalidate: lastInvalidate,
                            onSelect: onSelectHarness
                        )
                    case .running:
                        RunningView(
                            creds: current,
                            invalidationTick: liveTick,
                            onSelectHarness: onSelectHarness
                        )
                    case .activity:
                        ActivityView(
                            creds: current,
                            invalidationTick: liveTick,
                            onSelectHarness: onSelectHarness
                        )
                    case .settings:
                        SettingsView(
                            creds: current,
                            monitor: monitor,
                            onForget: onForget,
                            onWorkspaceSwitched: onWorkspaceSwitched,
                            onOpenPushRoute: onOpenPushRoute
                        )
                    }
                }

                if let slug = pushedDetailSlug {
                    HarnessDetailView(
                        creds: current,
                        slug: slug,
                        invalidationTick: liveTick,
                        onBack: {
                            pushedRunLogSlug = nil
                            pushedDetailSlug = nil
                        },
                        onOpenRunLog: { pushedRunLogSlug = slug }
                    )
                    .transition(.move(edge: .trailing))
                }
                if let slug = pushedRunLogSlug {
                    RunLogView(
                        creds: current,
                        slug: slug,
                        onBack: { pushedRunLogSlug = nil }
                    )
                    .transition(.move(edge: .trailing))
                }

                VoicePill(voice: voice)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(.trailing, 16)
                    .padding(.bottom, 76)
            }
            MobileBottomNav(tab: $tab, counts: badgeHost.counts)
        }
        .task(id: current.deviceToken) { monitor.start(); await runSync() }
        .onReceive(cacheHost.$tick) { _ in
            // Bump the SSE-shared liveTick so existing screens that
            // observe `invalidationTick: liveTick` refresh when any
            // cache-tracked query refetches.
            liveTick += 1
        }
        .task(id: current.deviceToken) {
            await badgeHost.run()
        }
        .onChange(of: voice.state) { _, new in
            if new == .idle { wakeWord.start() } else { wakeWord.stop() }
        }
        .onChange(of: voice.pendingIntent) { _, new in
            // Voice intent dispatch — every `browser: 'required'` client-
            // tool call from the EL agent surfaces here and maps to a
            // native action. iOS uses the custom Tauri-style tab binding
            // plus pushedDetailSlug; voice-settings + standing-approvals
            // are sub-screens of the Settings tab, so we tab-switch to
            // Settings for those (user drills in one tap).
            guard let intent = new else { return }
            switch intent {
            case .navigateHarness(let slug):
                pushedDetailSlug = slug
            case .navigateTab(let target):
                tab = switch target {
                    case .operatorTab: .operatorTab
                    case .harnesses: .harnesses
                    case .activity: .activity
                    case .settings: .settings
                }
            case .navigateVoiceSettings, .navigateStandingApprovals:
                tab = .settings
            case .pause:
                Task { try? await current.client().pauseSet(paused: true) }
            case .resume:
                Task { try? await current.client().pauseSet(paused: false) }
            case .claimVoice:
                Task { try? await current.client().voiceLeaseClaim() }
            case .voiceSetMode(let mode):
                switch mode.lowercased() {
                case "on", "start", "listening": voice.start()
                case "off", "stop", "idle": voice.stop()
                default: break
                }
            case .workspaceSwitch(let id):
                Task { _ = try? await current.client().workspaceSwitch(workspaceId: id) }
            }
            voice.pendingIntent = nil
        }
        .onChange(of: deepLink.pendingSlug) { _, new in
            if let slug = new {
                pushedDetailSlug = slug
                deepLink.pendingSlug = nil
            }
        }
        .onAppear {
            if voice.state == .idle { wakeWord.start() }
            if let slug = deepLink.pendingSlug {
                pushedDetailSlug = slug
                deepLink.pendingSlug = nil
            }
        }
        .onDisappear { monitor.stop(); voice.stop(); wakeWord.stop() }
    }

    private func runSync() async {
        // Cache lives on cacheHost (@StateObject) so it survives SSE
        // reconnects + lets the UI observe deltas via cacheHost.tick.
        let stream = SyncStream(baseUrl: current.server, deviceToken: current.deviceToken)
        defer { stream.disconnect() }
        while !Task.isCancelled {
            do {
                let ev = try await stream.nextEvent()
                lastInvalidate = ev.name
                await cacheHost.handleInvalidate(ev.name)
                if Self.shouldRefreshBadges(for: ev.name) {
                    Task { await badgeHost.refresh() }
                }
                if ev.name.hasPrefix("harness") {
                    liveTick += 1
                }
            } catch {
                break
            }
        }
    }

    private static func shouldRefreshBadges(for invalidateName: String) -> Bool {
        invalidateName == "toastLog.recent"
            || invalidateName == "auditLog.recent"
            || invalidateName == "operatorScans.running"
            || invalidateName.hasPrefix("operatorScans.")
    }
}


private struct ShellBadgeCounts: Equatable {
    var pendingCards: Int = 0
    var recentAlerts: Int = 0
}

@MainActor
private final class ShellBadgeHost: ObservableObject {
    @Published private(set) var counts = ShellBadgeCounts()

    private let creds: DeviceCredentials

    init(creds: DeviceCredentials) {
        self.creds = creds
    }

    func run() async {
        await refresh()
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            if Task.isCancelled { break }
            await refresh()
        }
    }

    func refresh() async {
        let client = creds.client()
        let fresh = ShellBadgeCounts(
            pendingCards: await pendingCardCount(client: client),
            recentAlerts: await recentAlertCount(client: client)
        )
        if counts != fresh {
            counts = fresh
        }
    }

    private func pendingCardCount(client: OperatorClient) async -> Int {
        do {
            return (try await client.listOperatorCards()).count
        } catch {
            return counts.pendingCards
        }
    }

    private func recentAlertCount(client: OperatorClient) async -> Int {
        do {
            return (try await client.recentNotifications()).filter { Self.isAlertLevel($0.level) }.count
        } catch {
            return counts.recentAlerts
        }
    }

    private static func isAlertLevel(_ level: String) -> Bool {
        level.caseInsensitiveCompare("error") == .orderedSame
            || level.caseInsensitiveCompare("warning") == .orderedSame
            || level.caseInsensitiveCompare("warn") == .orderedSame
    }
}

private struct OfflineBanner: View {
    let state: ConnState

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 8) {
                Text("●")
                    .font(.system(size: 13, weight: .semibold))
                Text("Desktop offline")
                    .font(.caption.weight(.semibold))
                Spacer(minLength: 12)
                Text(durationText(now: context.date))
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(PapercupTheme.error.opacity(0.82))
            }
            .foregroundStyle(Color(red: 1.0, green: 0.80, blue: 0.84))
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Color(red: 0.28, green: 0.02, blue: 0.07).opacity(0.94))
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(PapercupTheme.error.opacity(0.32))
                    .frame(height: 1)
            }
        }
    }

    private func durationText(now: Date) -> String {
        guard let since = state.offlineSinceMs else { return "" }
        let elapsed = max(1, Int(now.timeIntervalSince1970) - Int(since / 1_000))
        if elapsed < 60 { return "\(elapsed)s" }
        let minutes = elapsed / 60
        if minutes < 60 { return "\(minutes)m" }
        return "\(minutes / 60)h"
    }
}
private struct PausedBanner: View {
    let creds: DeviceCredentials

    @Environment(\.scenePhase) private var scenePhase
    @State private var info = PauseInfo(paused: false, at: nil, by: nil)
    @State private var busy: Bool = false

    var body: some View {
        Group {
            if info.paused {
                HStack(alignment: .center, spacing: 10) {
                    Text("⏸")
                        .font(.system(size: 17, weight: .semibold))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Operator paused")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(PapercupTheme.warning)
                        if let detail = detailText {
                            Text(detail)
                                .font(.caption2)
                                .foregroundStyle(PapercupTheme.warning.opacity(0.82))
                        }
                    }
                    Spacer(minLength: 12)
                    Button {
                        busy = true
                        Task { @MainActor in
                            defer { busy = false }
                            do {
                                let paused = try await creds.client().pauseSet(paused: false)
                                info.paused = paused
                                if !paused {
                                    info.at = nil
                                    info.by = nil
                                }
                            } catch {
                            }
                        }
                    } label: {
                        Text(busy ? "…" : "Resume")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(PapercupTheme.ink)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(PapercupTheme.warning, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(busy)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
                .background(Color(red: 0.28, green: 0.17, blue: 0.02).opacity(0.96))
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(PapercupTheme.warning.opacity(0.28))
                        .frame(height: 1)
                }
            }
        }
        .task(id: creds.deviceToken) {
            await refresh()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                if Task.isCancelled { break }
                await refresh()
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            Task { await refresh() }
        }
    }

    private var detailText: String? {
        [shortActor(info.by), relativePauseTime(info.at)]
            .compactMap { $0 }
            .joined(separator: " · ")
            .nilIfEmpty
    }

    @MainActor
    private func refresh() async {
        do {
            info = try await creds.client().pauseGet()
        } catch {
        }
    }

    private func shortActor(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        if raw.hasPrefix("device:") { return "by phone" }
        if let at = raw.firstIndex(of: "@"), at > raw.startIndex {
            return "by \(String(raw[..<at]))"
        }
        return "by \(raw)"
    }

    private func relativePauseTime(_ iso: String?) -> String? {
        guard let iso, let when = Self.parseDate(iso) else { return nil }
        let diff = Int(Date().timeIntervalSince(when))
        guard diff >= 0 else { return nil }
        if diff < 60 { return "\(diff)s ago" }
        let minutes = diff / 60
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h ago" }
        return "\(hours / 24)d ago"
    }

    private static func parseDate(_ raw: String) -> Date? {
        if let exact = fractionalDateFormatter.date(from: raw) { return exact }
        return plainDateFormatter.date(from: raw)
    }

    private static let fractionalDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let plainDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
private struct MobileBottomNav: View {
    @Binding var tab: AppRoot.Tab
    let counts: ShellBadgeCounts

    private enum BadgeKind {
        case pendingCards
        case recentAlerts
    }

    private var items: [(tab: AppRoot.Tab, icon: String, label: String, badge: BadgeKind?)] {
        [
            (.operatorTab, "●", NSLocalizedString("tab.operator", comment: ""), .pendingCards),
            (.harnesses, "⌘", NSLocalizedString("tab.harnesses", comment: ""), nil),
            (.running, "▶", NSLocalizedString("tab.running", comment: ""), nil),
            (.activity, "◆", NSLocalizedString("tab.activity", comment: ""), .recentAlerts),
            (.settings, "⚙", NSLocalizedString("tab.settings", comment: ""), nil),
        ]
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(items, id: \.tab) { item in
                let selected = tab == item.tab
                let background = selected ? PapercupTheme.accent.opacity(0.10) : Color.clear
                Button {
                    tab = item.tab
                } label: {
                    VStack(spacing: 1) {
                        ZStack(alignment: .topTrailing) {
                            Text(item.icon)
                                .font(.system(size: 18, weight: .semibold))
                            if let badge = item.badge {
                                NavBadge(count: count(for: badge), tone: badge == .recentAlerts ? .attention : .info)
                                    .offset(x: 12, y: -5)
                            }
                        }
                        Text(item.label.uppercased())
                            .font(.system(size: 10, weight: .semibold))
                            .tracking(0.8)
                    }
                    .foregroundStyle(selected ? PapercupTheme.accentStrong : PapercupTheme.textMuted)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background(
                        background,
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(accessibilityLabel(for: item.label, badge: item.badge)))
                .accessibilityAddTraits(selected ? [.isButton, .isSelected] : [.isButton])
            }
        }
        .padding(.horizontal, 6)
        .padding(.top, 6)
        .padding(.bottom, 4)
        .background(
            LinearGradient(
                colors: [PapercupTheme.inkRaised.opacity(0.96), PapercupTheme.ink.opacity(0.98)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .overlay(alignment: .top) {
            Rectangle()
                .fill(PapercupTheme.accentStrong.opacity(0.16))
                .frame(height: 1)
        }
    }

    private func count(for badge: BadgeKind) -> Int {
        switch badge {
        case .pendingCards: return counts.pendingCards
        case .recentAlerts: return counts.recentAlerts
        }
    }

    private func accessibilityLabel(for label: String, badge: BadgeKind?) -> String {
        guard let badge else { return label }
        let count = count(for: badge)
        guard count > 0 else { return label }
        return "\(label), \(count) \(badge == .pendingCards ? "pending" : "alerts")"
    }
}

private struct NavBadge: View {
    enum Tone {
        case info
        case attention
    }

    let count: Int
    let tone: Tone

    var body: some View {
        if count > 0 {
            Text(count > 99 ? "99+" : "\(count)")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(tone == .attention ? Color(red: 1.0, green: 0.94, blue: 0.95) : PapercupTheme.ink)
                .lineLimit(1)
                .monospacedDigit()
                .frame(minWidth: 16, minHeight: 16)
                .padding(.horizontal, count > 9 ? 2 : 0)
                .background(tone == .attention ? PapercupTheme.error : PapercupTheme.accent, in: Capsule())
        }
    }
}

private struct VoicePill: View {
    @ObservedObject var voice: VoiceManager

    private var style: (glyph: String, label: String, background: Color, foreground: Color) {
        switch voice.state {
        case .idle:
            return ("◉", "Listen", PapercupTheme.inkRaised, PapercupTheme.accentStrong)
        case .connecting:
            return ("⋯", "Connecting", PapercupTheme.inkRaised, PapercupTheme.warning)
        case .listening:
            return ("◼", "Listening", PapercupTheme.accent, PapercupTheme.ink)
        case .speaking:
            return ("◼", "Speaking", PapercupTheme.accentStrong, PapercupTheme.ink)
        case .failed:
            return ("!", "Error", PapercupTheme.error, Color.white)
        }
    }

    private var isActive: Bool {
        switch voice.state {
        case .idle, .failed: return false
        case .connecting, .listening, .speaking: return true
        }
    }

    var body: some View {
        let s = style
        Button {
            if isActive {
                voice.stop()
            } else {
                voice.start()
            }
        } label: {
            VStack(spacing: 0) {
                Text(s.glyph)
                    .font(.system(size: 18, weight: .semibold))
                Text(s.label.uppercased())
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.8)
            }
            .foregroundStyle(s.foreground)
            .frame(width: 80, height: 56)
            .background(s.background, in: Capsule())
            .overlay(Capsule().stroke(s.foreground.opacity(0.48), lineWidth: 1))
            .shadow(color: Color.black.opacity(0.38), radius: 18, x: 0, y: 10)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Voice: \(s.label)\(isActive ? " (tap to stop)" : "")"))
    }
}
