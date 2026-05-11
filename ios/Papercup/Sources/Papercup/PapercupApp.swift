// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import os.log

private let appLog = OSLog(subsystem: "com.papercuspai.operator.mobile", category: "App")

@main
struct PapercupApp: App {
    @UIApplicationDelegateAdaptor(PapercupAppDelegate.self) var appDelegate
    @StateObject private var deepLink = DeepLinkRouter.shared

    init() {
        // XCUITest hook: wipe Keychain creds before launch when the
        // -com.papercuspai.uitests.wipeCredentials YES launch arg is
        // present. Lets PairFlowUITests start every run from a known
        // un-paired state without adding a permanent dev backdoor.
        if CommandLine.arguments.contains("-com.papercuspai.uitests.wipeCredentials") {
            CredentialStore.clear()
        }
    }

    var body: some Scene {
        WindowGroup {
            AppRoot()
                .tint(PapercupTheme.accent)
                .environmentObject(deepLink)
                .onOpenURL { url in
                    os_log(.info, log: appLog, "WindowGroup.onOpenURL fired url=%{public}@", url.absoluteString)
                    deepLink.handle(url: url)
                }
        }
    }
}
