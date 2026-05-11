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

    private init() {}

    private static let log = OSLog(subsystem: "com.papercuspai.operator.mobile", category: "DeepLink")

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

    /// Called from the UNUserNotificationCenterDelegate on tap. Looks
    /// for a `harnessSlug` (or fallback `slug`) string in the userInfo.
    func handle(notificationUserInfo info: [AnyHashable: Any]) {
        if let slug = info["harnessSlug"] as? String ?? info["slug"] as? String {
            pendingSlug = slug
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
