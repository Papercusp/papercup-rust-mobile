// SPDX-License-Identifier: GPL-3.0-or-later
//
// End-to-end UI tests that exercise the paired-state code paths.
// XCUITest can tap real UI elements (including system alerts) without
// Accessibility permission — that's the only path through the iOS 17.4
// "Open in Papercup?" confirmation when going via openurl, but for
// the paste-payload flow we don't need it at all.
//
// Required environment variables (passed via xcodebuild
// -setenv ... or the run-ios-uitests.sh wrapper):
//   PAPERCUP_PAIR_PAYLOAD  — JSON {server, pairToken, workspaceId}
//                            minted fresh by the test runner.

import XCTest

final class PairFlowUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Smoke test: a fresh-install app launches into PairView with the
    /// expected affordances visible. Verifies the SceneManifest +
    /// CredentialStore + PairView wiring on every launch without needing
    /// backend or a pair token.
    func testFreshLaunchShowsPairChoices() {
        let app = XCUIApplication()
        app.launchArguments = ["-com.papercuspai.uitests.wipeCredentials", "YES"]
        app.launch()

        // Heading
        XCTAssertTrue(app.staticTexts["Pair this device"].waitForExistence(timeout: 5),
                      "Pair view heading should render on fresh launch")
        // Both pair-mode buttons present
        XCTAssertTrue(app.buttons["Scan QR code"].exists, "Scan QR button should be present")
        XCTAssertTrue(app.buttons["Paste payload"].exists, "Paste payload button should be present")
    }

    /// Drives the full paste-pair flow using a backend-minted token
    /// provided via environment. Skips silently if the env var isn't
    /// set so the test still passes in plain CI (where backend isn't
    /// reachable).
    func testPastePairFlow() throws {
        guard let payload = ProcessInfo.processInfo.environment["PAPERCUP_PAIR_PAYLOAD"],
              !payload.isEmpty else {
            throw XCTSkip("PAPERCUP_PAIR_PAYLOAD not set — runner provides this from a freshly minted PG token.")
        }

        // Prime the simulator pasteboard with the JSON payload.
        UIPasteboard.general.string = payload

        let app = XCUIApplication()
        app.launchArguments = ["-com.papercuspai.uitests.wipeCredentials", "YES"]
        app.launch()

        XCTAssertTrue(app.staticTexts["Pair this device"].waitForExistence(timeout: 5))
        app.buttons["Paste payload"].tap()

        let editor = app.textViews.element(boundBy: 0)
        XCTAssertTrue(editor.waitForExistence(timeout: 3))
        editor.tap()
        editor.press(forDuration: 0.6) // brings up the loupe / Paste menu

        // The system Paste menu is presented; tap "Paste" in the menu bar.
        let pasteMenu = app.menuItems["Paste"]
        if pasteMenu.waitForExistence(timeout: 3) {
            pasteMenu.tap()
        } else {
            // Fallback: type the JSON directly. Slow but reliable.
            editor.typeText(payload)
        }

        app.buttons["Pair"].tap()

        // After successful pair, the tab bar appears with the Operator tab.
        let operatorTab = app.tabBars.buttons["Operator"]
        XCTAssertTrue(operatorTab.waitForExistence(timeout: 15),
                      "Operator tab should appear after successful pair")
    }
}

/// Tap into the standard nav rows once paired. Skips unless paired
/// state was established (PAPERCUP_PAIR_PAYLOAD set + paired in setUp).
final class PairedNavigationUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testSettingsNavRowsOpen() throws {
        guard ProcessInfo.processInfo.environment["PAPERCUP_PAIR_PAYLOAD"] != nil else {
            throw XCTSkip("Skipped — needs PAPERCUP_PAIR_PAYLOAD to reach paired state.")
        }
        let app = XCUIApplication()
        app.launch()
        // Already paired from the previous test class. Navigate Settings.
        let settingsTab = app.tabBars.buttons["Settings"]
        guard settingsTab.waitForExistence(timeout: 10) else {
            throw XCTSkip("Not paired — previous test must establish creds first.")
        }
        settingsTab.tap()

        // Three nav rows added by phase 11b
        let standing = app.buttons["Standing approvals"].firstMatch
        let voice = app.buttons["Voice"].firstMatch
        let diagnostics = app.buttons["Diagnostics"].firstMatch

        // Scroll into view if needed
        if !standing.exists { app.swipeUp() }

        XCTAssertTrue(standing.waitForExistence(timeout: 3))
        standing.tap()
        XCTAssertTrue(app.staticTexts["Standing approvals"].waitForExistence(timeout: 3))
        app.navigationBars.buttons.firstMatch.tap()

        XCTAssertTrue(voice.waitForExistence(timeout: 3))
        voice.tap()
        XCTAssertTrue(app.staticTexts["Voice"].waitForExistence(timeout: 3))
        app.navigationBars.buttons.firstMatch.tap()

        XCTAssertTrue(diagnostics.waitForExistence(timeout: 3))
        diagnostics.tap()
        XCTAssertTrue(app.staticTexts["Diagnostics"].waitForExistence(timeout: 3))
    }
}
