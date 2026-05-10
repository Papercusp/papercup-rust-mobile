// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

@main
struct PapercupApp: App {
    var body: some Scene {
        WindowGroup {
            AppRoot()
                .tint(PapercupTheme.accent)
        }
    }
}
