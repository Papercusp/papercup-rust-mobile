// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import os.log
#if canImport(Sentry)
import Sentry
#endif

private let appLog = OSLog(subsystem: "com.papercuspai.operator.mobile", category: "App")

@main
struct PapercupApp: App {
    @UIApplicationDelegateAdaptor(PapercupAppDelegate.self) var appDelegate
    @StateObject private var deepLink = DeepLinkRouter.shared

    init() {
        #if canImport(Sentry)
        // Phase 10 — iOS crash reporting parity with Android Crashlytics.
        // DSN comes from Info.plist key SENTRY_DSN (set per-build via
        // xcconfig); empty-string DSN disables uploads, so dev builds
        // without the key are no-op. Sentry SDK auto-captures crashes,
        // unhandled NSExceptions, and fatalError().
        if let dsn = Bundle.main.object(forInfoDictionaryKey: "SENTRY_DSN") as? String,
           !dsn.isEmpty {
            SentrySDK.start { options in
                options.dsn = dsn
                options.releaseName = "papercup-mobile@\(version())"
                options.environment = {
                    #if DEBUG
                    return "debug"
                    #else
                    return "release"
                    #endif
                }()
                // Performance + sessions disabled by default; enable later.
                options.tracesSampleRate = 0.0
            }
        }
        #endif

        #if DEBUG
        // XCUITest hooks — DEBUG-only so release builds can't be
        // pair-injected via Xcode launch args. Both no-ops without args.
        let args = CommandLine.arguments
        if args.contains("-com.papercuspai.uitests.wipeCredentials") {
            CredentialStore.clear()
        }
        if let i = args.firstIndex(of: "-com.papercuspai.uitests.pairPayload"),
           i + 1 < args.count {
            let raw = args[i + 1]
            if let data = raw.data(using: .utf8),
               let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String],
               let server = dict["server"],
               let token = dict["pairToken"],
               let ws = dict["workspaceId"] {
                DispatchQueue.main.async {
                    DeepLinkRouter.shared.pendingPair = PendingPair(
                        server: server, pairToken: token, workspaceId: ws
                    )
                }
            }
        }
        // Push-tap backdoor: feed a notification userInfo dict through the
        // SAME DeepLinkRouter path a real APNs tap uses (D-004). Real APNs
        // can't reach a simulator and the APNs cert is owner-gated, so this
        // is how the E2E exercises cold-launch → deep-link routing
        // deterministically (the springboard Notification Center tap is
        // Apple's UI, not ours, and is too flaky to gate on).
        if let i = args.firstIndex(of: "-com.papercuspai.uitests.pushUserInfo"),
           i + 1 < args.count {
            let raw = args[i + 1]
            if let data = raw.data(using: .utf8),
               let info = try? JSONSerialization.jsonObject(with: data) as? [AnyHashable: Any] {
                DispatchQueue.main.async {
                    DeepLinkRouter.shared.handle(notificationUserInfo: info)
                }
            }
        }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            AppRoot()
                .tint(PapercupTheme.accent)
                .preferredColorScheme(.dark)
                .environmentObject(deepLink)
                .onOpenURL { url in
                    os_log(.info, log: appLog, "WindowGroup.onOpenURL fired url=%{public}@", url.absoluteString)
                    deepLink.handle(url: url)
                }
        }
    }
}
