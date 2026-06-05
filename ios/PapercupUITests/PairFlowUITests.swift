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
    /// AppRoot.autoPair → /api/device/pair → DeviceCredentials persist
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

        // The PapercupNavRow rows combine their children into one
        // accessibility element, so an exact `app.buttons[label]` query
        // misses them (caught live 2026-06-05: pairing succeeded but the
        // row queries failed). Match by label-contains across element
        // types instead, and scroll until found.
        func settingsRow(_ label: String) -> XCUIElement {
            app.descendants(matching: .any)
                .matching(NSPredicate(format: "label CONTAINS[c] %@", label))
                .firstMatch
        }
        func assertRowPresent(_ label: String) {
            let row = settingsRow(label)
            for _ in 0..<4 where !row.exists {
                app.swipeUp()
            }
            XCTAssertTrue(row.waitForExistence(timeout: 5),
                          "\(label) nav row should be present in the redesigned Settings")
        }

        // The D-003 redesign reorganized Settings into pairing /
        // connection (Switch workspace · Standing approvals) / voice /
        // about (Diagnostics) / devices sections. Assert the three
        // navigable rows render, then prove navigation works by opening
        // ONE (avoids per-row back-nav, which the custom detail chrome
        // makes brittle — no standard NavigationBar back button).
        assertRowPresent("Standing approvals")
        assertRowPresent("Voice")
        let diagnostics = settingsRow("Diagnostics")
        assertRowPresent("Diagnostics")
        diagnostics.tap()
        XCTAssertTrue(app.staticTexts["Diagnostics"].waitForExistence(timeout: 5),
                      "Diagnostics detail page should open — proves Settings navigation works")
    }
}
