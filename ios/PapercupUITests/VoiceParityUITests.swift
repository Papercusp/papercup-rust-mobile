// SPDX-License-Identifier: GPL-3.0-or-later
//
// Voice-parity soak (WI-5091) — mirrors the Android injected-voice soak
// on the iOS simulator, where no microphone exists. Driven by
// run-ios-uitests.sh with TEST_RUNNER_*-forwarded env:
//
//   PAPERCUP_PAIR_PAYLOAD         — one-shot pair payload (fresh mint)
//   PAPERCUP_UITEST_VOICE_PCM_DIR — dir of turn-*.pcm fixtures (raw
//                                   16kHz mono PCM16). The app-side
//                                   inject hook (DesktopVoiceSession)
//                                   consumes one per Listen tap and
//                                   writes <dir>/results/*.result.json
//                                   (spoken reply, audio chunk count)
//                                   for the host-side grader.
//   PAPERCUP_UITEST_VOICE_TURNS   — turns to drive (default 10)
//
// The XCUITest layer asserts the STATE MACHINE (every turn terminates;
// errors stay under 20%); reply CONTENT is graded host-side from the
// result JSONs, exactly like the Android soak graded from logcat.

import XCTest

final class VoiceParityUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testInjectedVoiceSoak() throws {
        guard let payload = ProcessInfo.processInfo.environment["PAPERCUP_PAIR_PAYLOAD"],
              !payload.isEmpty else {
            throw XCTSkip("PAPERCUP_PAIR_PAYLOAD not set — runner mints it")
        }
        guard let pcmDir = ProcessInfo.processInfo.environment["PAPERCUP_UITEST_VOICE_PCM_DIR"],
              !pcmDir.isEmpty else {
            throw XCTSkip("PAPERCUP_UITEST_VOICE_PCM_DIR not set — voice soak only runs with fixtures")
        }
        let turns = Int(ProcessInfo.processInfo.environment["PAPERCUP_UITEST_VOICE_TURNS"] ?? "") ?? 10

        let app = XCUIApplication()
        app.launchArguments = [
            "-com.papercuspai.uitests.wipeCredentials", "YES",
            "-com.papercuspai.uitests.pairPayload", payload,
        ]
        app.launchEnvironment["PAPERCUP_UITEST_VOICE_PCM_DIR"] = pcmDir
        app.launch()

        // The VoicePill exposes "Voice: <Label>" accessibility labels
        // (AppRoot.VoicePill). Idle = exactly "Voice: Listen"; active
        // states append "(tap to stop)".
        func pill(_ prefix: String) -> XCUIElement {
            app.buttons
                .matching(NSPredicate(format: "label BEGINSWITH[c] %@", "Voice: \(prefix)"))
                .firstMatch
        }
        let idlePill = app.buttons["Voice: Listen"].firstMatch

        XCTAssertTrue(idlePill.waitForExistence(timeout: 25),
                      "Voice pill should appear after the pair backdoor")

        var errors = 0
        for turn in 1...turns {
            // The pill re-renders through a post-turn transient (reply text)
            // before settling back to idle — never tap without waiting.
            XCTAssertTrue(idlePill.waitForExistence(timeout: 20),
                          "turn \(turn): idle pill should be present before tap")
            idlePill.tap()

            // Inject hook fills the PCM and reports .listening. A transient
            // backend blip (session-init against a restarting server) shows
            // as Error instead — count it as a failed turn and move on,
            // like the Android soak tolerated transients.
            let startDeadline = Date().addingTimeInterval(15)
            var started = false
            while Date() < startDeadline {
                if pill("Listening").exists { started = true; break }
                if pill("Error").exists { break }
                RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            }
            if !started {
                errors += 1
                if pill("Error").exists { pill("Error").tap() }
                XCTAssertTrue(idlePill.waitForExistence(timeout: 10),
                              "turn \(turn): pill should reset to Listen after a start failure")
                continue
            }
            pill("Listening").tap() // send

            // Terminal: back to idle (ok) or Error shown. Replies can be
            // slow under provider pressure (Android saw one >70s turn),
            // so the window is generous.
            let deadline = Date().addingTimeInterval(150)
            var terminal: String? = nil
            while Date() < deadline {
                if idlePill.exists { terminal = "ok"; break }
                if pill("Error").exists { terminal = "error"; break }
                RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            }
            XCTAssertNotNil(terminal, "turn \(turn): voice turn never terminated within 150s")
            if terminal == "error" {
                errors += 1
                // Reset the pill for the next turn (tap dismisses/stops).
                pill("Error").tap()
                _ = idlePill.waitForExistence(timeout: 10)
            }
        }

        XCTAssertLessThanOrEqual(
            errors, max(1, turns / 5),
            "voice soak: \(errors)/\(turns) turns errored — beyond the transient tolerance")
    }
}
