// SPDX-License-Identifier: GPL-3.0-or-later
//
// APNs push registration. Mirror of Android's PushService.kt (which
// speaks FCM). The Xcode project declares the Push Notifications
// entitlement for both build configurations; a signed device build also
// needs the bundle ID enabled for Push in the Apple developer account.
//
// The release script supplies DEVELOPMENT_TEAM at archive time rather
// than committing account-specific signing material. Automatic signing
// selects a matching provisioning profile for
// com.papercuspai.operator.mobile with the production APNs entitlement.
//
// Server contract: POST /api/device/push/register
//   body: { platform: "apns", token: "<hex>" }
// Same endpoint Android hits with platform "fcm".

import Foundation
import UIKit
import os.log

@MainActor
final class PushManager: NSObject {
    private let log = OSLog(subsystem: "com.papercuspai.operator.mobile", category: "Push")
    private let creds: DeviceCredentials

    init(creds: DeviceCredentials) { self.creds = creds }

    /// Call from the app delegate / SwiftUI scene `.onAppear`. Triggers
    /// the OS prompt for notification permission, then registers for
    /// remote notifications. The token comes back via the
    /// UIApplicationDelegate's didRegisterForRemoteNotificationsWithDeviceToken.
    func requestPermissionAndRegister() async {
        let center = UNUserNotificationCenter.current()
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            guard granted else {
                os_log(.info, log: log, "push: permission denied")
                return
            }
            UIApplication.shared.registerForRemoteNotifications()
        } catch {
            os_log(.error, log: log, "push: permission request failed: %{public}@", String(describing: error))
        }
    }

    /// Hex-encode and POST to /api/device/push/register. Idempotent
    /// server-side; safe to call on every cold-start + on token rotation.
    func register(deviceTokenData: Data) async {
        let hex = deviceTokenData.map { String(format: "%02x", $0) }.joined()
        do {
            try await creds.client()
                .registerPush(platform: "apns", token: hex)
            os_log(.info, log: log, "push: registered apns token (%d chars)", hex.count)
        } catch {
            os_log(.error, log: log, "push: registration failed: %{public}@", String(describing: error))
        }
    }
}
