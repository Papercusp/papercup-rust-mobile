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
            // After a FAILED turn the pill stays "Error" by design, and
            // tapping it RETRIES (VoicePill maps .failed → start()), so a
            // soak must accept either pill here — idle-only wedged the run
            // one turn after any error.
            let preDeadline = Date().addingTimeInterval(20)
            var startPill: XCUIElement? = nil
            while Date() < preDeadline {
                if idlePill.exists { startPill = idlePill; break }
                if pill("Error").exists { startPill = pill("Error"); break }
                RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            }
            XCTAssertNotNil(startPill,
                            "turn \(turn): pill neither idle nor Error before tap")
            guard let startPill else { break }
            startPill.tap()

            // Inject hook fills the PCM and reports .listening. A transient
            // backend blip (session-init against a restarting server) shows
            // as Error instead — count it as a failed turn and move on,
            // like the Android soak tolerated transients.
            let startDeadline = Date().addingTimeInterval(15)
            // When the start tap was on the Error pill (retry), that pill
            // lingers until .listening lands — grace it so a stale Error
            // isn't miscounted as a fresh start failure.
            let errorGraceUntil = Date().addingTimeInterval(2)
            var started = false
            while Date() < startDeadline {
                if pill("Listening").exists { started = true; break }
                if Date() > errorGraceUntil, pill("Error").exists { break }
                RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            }
            if !started {
                errors += 1
                // Leave the Error pill in place — the next turn's pre-tap
                // wait taps it as the retry entry point.
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
                // Leave the Error pill showing — tapping it would START a
                // retry session (not reset to idle); the next turn's
                // pre-tap wait uses it as the start tap.
            }
        }

        XCTAssertLessThanOrEqual(
            errors, max(1, turns / 5),
            "voice soak: \(errors)/\(turns) turns errored — beyond the transient tolerance")
    }
}
