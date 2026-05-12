// SPDX-License-Identifier: GPL-3.0-or-later
//
// End-to-end UI tests that exercise the paired-state code paths.
// XCUITest can drive real UI without Accessibility permission, the
// only viable path in the QEMU sim setup since simctl openurl trips
// the iOS 17.4 "Open in Papercup?" prompt and System Events keystroke
// injection requires an Accessibility-enabled session we don't have.
//
// Required environment variables (passed via TEST_RUNNER_* by the
// run-ios-uitests.sh wrapper):
//   PAPERCUP_PAIR_PAYLOAD  — JSON {server, pairToken, workspaceId}
//                            minted fresh; consumed exactly once.
//
// The backend mobile_pair_tokens are one-shot, so we get one chance per
// fresh token. Combining smoke + paired navigation into a single test
// keeps token consumption tractable.

import XCTest
import UIKit

final class PairFlowUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Smoke test: a fresh-install app launches into PairView with the
    /// expected affordances visible. No backend needed; covers the
    /// SceneManifest fix + CredentialStore + PairView wiring.
    func testFreshLaunchShowsPairChoices() {
        let app = XCUIApplication()
        app.launchArguments = ["-com.papercuspai.uitests.wipeCredentials", "YES"]
        app.launch()

        XCTAssertTrue(app.staticTexts["Pair with your desktop"].waitForExistence(timeout: 10),
                      "Pair view heading should render on fresh launch")
        let wordmarkExists = app.images["Papercusp"].exists ||
            app.otherElements["Papercusp"].exists ||
            app.staticTexts["Papercusp"].exists
        XCTAssertTrue(wordmarkExists, "Papercusp wordmark should be present")
        XCTAssertTrue(app.buttons["Scan QR"].exists, "Scan QR button should be present")
    }

    /// End-to-end pair flow + paired-state navigation in one go (the
    /// pair token is one-shot, so we can only spend it once per test
    /// run). Validates: launch-arg backdoor → DeepLinkRouter →
    /// AppRoot.autoPair → /api/mobile/pair → DeviceCredentials persist
    /// → PairedShell mounts → tab bar visible → Settings nav rows
    /// (Standing approvals / Voice / Diagnostics) open correctly.
    func testPairAndPairedNavigation() throws {
        guard let payload = ProcessInfo.processInfo.environment["PAPERCUP_PAIR_PAYLOAD"],
              !payload.isEmpty else {
            throw XCTSkip("PAPERCUP_PAIR_PAYLOAD not set — runner provides this from a freshly minted PG token.")
        }

        let app = XCUIApplication()
        app.launchArguments = [
            "-com.papercuspai.uitests.wipeCredentials", "YES",
            "-com.papercuspai.uitests.pairPayload", payload,
        ]
        app.launch()

        let operatorTab = app.buttons["Operator"]
        XCTAssertTrue(operatorTab.waitForExistence(timeout: 20),
                      "Operator tab should appear after launch-arg pair backdoor")

        // Hop to Settings, scroll to find the new nav rows, open each.
        let settingsTab = app.buttons["Settings"]
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 5))
        settingsTab.tap()

        let standing = app.buttons["Standing approvals"].firstMatch
        let voice = app.buttons["Voice"].firstMatch
        let diagnostics = app.buttons["Diagnostics"].firstMatch

        // Scroll if any aren't visible.
        if !standing.exists { app.swipeUp() }

        XCTAssertTrue(standing.waitForExistence(timeout: 5),
                      "Standing approvals nav row should be present")
        standing.tap()
        XCTAssertTrue(app.staticTexts["Standing approvals"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.firstMatch.tap()

        XCTAssertTrue(voice.waitForExistence(timeout: 5),
                      "Voice nav row should be present")
        voice.tap()
        XCTAssertTrue(app.staticTexts["Voice"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.firstMatch.tap()

        XCTAssertTrue(diagnostics.waitForExistence(timeout: 5),
                      "Diagnostics nav row should be present")
        diagnostics.tap()
        XCTAssertTrue(app.staticTexts["Diagnostics"].waitForExistence(timeout: 5))
    }
}
