// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import os.log

private let appLog = OSLog(subsystem: "com.papercuspai.operator.mobile", category: "App")

@main
struct PapercupApp: App {
    @UIApplicationDelegateAdaptor(PapercupAppDelegate.self) var appDelegate
    @StateObject private var deepLink = DeepLinkRouter.shared

    init() {
        // XCUITest hooks. Both no-ops in production.
        let args = CommandLine.arguments
        if args.contains("-com.papercuspai.uitests.wipeCredentials") {
            CredentialStore.clear()
        }
        // Pair-payload backdoor for XCUITest: avoids the iOS 17.4
        // "Open in Papercup?" system prompt that blocks simctl openurl,
        // and the JSON-typing flake on the soft keyboard. The arg value
        // is the same JSON shape PairView would parse.
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
