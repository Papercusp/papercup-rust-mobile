// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import os.log

/// Mirrors Android's PairedShell — the Inbox-first 5-tab nav
/// (Inbox / Operator / Plans / Brew / Settings, mobile-apps-revival
/// D-003) plus pushed routes and a header Pot (workspace) switcher.
struct AppRoot: View {
    @State private var creds: DeviceCredentials? = CredentialStore.load()
    @State private var liveTick: Int = 0
    @State private var lastInvalidate: String? = nil
    @State private var pushedDetailSlug: String? = nil
    @State private var pushedRunLogSlug: String? = nil
    @EnvironmentObject private var deepLink: DeepLinkRouter

    /// Inbox-first 5-tab IA. `brew` absorbs the old harnesses + running
    /// tabs (the live fleet); `inbox` is the actionable attention feed;
    /// `plans` is the PG-canonical plans browser.
    enum Tab: Hashable { case inbox, operatorTab, plans, brew, settings }
    @State private var tab: Tab = .inbox

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
                    tab = .inbox
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
    /// PairView. Mirrors PairView.redeem(): POST /api/device/pair + persist
    /// DeviceCredentials. Used for pair-by-link (email, scanning a QR with
    /// the system camera, etc.). Mesh is Defguard self-enrollment (D-005).
    @MainActor
    private func autoPair(_ p: PendingPair) async {
        let log = OSLog(subsystem: "com.papercuspai.operator.mobile", category: "AutoPair")
        os_log(.info, log: log, "starting server=%{public}@ ws=%{public}@",
               p.server, p.workspaceId)
        deepLink.pendingPair = nil
        let client = OperatorClient(baseUrl: p.server, deviceToken: nil)
        do {
            let outcome = try await client.pair(pairToken: p.pairToken)
            os_log(.info, log: log, "pair OK deviceId=%{public}@", outcome.deviceId)
            let fresh = DeviceCredentials(
                server: p.server,
                deviceToken: outcome.deviceToken,
                deviceId: outcome.deviceId,
                workspaceId: outcome.workspaceId,
                defguardEnrollmentUrl: outcome.defguardEnrollmentUrl
            )
            CredentialStore.save(fresh)
            creds = fresh
            tab = .inbox
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
    @Environment(\.scenePhase) private var pairedScenePhase

    // Header Pot (workspace) switcher state. Same slug+scope model as
    // desktop/PUI (D-003): the phone's "Pot" is the active workspace.
    @State private var showPotSwitcher = false
    @State private var workspaces: [Workspace]? = nil

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
                tab = .brew
                pushedRunLogSlug = nil
                pushedDetailSlug = slug
            case .runLog(let slug):
                tab = .brew
                pushedDetailSlug = nil
                pushedRunLogSlug = slug
            case .operatorTab:
                pushedDetailSlug = nil
                pushedRunLogSlug = nil
                tab = .operatorTab
            case .inbox:
                pushedDetailSlug = nil
                pushedRunLogSlug = nil
                tab = .inbox
            }
        }


        VStack(spacing: 0) {
            PotSwitcherHeader(
                title: currentPotName,
                onTap: { showPotSwitcher = true }
            )
            PausedBanner(creds: current)
            if monitor.state.status == .offline {
                OfflineBanner(state: monitor.state)
            }
            VoiceErrorBanner(voice: voice)
            ZStack {
                Group {
                    switch tab {
                    case .inbox:
                        // Interim Inbox: the recent notifications + audit
                        // activity feed. The unified actionable attention
                        // feed (approvals/blocked/questions/completions)
                        // lands with the device/attention route (D-002).
                        ActivityView(
                            creds: current,
                            invalidationTick: liveTick,
                            onSelectHarness: onSelectHarness
                        )
                    case .operatorTab:
                        OperatorView(
                            creds: current,
                            invalidationTick: liveTick,
                            onSelectHarness: onSelectHarness,
                            voice: voice
                        )
                    case .plans:
                        PlansView(
                            creds: current,
                            invalidationTick: liveTick
                        )
                    case .brew:
                        BrewView(
                            creds: current,
                            liveTick: liveTick,
                            lastInvalidate: lastInvalidate,
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

                if let toast = badgeHost.toast {
                    ShellToastView(
                        toast: toast,
                        onDismiss: { badgeHost.dismissToast(toast.id) },
                        onOpen: { openToast(toast) }
                    )
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            MobileBottomNav(tab: $tab, counts: badgeHost.counts)
        }
        .task(id: current.deviceToken) { monitor.start(); await runSync() }
        .onReceive(cacheHost.$tick) { _ in
            // The polling cache refetched a tracked query (D-001.1). Bump
            // the shared liveTick so screens observing `invalidationTick:
            // liveTick` refresh, and refresh badges when the changed
            // surface is a notification/scan feed.
            liveTick += 1
            if let name = cacheHost.lastInvalidate, Self.shouldRefreshBadges(for: name) {
                Task { await badgeHost.refresh(showToast: true) }
            }
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
                tab = .brew
                pushedDetailSlug = slug
            case .navigateTab(let target):
                // VoiceManager.Tab predates the 5-tab IA: its `harnesses`
                // maps to Brew (the live fleet) and `activity` to Inbox.
                tab = switch target {
                    case .operatorTab: .operatorTab
                    case .harnesses: .brew
                    case .activity: .inbox
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
        // End any active voice session when the app backgrounds.
        // Mirrors Android lifecycle ON_STOP handling — EL bills by
        // session duration so we shouldn't keep burning minutes when
        // the user has navigated away.
        .onChange(of: pairedScenePhase) { _, newPhase in
            guard newPhase == .background else { return }
            switch voice.state {
            case .idle, .failed: break
            default: voice.stop()
            }
        }
        .task(id: current.deviceToken) {
            // Load the workspace roster so the header can show the Pot's
            // name (creds only carry the id) and the switcher opens warm.
            workspaces = try? await current.client().listWorkspaces()
        }
        .sheet(isPresented: $showPotSwitcher) {
            NavigationStack {
                WorkspaceSelectorView(
                    creds: current,
                    initialWorkspaces: workspaces,
                    onSwitchWorkspace: { w in
                        try await switchPot(w)
                        showPotSwitcher = false
                    }
                )
                .navigationTitle("Switch Pot")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { showPotSwitcher = false }
                    }
                }
            }
        }
    }

    /// Display name for the active Pot (workspace). Falls back to the id
    /// until the roster loads.
    private var currentPotName: String {
        workspaces?.first { $0.id == current.workspaceId }?.name ?? current.workspaceId
    }

    /// Re-issue the device token scoped to the selected Pot and persist.
    /// Mirrors SettingsView.switchWorkspace so the header + Settings agree.
    private func switchPot(_ w: Workspace) async throws {
        let res = try await current.client().workspaceSwitch(workspaceId: w.id)
        var fresh = current
        fresh.deviceToken = res.deviceToken
        fresh.workspaceId = res.workspaceId
        onWorkspaceSwitched(fresh)
    }

    private func openToast(_ toast: Toast) {
        badgeHost.dismissToast(toast.id)
        pushedDetailSlug = nil
        pushedRunLogSlug = nil

        if let slug = toast.harnessSlug, !slug.isEmpty {
            tab = .brew
            pushedDetailSlug = slug
            return
        }

        guard let rawHref = toast.actionHref, !rawHref.isEmpty else {
            tab = .inbox
            return
        }

        let path = rawHref
            .split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map(String.init)?
            .trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""

        switch path {
        case "", "operator":
            tab = .operatorTab
        case "harness", "running", "brew":
            tab = .brew
        case let value where value.hasPrefix("harness/"):
            tab = .brew
            pushedDetailSlug = String(value.dropFirst("harness/".count))
        case "log":
            tab = .brew
        case let value where value.hasPrefix("log/"):
            tab = .brew
            pushedRunLogSlug = String(value.dropFirst("log/".count))
        case "plans":
            tab = .plans
        case "notifications", "notifications/history", "actions", "inbox":
            tab = .inbox
        case let value where value.hasPrefix("settings"):
            tab = .settings
        default:
            tab = .inbox
        }
    }

    private func runSync() async {
        // SSE is retired (mobile-apps-revival D-001.1): the cache polls
        // GET /api/device/rest-query and surfaces deltas via cacheHost.tick
        // (observed by `.onReceive(cacheHost.$tick)` below, which bumps
        // liveTick + refreshes badges). We just keep polling alive for the
        // lifetime of the paired shell.
        cacheHost.start()
        defer { cacheHost.stop() }
        while !Task.isCancelled {
            do { try await Task.sleep(nanoseconds: 30_000_000_000) }
            catch { break }
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
    /// Standing-approval candidates awaiting a decision (the operator-card
    /// feed is retired — unify-agent-launches D-005; this is the surviving
    /// "needs your call" signal).
    var pendingApprovals: Int = 0
    var recentAlerts: Int = 0
}

@MainActor
private final class ShellBadgeHost: ObservableObject {
    @Published private(set) var counts = ShellBadgeCounts()
    @Published private(set) var toast: Toast?

    private let creds: DeviceCredentials
    private var newestToastId: Int64?
    private var dismissTask: Task<Void, Never>?

    init(creds: DeviceCredentials) {
        self.creds = creds
    }

    func run() async {
        await refresh(showToast: false)
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            if Task.isCancelled { break }
            await refresh(showToast: true)
        }
    }

    func refresh(showToast: Bool = true) async {
        let client = creds.client()
        let pending = await pendingApprovalCount(client: client)
        let loadedNotifications = await recentNotifications(client: client)
        let fresh = ShellBadgeCounts(
            pendingApprovals: pending,
            recentAlerts: loadedNotifications?.filter { Self.isAlertLevel($0.level) }.count ?? counts.recentAlerts
        )
        if counts != fresh {
            counts = fresh
        }
        if let loadedNotifications {
            updateToast(from: loadedNotifications, showToast: showToast)
        }
    }

    func dismissToast(_ id: Int64? = nil) {
        if id == nil || toast?.id == id {
            toast = nil
        }
    }

    private func pendingApprovalCount(client: OperatorClient) async -> Int {
        do {
            return (try await client.standingCandidates()).count
        } catch {
            return counts.pendingApprovals
        }
    }

    private func recentNotifications(client: OperatorClient) async -> [Toast]? {
        do {
            return try await client.recentNotifications()
        } catch {
            return nil
        }
    }

    private func updateToast(from notifications: [Toast], showToast: Bool) {
        guard let newest = notifications.max(by: { lhs, rhs in
            if lhs.createdAt == rhs.createdAt {
                return lhs.id < rhs.id
            }
            return lhs.createdAt < rhs.createdAt
        }) else { return }

        let previous = newestToastId
        newestToastId = newest.id
        guard showToast, previous != nil, previous != newest.id else { return }
        toast = newest
        scheduleDismiss(for: newest.id)
    }

    private func scheduleDismiss(for id: Int64) {
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            await MainActor.run {
                self?.dismissToast(id)
            }
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

private struct ShellToastView: View {
    let toast: Toast
    let onDismiss: () -> Void
    let onOpen: () -> Void

    var body: some View {
        let tone = Self.tone(for: toast.level)
        HStack(alignment: .top, spacing: 10) {
            Text(tone.glyph)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(tone.foreground)
            VStack(alignment: .leading, spacing: 3) {
                Text(toast.message)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(tone.foreground)
                    .multilineTextAlignment(.leading)
                if let description = toast.description, !description.isEmpty {
                    Text(description)
                        .font(.caption2)
                        .foregroundStyle(tone.foreground.opacity(0.80))
                        .multilineTextAlignment(.leading)
                }
            }
            Spacer(minLength: 8)
            Button(action: onDismiss) {
                Text("×")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(tone.foreground.opacity(0.88))
                    .padding(.horizontal, 4)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: 420, alignment: .leading)
        .background(tone.background, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(tone.foreground.opacity(0.28), lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(0.34), radius: 18, x: 0, y: 10)
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .accessibilityLabel(Text(toast.message))
    }

    private static func tone(for level: String) -> (glyph: String, background: Color, foreground: Color) {
        switch level.lowercased() {
        case "error":
            return ("✕", Color(red: 0.25, green: 0.03, blue: 0.06).opacity(0.96), Color(red: 1.0, green: 0.86, blue: 0.89))
        case "warning", "warn":
            return ("!", Color(red: 0.23, green: 0.14, blue: 0.02).opacity(0.96), Color(red: 1.0, green: 0.88, blue: 0.64))
        case "success":
            return ("✓", Color(red: 0.03, green: 0.19, blue: 0.13).opacity(0.96), Color(red: 0.72, green: 0.98, blue: 0.84))
        default:
            return ("ℹ", Color(red: 0.03, green: 0.16, blue: 0.23).opacity(0.96), Color(red: 0.78, green: 0.95, blue: 1.0))
        }
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
        case pendingApprovals
        case recentAlerts
    }

    private var items: [(tab: AppRoot.Tab, icon: String, label: String, badge: BadgeKind?)] {
        [
            (.inbox, "◆", NSLocalizedString("tab.inbox", comment: ""), .recentAlerts),
            (.operatorTab, "●", NSLocalizedString("tab.operator", comment: ""), .pendingApprovals),
            (.plans, "❒", NSLocalizedString("tab.plans", comment: ""), nil),
            (.brew, "▦", NSLocalizedString("tab.brew", comment: ""), nil),
            (.settings, "⚙", NSLocalizedString("tab.settings", comment: ""), nil),
        ]
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(items, id: \.tab) { item in
                let selected = tab == item.tab
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
                        Capsule()
                            .fill(selected ? PapercupTheme.accentStrong : Color.clear)
                            .frame(width: 28, height: 2)
                            .shadow(color: selected ? PapercupTheme.accentStrong.opacity(0.48) : .clear, radius: 8, x: 0, y: 0)
                    }
                    .foregroundStyle(selected ? PapercupTheme.accentStrong : PapercupTheme.textMuted)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
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
        case .pendingApprovals: return counts.pendingApprovals
        case .recentAlerts: return counts.recentAlerts
        }
    }

    private func accessibilityLabel(for label: String, badge: BadgeKind?) -> String {
        guard let badge else { return label }
        let count = count(for: badge)
        guard count > 0 else { return label }
        return "\(label), \(count) \(badge == .pendingApprovals ? "pending" : "alerts")"
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

/// Header Pot (workspace) switcher — the phone's equivalent of the
/// desktop/PUI header Pot selector (D-003). Shows the active Pot and
/// opens the workspace switcher sheet on tap.
private struct PotSwitcherHeader: View {
    let title: String
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                Text("◑")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(PapercupTheme.accentStrong)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(PapercupTheme.text)
                    .lineLimit(1)
                Text("▾")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(PapercupTheme.textMuted)
                Spacer(minLength: 0)
                Text("POT")
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(1.0)
                    .foregroundStyle(PapercupTheme.accentStrong.opacity(0.62))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity)
            .background(PapercupTheme.inkRaised.opacity(0.96))
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(PapercupTheme.accentStrong.opacity(0.14))
                    .frame(height: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Current Pot: \(title). Tap to switch."))
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
