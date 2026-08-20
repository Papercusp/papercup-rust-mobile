// SPDX-License-Identifier: GPL-3.0-or-later
//
// Deep-link plumbing — mirror of Android's EXTRA_DEEPLINK_SLUG flow
// (PushService.kt → MainActivity.deepLinkSlug → AppRoot route push).
//
// Two entry points feed `DeepLinkRouter.shared.pendingSlug`:
//
//   1. URL scheme: `papercup://harness/<slug>`
//      Handled by .onOpenURL in PapercupApp. Works for any link
//      (Safari, Mail, Messages, custom QR codes).
//
//   2. APNs notification tap: payload carries `harnessSlug` in the
//      userInfo dict; the UNUserNotificationCenterDelegate routes
//      it through here on tap. Inert today — landed for parity, will
//      activate the moment APNs delivery is wired (PushManager.swift).

import Foundation
import PapercupCore
import SwiftUI
import UserNotifications
import os.log

/// Pair-via-link payload, parsed from `papercup://pair?...`.
/// All three fields are required; matches the QR/paste shape.
struct PendingPair: Equatable {
    let server: String
    let pairToken: String
    let workspaceId: String
}

@MainActor
final class DeepLinkRouter: ObservableObject {
    static let shared = DeepLinkRouter()
    @Published var pendingSlug: String? = nil
    @Published var pendingPair: PendingPair? = nil
    /// Set when an attention/inbox push is tapped (kind = intervention /
    /// smoke-fail / plan-review). AppRoot routes it to the Inbox tab —
    /// every inbox push deep-links here (mobile-apps-revival D-004).
    @Published var pendingInbox: Bool = false

    private init() {}

    /// Push `kind` values that mean "look at your Inbox" (mirrors the
    /// server's MOBILE_KIND map in attention-notify.ts).
    private static let attentionKinds: Set<String> = [
        "intervention", "smoke-fail", "plan-review", "needs-human",
    ]

    private static let log = OSLog(subsystem: "com.papercuspai.operator.mobile", category: "DeepLink")

    /// Parse and install the JSON payload carried by the DEBUG-only
    /// XCUITest launch argument. This is synchronous by design: deferring
    /// assignment from `PapercupApp.init` can race AppRoot's first render
    /// and strand a valid one-shot token on PairView without redeeming it.
    @discardableResult
    func handle(pairPayload raw: String) -> Bool {
        guard let data = raw.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let server = dict["server"], !server.isEmpty,
              let token = dict["pairToken"], !token.isEmpty,
              let ws = dict["workspaceId"], !ws.isEmpty else {
            os_log(.info, log: Self.log, "launch pair payload missing required fields")
            return false
        }
        pendingPair = PendingPair(server: server, pairToken: token, workspaceId: ws)
        os_log(.info, log: Self.log, "launch pendingPair set server=%{public}@ ws=%{public}@", server, ws)
        return true
    }

    /// Returns true if the URL was a recognised papercup deep-link.
    @discardableResult
    func handle(url: URL) -> Bool {
        os_log(.info, log: Self.log, "handle url=%{public}@", url.absoluteString)
        guard url.scheme == "papercup" else {
            os_log(.info, log: Self.log, "non-papercup scheme, ignoring")
            return false
        }
        // papercup://harness/<slug>
        let parts = url.pathComponents.filter { $0 != "/" }
        if url.host == "harness", let slug = parts.first {
            os_log(.info, log: Self.log, "harness/%{public}@", slug)
            pendingSlug = slug
            return true
        }
        // papercup://pair?server=...&pairToken=...&workspaceId=...
        if url.host == "pair" {
            let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
            let q = Dictionary(uniqueKeysWithValues:
                (comps?.queryItems ?? []).compactMap { item -> (String, String)? in
                    guard let v = item.value else { return nil }
                    return (item.name, v)
                })
            if let server = q["server"], let token = q["pairToken"], let ws = q["workspaceId"],
               !server.isEmpty, !token.isEmpty, !ws.isEmpty {
                os_log(.info, log: Self.log, "pendingPair set server=%{public}@ ws=%{public}@", server, ws)
                pendingPair = PendingPair(server: server, pairToken: token, workspaceId: ws)
                return true
            }
            os_log(.info, log: Self.log, "pair URL missing required fields, q=%{public}@", String(describing: q))
        }
        os_log(.info, log: Self.log, "unrecognised host=%{public}@", String(describing: url.host))
        return false
    }

    /// Called from the UNUserNotificationCenterDelegate on tap. The
    /// server (attention-notify.ts) sends `kind` + an optional `harness`
    /// slug in the push data. Every attention push deep-links to the
    /// Inbox (D-004); a harness-scoped push also pushes that harness's
    /// detail over it.
    func handle(notificationUserInfo info: [AnyHashable: Any]) {
        let kind = info["kind"] as? String
        if let k = kind, Self.attentionKinds.contains(k) {
            pendingInbox = true
        }
        // Server key is `harness`; keep `harnessSlug`/`slug` for parity
        // with any older payloads.
        if let slug = info["harness"] as? String
            ?? info["harnessSlug"] as? String
            ?? info["slug"] as? String,
            !slug.isEmpty {
            pendingSlug = slug
        } else if kind == nil {
            // No kind, no harness — a bare tap still opens the Inbox.
            pendingInbox = true
        }
    }
}

/// Single shared delegate so the OS can route notification taps to
/// `DeepLinkRouter` even when the app was cold-launched. Wired in
/// `PapercupApp` via `UIApplicationDelegateAdaptor`.
import UIKit

final class PapercupAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    /// Foreground delivery: keep the banner visible so the user sees it.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .badge])
    }

    /// Tap delivery — route the slug to DeepLinkRouter.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        Task { @MainActor in
            DeepLinkRouter.shared.handle(notificationUserInfo: response.notification.request.content.userInfo)
            completionHandler()
        }
    }

    /// APNs token comes back here once `aps-environment` entitlement
    /// is signed in (see PushManager.swift). For now this fires only
    /// on a real device with the entitlement.
    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in
            guard let creds = CredentialStore.load() else { return }
            await PushManager(creds: creds).register(deviceTokenData: deviceToken)
        }
    }

    /// Required when UIApplicationDelegateAdaptor is wired alongside
    /// SwiftUI's .onOpenURL — without this, openurl events never reach
    /// the WindowGroup. We return true after handing the URL off to
    /// DeepLinkRouter so SwiftUI's .onOpenURL also fires (defence in
    /// depth).
    func application(_ app: UIApplication,
                     open url: URL,
                     options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
        Task { @MainActor in DeepLinkRouter.shared.handle(url: url) }
        return true
    }
}
