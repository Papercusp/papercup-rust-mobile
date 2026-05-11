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

@MainActor
final class DeepLinkRouter: ObservableObject {
    static let shared = DeepLinkRouter()
    @Published var pendingSlug: String? = nil

    private init() {}

    /// Returns true if the URL was a recognised papercup deep-link.
    @discardableResult
    func handle(url: URL) -> Bool {
        guard url.scheme == "papercup" else { return false }
        // papercup://harness/<slug>  (host="harness", first path segment is the slug)
        let parts = url.pathComponents.filter { $0 != "/" }
        if url.host == "harness", let slug = parts.first {
            pendingSlug = slug
            return true
        }
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
}
