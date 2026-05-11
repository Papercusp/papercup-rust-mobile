// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

@main
struct PapercupApp: App {
    @UIApplicationDelegateAdaptor(PapercupAppDelegate.self) var appDelegate
    @StateObject private var deepLink = DeepLinkRouter.shared

    var body: some Scene {
        WindowGroup {
            AppRoot()
                .tint(PapercupTheme.accent)
                .environmentObject(deepLink)
                .onOpenURL { url in deepLink.handle(url: url) }
        }
    }
}
