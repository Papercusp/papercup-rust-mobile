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
import Darwin

@_silgen_name("notify_register_check")
private func notify_register_check(_ name: UnsafePointer<CChar>, _ token: UnsafeMutablePointer<Int32>) -> Int32
@_silgen_name("notify_get_state")
private func notify_get_state(_ token: Int32, _ state: UnsafeMutablePointer<UInt64>) -> Int32
@_silgen_name("notify_set_state")
private func notify_set_state(_ token: Int32, _ state: UInt64) -> Int32
@_silgen_name("notify_post")
private func notify_post(_ name: UnsafePointer<CChar>) -> Int32
@_silgen_name("notify_cancel")
private func notify_cancel(_ token: Int32) -> Int32

private let notifyOK: Int32 = 0

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

    /// Accessibility keeps the full label even when SwiftUI truncates it.
    /// Check the rendered bounds against the space needed for the full text.
    @MainActor
    private func assertUnclippedText(_ element: XCUIElement, font: UIFont,
                                    file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.exists, file: file, line: line)
        let bounds = element.frame
        XCTAssertGreaterThan(bounds.width, 0, file: file, line: line)
        let required = (element.label as NSString).boundingRect(
            with: CGSize(width: bounds.width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font], context: nil).height
        // UIKit typographic leading and SwiftUI pixel-snapped baselines differ
        // by less than two points here; a missing line is much taller.
        XCTAssertGreaterThanOrEqual(bounds.height + 2, ceil(required),
                                    "Full guidance must fit its rendered text bounds",
                                    file: file, line: line)
    }

    @MainActor
    private func pastePairPayload(_ app: XCUIApplication, payload: String) throws {
        let manual = try XCTUnwrap(app.buttons["Paste manually"].waitForExistence(timeout: 10)
                                   ? app.buttons["Paste manually"] : nil)
        manual.tap()
        let editor = app.textViews.firstMatch
        _ = try XCTUnwrap(editor.waitForExistence(timeout: 5) ? editor : nil)
        // typeText logs its argument. Use the real edit menu to keep tokens
        // out of retained XCTest output.
        UIPasteboard.general.string = payload
        editor.tap()
        editor.press(forDuration: 1)
        let paste = app.menuItems["Paste"].firstMatch
        let pasteExists = paste.waitForExistence(timeout: 5)
        if !pasteExists { retainScreenshot(app, named: "manual-paste-menu-missing") }
        _ = try XCTUnwrap(pasteExists ? paste : nil, "Manual editor must offer Paste")
        paste.tap()
        let allowPaste = app.buttons["Allow Paste"].firstMatch
        if allowPaste.waitForExistence(timeout: 2) { allowPaste.tap() }
        let pair = app.buttons["Pair"]
        _ = try XCTUnwrap(pair.isEnabled ? pair : nil, "Pasted payload must enable pairing")
        pair.tap()
    }

    @MainActor
    private func visiblePair(_ app: XCUIApplication, payload: String) throws {
        try pastePairPayload(app, payload: payload)
        let loaded = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] %@ OR label CONTAINS[c] %@",
                        "awaiting you", "All clear")
        ).firstMatch
        _ = try XCTUnwrap(loaded.waitForExistence(timeout: 30) ? loaded : nil,
                          "A real authorized attention read must complete after pairing")
    }

    /// Actual Settings switching against the owned two-workspace backend.
    /// Distinct device rows prove the new token changes reads, beyond the header label.
    @MainActor
    func testOwnedWorkspaceSwitchAndKeychainRelaunch() throws {
        guard let raw = ProcessInfo.processInfo.environment["PAPERCUP_PAIR_PAYLOAD"], !raw.isEmpty else {
            throw XCTSkip("A fresh owned two-workspace fixture payload is required.")
        }
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
        let workspace = try XCTUnwrap(payload["workspaceId"] as? String)
        let base = try XCTUnwrap(URL(string: try XCTUnwrap(payload["server"] as? String)))
        _ = try XCTUnwrap(workspace.hasPrefix("test-runtime-") && base.scheme == "https" &&
                          base.host?.hasPrefix("native-iphone-") == true ? base : nil,
                          "Use only the owned public HTTPS fixture")
        let app = XCUIApplication()
        defer { UIPasteboard.general.string = nil; app.terminate() }
        #if targetEnvironment(simulator)
        // The Simulator Hardware > Face ID controls use these notifications.
        // Enroll the simulated sensor, then provide a match only after the
        // real LocalAuthentication UI opens. Keep the production gate intact.
        var enrollment: Int32 = 0
        XCTAssertEqual("com.apple.BiometricKit.enrollmentChanged".withCString {
            notify_register_check($0, &enrollment)
        }, notifyOK)
        var priorEnrollment: UInt64 = 0
        XCTAssertEqual(notify_get_state(enrollment, &priorEnrollment), notifyOK)
        XCTAssertEqual(notify_set_state(enrollment, 1), notifyOK)
        XCTAssertEqual("com.apple.BiometricKit.enrollmentChanged".withCString {
            notify_post($0)
        }, notifyOK)
        defer {
            notify_set_state(enrollment, priorEnrollment)
            "com.apple.BiometricKit.enrollmentChanged".withCString { notify_post($0) }
            notify_cancel(enrollment)
        }
        #endif
        func settings() throws {
            let tab = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Settings")).firstMatch
            _ = try XCTUnwrap(tab.waitForExistence(timeout: 15) ? tab : nil)
            tab.tap()
        }
        func assertWorkspace(_ name: String, marker: String, absentMarker: String) throws {
            XCTAssertTrue(app.buttons["Current Pot: \(name). Tap to switch."].waitForExistence(timeout: 20),
                          "Selected workspace must render")
            let row = app.staticTexts[marker]
            XCTAssertTrue(row.waitForExistence(timeout: 20), "Authorized device data must come from the selected workspace")
            XCTAssertFalse(app.staticTexts[absentMarker].exists, "Other-workspace data must stay isolated")
            for _ in 0..<8 {
                if row.isHittable { break }
                app.swipeUp()
            }
            XCTAssertTrue(row.isHittable, "Retained screenshot must show the selected workspace marker")
        }
        func switchTo(_ name: String) throws {
            let link = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Switch workspace")).firstMatch
            for _ in 0..<8 {
                if link.isHittable { break }
                app.swipeDown()
            }
            _ = try XCTUnwrap(link.isHittable ? link : nil)
            link.tap()
            let choice = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", name)).firstMatch
            _ = try XCTUnwrap(choice.waitForExistence(timeout: 15) && choice.isEnabled ? choice : nil)
            choice.tap()
            #if targetEnvironment(simulator)
            // iOS asks for Face ID permission the first time this app uses
            // LocalAuthentication. XCTest cannot approve the biometric match
            // while that privacy alert is still on screen, so accept the
            // simulator-only consent before posting the simulated match.
            let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            let faceIDPermission = springboard.alerts.buttons["Allow"].firstMatch
            if faceIDPermission.waitForExistence(timeout: 5) {
                faceIDPermission.tap()
            }
            XCTAssertFalse(app.buttons["Current Pot: \(name). Tap to switch."].exists,
                           "Workspace must not change before authentication approves")
            XCTAssertEqual("com.apple.BiometricKit_Sim.pearl.match".withCString {
                notify_post($0)
            }, notifyOK)
            #endif
            XCTAssertTrue(app.buttons["Current Pot: \(name). Tap to switch."].waitForExistence(timeout: 30),
                          "Workspace switch must update the paired shell")
            // The new token rebuilds PairedShell and its Settings navigation.
            try settings()
        }
        app.launchArguments = ["-com.papercuspai.uitests.wipeCredentials", "YES"]
        app.launch()
        try visiblePair(app, payload: raw)
        UIPasteboard.general.string = nil
        try settings()
        try assertWorkspace("Native workspace A", marker: "Native workspace A marker", absentMarker: "Native workspace B marker")
        retainScreenshot(app, named: "workspace-switch-original-A-data")
        try switchTo("Native workspace B")
        try assertWorkspace("Native workspace B", marker: "Native workspace B marker", absentMarker: "Native workspace A marker")
        retainScreenshot(app, named: "workspace-switch-B-isolated-data")
        app.terminate()
        app.launchArguments = []
        app.launch()
        XCTAssertFalse(app.staticTexts["Pair with your desktop"].exists)
        try settings()
        try assertWorkspace("Native workspace B", marker: "Native workspace B marker", absentMarker: "Native workspace A marker")
        retainScreenshot(app, named: "workspace-switch-B-keychain-relaunch")
        try switchTo("Native workspace A")
        try assertWorkspace("Native workspace A", marker: "Native workspace A marker", absentMarker: "Native workspace B marker")
        retainScreenshot(app, named: "workspace-switch-return-A-data")
    }

    /// The maintained disposable fixture terminates its actual operator after
    /// the first authorized heartbeat, then starts a new PID with the same
    /// private database and signing identity. No controlled responder or seed.
    @MainActor
    func testOwnedOperatorOfflineThenRecoversWithoutRepairing() throws {
        guard let raw = ProcessInfo.processInfo.environment["PAPERCUP_PAIR_PAYLOAD"], !raw.isEmpty else {
            throw XCTSkip("A fresh owned public HTTPS fixture payload is required.")
        }
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
        let workspace = try XCTUnwrap(payload["workspaceId"] as? String)
        let server = try XCTUnwrap(payload["server"] as? String)
        let base = try XCTUnwrap(URL(string: server))
        _ = try XCTUnwrap(workspace.hasPrefix("test-runtime-") && base.scheme == "https" &&
                          base.host?.hasPrefix("native-iphone-") == true ? base : nil,
                          "Use only the owned interruptible fixture")
        let app = XCUIApplication()
        defer { UIPasteboard.general.string = nil; app.terminate() }
        app.launchArguments = ["-com.papercuspai.uitests.wipeCredentials", "YES"]
        app.launch()
        try visiblePair(app, payload: raw)
        UIPasteboard.general.string = nil
        retainScreenshot(app, named: "owned-operator-authorized-before-stop")
        let title = app.staticTexts["offline-banner-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 90), "Stopping the real operator must show offline recovery")
        XCTAssertEqual(title.label, "Desktop offline")
        XCTAssertFalse(app.buttons["pairAgainButton"].exists)
        XCTAssertFalse(app.staticTexts["Pair with your desktop"].exists)
        retainScreenshot(app, named: "owned-operator-stopped-keeps-pairing")
        let recovered = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: title)
        wait(for: [recovered], timeout: 180)
        XCTAssertFalse(app.buttons["pairAgainButton"].exists)
        XCTAssertFalse(app.staticTexts["Pair with your desktop"].exists)
        let recoveredInbox = app.staticTexts.matching(NSPredicate(
            format: "label CONTAINS[c] %@ OR label CONTAINS[c] %@", "awaiting you", "All clear"
        )).firstMatch
        XCTAssertTrue(recoveredInbox.waitForExistence(timeout: 30),
                      "Recovery must restore authorized inbox content before any relaunch")
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(
            format: "label CONTAINS[c] %@", "HTTP 502"
        )).firstMatch.exists, "The outage error must clear when inbox content recovers")
        retainScreenshot(app, named: "owned-operator-recovered-without-repairing")
        app.terminate()
        app.launchArguments = []
        app.launch()
        let loaded = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@ OR label CONTAINS[c] %@",
                                                        "awaiting you", "All clear")).firstMatch
        XCTAssertTrue(loaded.waitForExistence(timeout: 30), "Ordinary relaunch must still authorize the original pairing")
        XCTAssertFalse(app.staticTexts["Pair with your desktop"].exists)
        XCTAssertFalse(app.buttons["pairAgainButton"].exists)
        XCTAssertFalse(title.exists)
        retainScreenshot(app, named: "owned-operator-recovered-keychain-relaunch")
    }

    /// Real expired-token refusal followed by fresh pairing on the same owned
    /// public backend. No credential seed or controlled HTTP responder.
    @MainActor
    func testPublicExpiredPairThenFreshPair() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let raw = env["PAPERCUP_PAIR_PAYLOAD"], !raw.isEmpty,
              let expiredRaw = env["PAPERCUP_EXPIRED_PAIR_PAYLOAD"], !expiredRaw.isEmpty else {
            throw XCTSkip("Fresh and expired private fixture payloads are required.")
        }
        let fresh = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
        let expired = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(expiredRaw.utf8)) as? [String: Any])
        let server = try XCTUnwrap(fresh["server"] as? String)
        let workspace = try XCTUnwrap(fresh["workspaceId"] as? String)
        let base = try XCTUnwrap(URL(string: server))
        _ = try XCTUnwrap(workspace.hasPrefix("test-runtime-") && base.scheme == "https" &&
                          base.host?.hasPrefix("native-iphone-") == true ? base : nil,
                          "Use only the owned public HTTPS fixture")
        XCTAssertEqual(expired["server"] as? String, server)
        XCTAssertEqual(expired["workspaceId"] as? String, workspace)
        let expiredToken = try XCTUnwrap(expired["pairToken"] as? String)
        let freshToken = try XCTUnwrap(fresh["pairToken"] as? String)
        XCTAssertFalse(expiredToken == freshToken,
                       "Expired and fresh fixture tokens must be distinct")
        let app = XCUIApplication()
        defer { UIPasteboard.general.string = nil; app.terminate() }
        app.launchArguments = ["-com.papercuspai.uitests.wipeCredentials", "YES"]
        app.launch()
        try pastePairPayload(app, payload: expiredRaw)
        let guidance = app.staticTexts["That pairing code was already used or expired. Mint a fresh one from your desktop."]
        XCTAssertTrue(guidance.waitForExistence(timeout: 30))
        XCTAssertTrue(app.buttons["Try again"].exists)
        let operatorTab = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Operator")).firstMatch
        XCTAssertFalse(operatorTab.exists)
        // Hide private input before retaining the recovery screen.
        let back = try XCTUnwrap(app.buttons["Back"].exists ? app.buttons["Back"] : nil)
        back.tap()
        UIPasteboard.general.string = nil
        XCTAssertFalse(app.textViews.firstMatch.exists)
        XCTAssertTrue(guidance.exists)
        assertUnclippedText(guidance, font: .monospacedSystemFont(
            ofSize: UIFont.preferredFont(forTextStyle: .footnote).pointSize, weight: .regular))
        let instructions = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "Remote access")).firstMatch
        assertUnclippedText(instructions, font: .preferredFont(forTextStyle: .callout))
        XCTAssertTrue(app.buttons["Try again"].isHittable)
        retainScreenshot(app, named: "expired-pair-fresh-code-guidance")
        app.terminate()
        app.launchArguments = []
        app.launch()
        XCTAssertTrue(app.staticTexts["Pair with your desktop"].waitForExistence(timeout: 10),
                      "Failed pairing must not leave an authorized Keychain credential")
        retainScreenshot(app, named: "expired-pair-ordinary-relaunch-unpaired")
        try visiblePair(app, payload: raw)
        XCTAssertTrue(operatorTab.waitForExistence(timeout: 10),
                      "Fresh pairing must show the authorized Operator tab")
        retainScreenshot(app, named: "expired-pair-fresh-code-authorized")
        app.terminate()
        app.launch()
        let loaded = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@ OR label CONTAINS[c] %@",
                                                        "awaiting you", "All clear")).firstMatch
        XCTAssertTrue(loaded.waitForExistence(timeout: 30))
        XCTAssertFalse(app.staticTexts["Pair with your desktop"].exists)
        retainScreenshot(app, named: "expired-pair-fresh-keychain-relaunch")
    }

    /// P-008 public-network acceptance uses the real protected HTTPS listener,
    /// with no local forwarding route or controlled HTTP responder.
    @MainActor
    func testPublicHTTPSPairAndAuthorizedAttention() async throws {
        guard let raw = ProcessInfo.processInfo.environment["PAPERCUP_PAIR_PAYLOAD"],
              !raw.isEmpty else {
            throw XCTSkip("A fresh owned public HTTPS pairing payload is required.")
        }
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
        let workspace = try XCTUnwrap(payload["workspaceId"] as? String)
        let server = try XCTUnwrap(payload["server"] as? String)
        let base = try XCTUnwrap(URL(string: server))
        _ = try XCTUnwrap(workspace.hasPrefix("test-runtime-") ? workspace : nil,
                          "Use an owned disposable workspace")
        _ = try XCTUnwrap(base.scheme == "https" && base.host?.hasPrefix("native-iphone-") == true
                          ? base : nil, "Acceptance requires the owned public HTTPS fixture")
        XCTAssertNil(base.user)
        XCTAssertNil(base.password)

        // Probe from the actual iOS URLSession stack, before spending the token.
        // A Cloudflare rejection cannot satisfy the heartbeat's exact 401.
        for (path, method, expected) in [
            ("api/health", "GET", 404),
            ("api/workspaces", "GET", 404),
            ("api/device/desktop/mint-pair-token", "POST", 404),
            ("api/device/heartbeat", "POST", 401),
        ] {
            var request = URLRequest(url: base.appendingPathComponent(path))
            request.httpMethod = method
            request.timeoutInterval = 15
            let (_, response) = try await URLSession.shared.data(for: request)
            let status = try XCTUnwrap(response as? HTTPURLResponse).statusCode
            XCTAssertEqual(status, expected, "Protected public route \(path) must retain its boundary")
            guard status == expected else { throw NSError(domain: "PublicHTTPSBoundary", code: status) }
        }

        let app = XCUIApplication()
        defer {
            UIPasteboard.general.string = nil
            app.terminate()
        }
        app.launchArguments = ["-com.papercuspai.uitests.wipeCredentials", "YES"]
        app.launch()
        try visiblePair(app, payload: raw)
        XCTAssertFalse(app.buttons["pairAgainButton"].exists)
        XCTAssertFalse(app.staticTexts["offline-banner-title"].exists)
        retainScreenshot(app, named: "public-https-authorized-attention")
    }

    /// First stage of the runner's actual simctl uninstall/reinstall journey.
    @MainActor
    func testPairBeforeActualReinstall() throws {
        guard let raw = ProcessInfo.processInfo.environment["PAPERCUP_PAIR_PAYLOAD"], !raw.isEmpty else {
            throw XCTSkip("An owned pairing payload is required for reinstall acceptance.")
        }
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
        let workspace = try XCTUnwrap(payload["workspaceId"] as? String)
        let base = try XCTUnwrap(URL(string: try XCTUnwrap(payload["server"] as? String)))
        _ = try XCTUnwrap(workspace.hasPrefix("test-runtime-") ? workspace : nil)
        _ = try XCTUnwrap(base.scheme == "http" && ["127.0.0.1", "localhost"].contains(base.host ?? "")
                          ? base : nil, "Reinstall acceptance uses the owned private operator fixture")
        let app = XCUIApplication()
        defer { UIPasteboard.general.string = nil; app.terminate() }
        app.launchArguments = ["-com.papercuspai.uitests.wipeCredentials", "YES"]
        app.launch()
        try visiblePair(app, payload: raw)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Operator")).firstMatch.exists)
        retainScreenshot(app, named: "reinstall-original-authorized")
    }

    /// Positive control: this process receives no payload or credential seed.
    @MainActor
    func testAuthorizedRelaunchBeforeActualReinstall() throws {
        guard ProcessInfo.processInfo.environment["PAPERCUP_REINSTALL_PHASE"] == "before-uninstall" else {
            throw XCTSkip("Run through the maintained reinstall journey.")
        }
        let app = XCUIApplication()
        defer { app.terminate() }
        app.launchArguments = []
        app.launch()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Operator"))
            .firstMatch.waitForExistence(timeout: 15))
        let loaded = app.staticTexts.matching(NSPredicate(
            format: "label CONTAINS[c] %@ OR label CONTAINS[c] %@", "awaiting you", "All clear")).firstMatch
        XCTAssertTrue(loaded.waitForExistence(timeout: 30), "Persisted credentials must authorize a real read")
        XCTAssertFalse(app.buttons["Paste manually"].exists)
        XCTAssertFalse(app.buttons["pairAgainButton"].exists)
        retainScreenshot(app, named: "reinstall-positive-ordinary-relaunch")
    }

    /// Negative control follows successful OS uninstall and a new data container.
    /// Neither launch uses the wipe-credentials backdoor.
    @MainActor
    func testActualReinstallClearsOldPairing() throws {
        guard ProcessInfo.processInfo.environment["PAPERCUP_REINSTALL_PHASE"] == "after-uninstall" else {
            throw XCTSkip("Actual uninstall/reinstall must precede this test.")
        }
        let app = XCUIApplication()
        defer { app.terminate() }
        app.launchArguments = []
        for launch in 1...2 {
            app.launch()
            XCTAssertTrue(app.staticTexts["Pair with your desktop"].waitForExistence(timeout: 15))
            XCTAssertTrue(app.buttons["Paste manually"].exists)
            XCTAssertTrue(app.buttons["Scan QR"].exists)
            XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Operator"))
                .firstMatch.exists, "Reinstall must not resume old pairing")
            XCTAssertFalse(app.buttons["pairAgainButton"].exists)
            retainScreenshot(app, named: "actual-reinstall-onboarding-\(launch)")
            app.terminate()
        }
    }

    /// Smoke test: a fresh-install app launches into PairView with the
    /// expected affordances visible. No backend needed; covers the
    /// SceneManifest fix + CredentialStore + PairView wiring.
    @MainActor
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
        assertUnclippedText(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "Remote access")).firstMatch,
                           font: .preferredFont(forTextStyle: .callout))
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
    @MainActor
    func testPairAndPairedNavigation() throws {
        guard let payload = ProcessInfo.processInfo.environment["PAPERCUP_PAIR_PAYLOAD"],
              !payload.isEmpty else {
            throw XCTSkip("PAPERCUP_PAIR_PAYLOAD not set — runner provides this from a freshly minted PG token.")
        }

        let app = XCUIApplication()
        defer { UIPasteboard.general.string = nil; app.terminate() }
        app.launchArguments = ["-com.papercuspai.uitests.wipeCredentials", "YES"]
        // WI-4984 regression rig: delay the converse SSE drain by 8s so the
        // chat leg below can prove the submitted turn renders BEFORE the
        // drain completes (the optimistic/persisted-early path). Without
        // the fix, the marker only appears after converse finishes — which
        // this delay pushes past the 6s assertion window.
        app.launchEnvironment["PAPERCUP_UITEST_CONVERSE_DELAY_MS"] = "8000"
        app.launch()

        XCTAssertTrue(app.staticTexts["Pair with your desktop"].waitForExistence(timeout: 10))
        try pastePairPayload(app, payload: payload)

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
        let expectedReply = "Paired iOS reply \(UUID().uuidString)"
        let marker = "Live iOS sim E2E (su-e7a83). Reply with exactly this text and no other words: \(expectedReply)"
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
        // A failed backend also clears the thinking bubble. Require a unique
        // assistant reply: the user's longer prompt cannot match this exact
        // static-text label, and an earlier conversation cannot supply it.
        // 120s budget — a real operator turn burns a model call.
        let working = app.staticTexts["Operator is working…"]
        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: working, handler: nil)
        waitForExpectations(timeout: 120)
        XCTAssertTrue(app.staticTexts[expectedReply].waitForExistence(timeout: 10),
                      "a completed send must render the actual assistant reply, not just dismiss its spinner")
        retainScreenshot(app, named: "paired-chat-reply")

        // Normal relaunch must load Keychain credentials without re-consuming
        // the one-shot Remote access pair token or using a credential hook.
        app.terminate()
        app.launchArguments = []
        app.launch()
        XCTAssertTrue(operatorTab.waitForExistence(timeout: 20),
                      "Keychain pairing should survive an ordinary relaunch")
        XCTAssertFalse(app.staticTexts["Pair with your desktop"].exists,
                       "a paired relaunch must not return to onboarding")
        XCTAssertTrue(app.staticTexts["Needs you"].waitForExistence(timeout: 10),
                      "an ordinary paired relaunch should open the default Inbox tab")
        // AppRoot starts on Inbox. Open Operator so the reply assertion
        // exercises a new persisted conversation read after the relaunch.
        operatorTab.tap()
        XCTAssertTrue(app.staticTexts[expectedReply].waitForExistence(timeout: 20),
                      "the assistant reply must survive a fresh persisted conversation read after relaunch")
        retainScreenshot(app, named: "paired-keychain-relaunch")
    }

    /// P-008 live authorization acceptance against an owned disposable operator.
    /// Desktop controls travel over its private loopback forwarding route; no
    /// production workspace, credential seed or controlled HTTP responder is used.
    @MainActor
    func testLiveRevocationAndRepairing() async throws {
        guard let raw = ProcessInfo.processInfo.environment["PAPERCUP_PAIR_PAYLOAD"],
              !raw.isEmpty else {
            throw XCTSkip("A fresh private operator pairing payload is required.")
        }
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
        let workspace = try XCTUnwrap(payload["workspaceId"] as? String)
        let server = try XCTUnwrap(payload["server"] as? String)
        let base = try XCTUnwrap(URL(string: server))
        // Loopback controls are safe only in the isolated operator-api fixture.
        // Refuse an arbitrary live desktop before listing or revoking anything.
        XCTAssertTrue(workspace.hasPrefix("test-runtime-"), "Use an owned disposable workspace")
        XCTAssertTrue(base.scheme == "http" && ["127.0.0.1", "localhost"].contains(base.host ?? ""),
                      "Desktop controls require the private loopback route")
        guard workspace.hasPrefix("test-runtime-"), base.scheme == "http",
              ["127.0.0.1", "localhost"].contains(base.host ?? "") else { return }

        func control(_ path: String, method: String = "GET", body: [String: String]? = nil) async throws -> [String: Any] {
            var request = URLRequest(url: base.appendingPathComponent("api/device/desktop/" + path))
            request.httpMethod = method
            request.timeoutInterval = 15
            if let body {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
            }
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = try XCTUnwrap(response as? HTTPURLResponse).statusCode
            XCTAssertEqual(status, 200, "Owned desktop control must succeed")
            guard status == 200 else { throw NSError(domain: "OwnedOperatorControl", code: status) }
            // Do not put response bytes or pairing tokens in an assertion/log.
            return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        func ownedDevices() async throws -> [[String: Any]] {
            let response = try await control("devices")
            return try XCTUnwrap(response["devices"] as? [[String: Any]])
                .filter { ($0["workspace_id"] as? String) == workspace }
        }
        let initialDevices = try await ownedDevices()
        XCTAssertEqual(initialDevices.count, 0, "Fixture must start without paired devices")
        let app = XCUIApplication()
        defer {
            UIPasteboard.general.string = nil
            app.terminate()
        }
        app.launchArguments = ["-com.papercuspai.uitests.wipeCredentials", "YES"]
        app.launch()
        try visiblePair(app, payload: raw)
        let originalDevices = try await ownedDevices()
        XCTAssertEqual(originalDevices.count, 1)
        let original = try XCTUnwrap(originalDevices.first?["device_id"] as? String)
        retainScreenshot(app, named: "live-authorized-before-revocation")

        _ = try await control("devices/" + original, method: "DELETE")
        XCUIDevice.shared.press(.home)
        app.activate()
        let pairAgain = app.buttons["pairAgainButton"]
        XCTAssertTrue(pairAgain.waitForExistence(timeout: 30),
                      "Real backend revocation must produce native re-pair guidance")
        XCTAssertFalse(app.staticTexts["offline-banner-title"].exists)
        retainScreenshot(app, named: "live-revoked-offers-pair-again")
        pairAgain.tap()
        XCTAssertTrue(app.staticTexts["Pair with your desktop"].waitForExistence(timeout: 10))
        app.terminate()
        app.launchArguments = []
        app.launch()
        XCTAssertTrue(app.staticTexts["Pair with your desktop"].waitForExistence(timeout: 10),
                      "Revoked credentials must stay cleared across ordinary relaunch")
        retainScreenshot(app, named: "live-revoked-keychain-cleared")

        let minted = try await control("mint-pair-token", method: "POST", body: ["workspaceId": workspace])
        var fresh = try XCTUnwrap(minted["qrPayload"] as? [String: Any])
        XCTAssertEqual(fresh["workspaceId"] as? String, workspace)
        fresh["server"] = server // same owned loopback forwarding route
        let freshJSON = try JSONSerialization.data(withJSONObject: fresh)
        try visiblePair(app, payload: try XCTUnwrap(String(data: freshJSON, encoding: .utf8)))
        let repairedDevices = try await ownedDevices()
        XCTAssertEqual(repairedDevices.count, 1)
        let repaired = try XCTUnwrap(repairedDevices.first?["device_id"] as? String)
        XCTAssertNotEqual(repaired, original, "Re-pairing must issue a fresh device identity")
        XCTAssertFalse(app.buttons["pairAgainButton"].exists)
        retainScreenshot(app, named: "live-repaired-authorized-workspace")
        _ = try await control("devices/" + repaired, method: "DELETE")
    }

    /// The real backend advances only its isolated JWT clock after the first
    /// phone heartbeat. The original signing key and unrevoked row stay intact.
    @MainActor
    func testLiveDeviceExpiryAndRepairing() async throws {
        guard let raw = ProcessInfo.processInfo.environment["PAPERCUP_PAIR_PAYLOAD"], !raw.isEmpty else {
            throw XCTSkip("A fresh private operator pairing payload is required.")
        }
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
        let workspace = try XCTUnwrap(payload["workspaceId"] as? String)
        let server = try XCTUnwrap(payload["server"] as? String)
        let base = try XCTUnwrap(URL(string: server))
        XCTAssertTrue(workspace.hasPrefix("test-runtime-"), "Use an owned disposable workspace")
        XCTAssertTrue(base.scheme == "http" && base.host == "127.0.0.1" && base.port != nil,
                      "Desktop controls require the owned private loopback route")
        let ownedRoute = workspace.hasPrefix("test-runtime-") && base.scheme == "http" &&
            base.host == "127.0.0.1" && base.port != nil && ![3070, 3170, 3055].contains(base.port ?? 0) &&
            (base.path.isEmpty || base.path == "/") && base.query == nil && base.fragment == nil &&
            base.user == nil && base.password == nil
        _ = try XCTUnwrap(ownedRoute ? true : nil, "Expiry controls require the exact owned loopback fixture")
        func control(_ path: String, method: String = "GET", body: [String: String]? = nil) async throws -> [String: Any] {
            var request = URLRequest(url: base.appendingPathComponent("api/device/desktop/" + path))
            request.httpMethod = method
            request.timeoutInterval = 15
            if let body {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
            }
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = try XCTUnwrap(response as? HTTPURLResponse).statusCode
            XCTAssertEqual(status, 200, "Owned desktop control must succeed")
            guard status == 200 else { throw NSError(domain: "OwnedOperatorControl", code: status) }
            return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        func devices() async throws -> [[String: Any]] {
            let response = try await control("devices")
            return try XCTUnwrap(response["devices"] as? [[String: Any]])
                .filter { ($0["workspace_id"] as? String) == workspace }
        }
        let initial = try await devices()
        XCTAssertEqual(initial.count, 0)
        let app = XCUIApplication()
        defer { UIPasteboard.general.string = nil; app.terminate() }
        app.launchArguments = ["-com.papercuspai.uitests.wipeCredentials", "YES"]
        app.launch()
        try visiblePair(app, payload: raw)
        let paired = try await devices()
        XCTAssertEqual(paired.count, 1)
        let original = try XCTUnwrap(paired.first?["device_id"] as? String)
        retainScreenshot(app, named: "device-expiry-authorized-positive-control")
        XCUIDevice.shared.press(.home)
        app.activate()
        let pairAgain = app.buttons["pairAgainButton"]
        XCTAssertTrue(pairAgain.waitForExistence(timeout: 60),
                      "Real expired device JWT must produce native re-pair guidance")
        XCTAssertFalse(app.staticTexts["offline-banner-title"].exists)
        let expired = try await devices()
        XCTAssertEqual(expired.count, 1)
        XCTAssertEqual(expired.first?["device_id"] as? String, original,
                       "Expiry must preserve the original unrevoked device")
        retainScreenshot(app, named: "device-expiry-offers-pair-again")
        pairAgain.tap()
        XCTAssertTrue(app.staticTexts["Pair with your desktop"].waitForExistence(timeout: 10))
        app.terminate()
        app.launchArguments = []
        app.launch()
        XCTAssertTrue(app.staticTexts["Pair with your desktop"].waitForExistence(timeout: 10),
                      "Expired credentials must remain cleared across an ordinary unseeded relaunch")
        retainScreenshot(app, named: "device-expiry-keychain-cleared")
        let minted = try await control("mint-pair-token", method: "POST", body: ["workspaceId": workspace])
        var fresh = try XCTUnwrap(minted["qrPayload"] as? [String: Any])
        XCTAssertEqual(fresh["workspaceId"] as? String, workspace)
        fresh["server"] = server
        let freshJSON = try JSONSerialization.data(withJSONObject: fresh)
        try visiblePair(app, payload: try XCTUnwrap(String(data: freshJSON, encoding: .utf8)))
        let repaired = try await devices()
        XCTAssertEqual(repaired.count, 2, "Expired device stays unrevoked alongside the fresh pairing")
        XCTAssertTrue(repaired.contains { ($0["device_id"] as? String) == original })
        XCTAssertTrue(repaired.contains { ($0["device_id"] as? String) != original })
        XCTAssertFalse(app.buttons["pairAgainButton"].exists)
        app.terminate()
        app.launchArguments = []
        app.launch()
        let loaded = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@ OR label CONTAINS[c] %@",
                                                         "awaiting you", "All clear")).firstMatch
        XCTAssertTrue(loaded.waitForExistence(timeout: 30), "Fresh credentials must authorize after ordinary relaunch")
        retainScreenshot(app, named: "device-expiry-fresh-keychain-authorized")
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
