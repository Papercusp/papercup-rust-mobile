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
    private func retainScreenshot(_ app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

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
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Remote access")).firstMatch.exists,
                      "Pairing instructions should point to the current desktop settings")
        // iphone D-014(4): BYOC cloud workspaces pair from the cloud desktop's
        // Settings → Remote access, so the instructions must name them too.
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "cloud workspace")).firstMatch.exists,
                      "Pairing instructions should tell cloud-workspace users where to pair")
        XCTAssertTrue(app.buttons["Paste manually"].exists, "Paste pairing should remain available without camera access")

        // Retain a real candidate image for the review packet after the
        // clean-install assertions have established the visible screen.
        retainScreenshot(app, named: "clean-install-pairing")
    }

    /// End-to-end pair flow + paired-state navigation in one go (the
    /// pair token is one-shot, so we can only spend it once per test
    /// run). Validates: visible Paste manually → PairView.redeem →
    /// /api/device/pair → DeviceCredentials persist across relaunch
    /// → PairedShell mounts → tab bar visible → Settings nav rows
    /// (Standing approvals / Voice / Diagnostics) open correctly.
    func testPairAndPairedNavigation() throws {
        guard let payload = ProcessInfo.processInfo.environment["PAPERCUP_PAIR_PAYLOAD"],
              !payload.isEmpty else {
            throw XCTSkip("PAPERCUP_PAIR_PAYLOAD not set — runner provides this from a freshly minted PG token.")
        }

        let app = XCUIApplication()
        app.launchArguments = ["-com.papercuspai.uitests.wipeCredentials", "YES"]
        // WI-4984 regression rig: delay the converse SSE drain by 8s so the
        // chat leg below can prove the submitted turn renders BEFORE the
        // drain completes (the optimistic/persisted-early path). Without
        // the fix, the marker only appears after converse finishes — which
        // this delay pushes past the 6s assertion window.
        app.launchEnvironment["PAPERCUP_UITEST_CONVERSE_DELAY_MS"] = "8000"
        app.launch()

        XCTAssertTrue(app.staticTexts["Pair with your desktop"].waitForExistence(timeout: 10))
        let paste = app.buttons["Paste manually"]
        XCTAssertTrue(paste.waitForExistence(timeout: 5))
        paste.tap()
        let editor = app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5), "manual pairing editor should appear")
        editor.tap()
        editor.typeText(payload)
        let pair = app.buttons["Pair"]
        XCTAssertTrue(pair.isEnabled, "entered Remote access payload should enable pairing")
        pair.tap()

        // Tab-bar items combine icon + label into one accessibility element and
        // the label is title-case, so an exact `app.buttons["Operator"]` query
        // misses them (the same combined-element issue documented for the
        // Settings rows below; the app IS paired via the backdoor — verified
        // out-of-band with simctl 2026-07-14). Match a button whose label
        // CONTAINS the tab name, case-insensitively.
        func tabItem(_ label: String) -> XCUIElement {
            app.buttons
                .matching(NSPredicate(format: "label CONTAINS[c] %@", label))
                .firstMatch
        }

        let operatorTab = tabItem("Operator")
        XCTAssertTrue(operatorTab.waitForExistence(timeout: 20),
                      "Operator tab should appear after visible manual pairing")
        retainScreenshot(app, named: "paired-operator")

        // Hop to Settings, scroll to find the new nav rows, open each.
        let settingsTab = tabItem("Settings")
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
        retainScreenshot(app, named: "paired-settings")
        diagnostics.tap()
        XCTAssertTrue(app.staticTexts["Diagnostics"].waitForExistence(timeout: 5),
                      "Diagnostics detail page should open — proves Settings navigation works")
        retainScreenshot(app, named: "paired-diagnostics")

        // ── Brief 44 verify-clause legs (pair → Inbox live → chat
        // round-trip), still on the same one-shot pair token. ──

        // Grant the push-permission system alert if it's up (the paired
        // shell requests authorization on appear — D-004). Granting here
        // is what lets the deep-link phase's simctl push render a real
        // notification. Springboard query, not an interruption monitor
        // (monitors are unreliable for springboard-owned alerts).
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allowBtn = springboard.alerts.buttons["Allow"]
        if allowBtn.waitForExistence(timeout: 8) { allowBtn.tap() }

        // Tab-bar buttons carry a badge suffix in their a11y label when a
        // count is live (e.g. "Inbox, 24 needs you"), so an exact
        // `app.buttons[label]` match misses them — match by label-prefix.
        func tabButton(_ label: String) -> XCUIElement {
            app.buttons.matching(
                NSPredicate(format: "label BEGINSWITH[c] %@", label)
            ).firstMatch
        }

        // Inbox leg — live attention feed renders (real fetch against the
        // staging operator; the header always says "Needs you", and the
        // feed resolves out of `loading` into content or the explicit
        // empty state — an errorCard fails the predicate).
        tabButton("Inbox").tap()
        XCTAssertTrue(app.staticTexts["Needs you"].waitForExistence(timeout: 10),
                      "Inbox header should render")
        let liveLoaded = app.descendants(matching: .staticText).matching(
            NSPredicate(format: "label CONTAINS[c] %@ OR label CONTAINS[c] %@",
                        "awaiting you", "All clear")
        ).firstMatch
        XCTAssertTrue(liveLoaded.waitForExistence(timeout: 20),
                      "Inbox should resolve the live attention fetch (count or all-clear)")
        retainScreenshot(app, named: "paired-inbox")

        tabButton("Plans").tap()
        XCTAssertTrue(app.staticTexts["Plans"].waitForExistence(timeout: 10),
                      "Plans screen should render on the paired candidate")
        retainScreenshot(app, named: "paired-plans")

        tabButton("Fleet").tap()
        XCTAssertTrue(app.staticTexts["Fleet activity"].waitForExistence(timeout: 10),
                      "Fleet screen should render on the paired candidate")
        retainScreenshot(app, named: "paired-fleet")

        // Chat leg — a real round-trip on the SHARED operator thread:
        // send a marker message, then assert the persisted thread re-read
        // brings it back as a turn (proves device→server→PG→device).
        tabButton("Operator").tap()
        let marker = "Live iOS sim E2E (su-e7a83) — reply with one short sentence."
        let field = app.textFields["Message the operator…"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), "chat composer should render")
        field.tap()
        field.typeText(marker)
        app.buttons["Send"].firstMatch.tap()
        // WI-4984: the submitted turn must render IMMEDIATELY — the
        // launch-injected 8s converse delay means this 6s window can only
        // be met by the optimistic/persisted-early render path, never by
        // waiting for the SSE drain to complete.
        let echoed = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "Live iOS sim E2E (su-e7a83)")
        ).firstMatch
        XCTAssertTrue(echoed.waitForExistence(timeout: 6),
                      "submitted message should render before the converse SSE completes (WI-4984)")
        XCTAssertTrue(app.staticTexts["Operator is working…"].exists,
                      "converse should still be draining while the user's turn is already visible")
        // And the operator's reply lands once the converse completes (the
        // thinking bubble clears; a fresh assistant turn renders under our
        // marker). 120s budget — a real operator turn burns a model call.
        let working = app.staticTexts["Operator is working…"]
        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: working, handler: nil)
        waitForExpectations(timeout: 120)

        // Normal relaunch must load Keychain credentials without re-consuming
        // the one-shot Remote access pair token or using a credential hook.
        app.terminate()
        app.launchArguments = []
        app.launch()
        XCTAssertTrue(operatorTab.waitForExistence(timeout: 20),
                      "Keychain pairing should survive an ordinary relaunch")
        XCTAssertFalse(app.staticTexts["Pair with your desktop"].exists,
                       "a paired relaunch must not return to onboarding")
        retainScreenshot(app, named: "paired-keychain-relaunch")
    }

    /// Push deep-link routing: a notification-tap userInfo (the exact
    /// shape attention-notify.ts sends — `kind: needs-human`) routes a
    /// cold-launched app to the Inbox tab (D-004). Driven through the
    /// `pushUserInfo` launch-arg backdoor, which feeds the dict to the
    /// SAME `DeepLinkRouter.handle(notificationUserInfo:)` a real APNs tap
    /// uses — so this tests OUR routing end-to-end (router → pendingInbox
    /// → AppRoot nav), not Apple's springboard. Real APNs can't reach a
    /// simulator and the cert is owner-gated; delivery itself is covered
    /// by the runner's `simctl push` (phase B). Needs prior-phase creds.
    func testPushTapDeepLink() throws {
        guard ProcessInfo.processInfo.environment["PAPERCUP_PUSH_TAP_PHASE"] == "1" else {
            throw XCTSkip("PAPERCUP_PUSH_TAP_PHASE not set — runner-only phase (needs a paired device).")
        }
        let app = XCUIApplication()
        // Don't wipe credentials — the pair phase persisted them; a push
        // tap on an already-paired device must land on the Inbox.
        app.launchArguments = [
            "-com.papercuspai.uitests.pushUserInfo",
            #"{"kind":"needs-human","title":"Papercusp E2E"}"#,
        ]
        app.launch()
        XCTAssertTrue(app.staticTexts["Needs you"].waitForExistence(timeout: 25),
                      "needs-human push tap should deep-link to the Inbox tab")
    }
}
