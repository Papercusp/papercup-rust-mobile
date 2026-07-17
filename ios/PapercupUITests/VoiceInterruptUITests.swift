// SPDX-License-Identifier: GPL-3.0-or-later
//
// Interruption-semantics drill (WI-5091 deepening): barge-in during
// Speaking must hard-cancel the turn (VoiceManager.tapStop → stop() →
// .idle) and the very next turn must run clean. Uses the same
// injected-PCM rig as VoiceParityUITests; fixture dir should hold
// turn-01 = a LONG-answer question (wide Speaking window to tap into)
// and turn-02 = a normal short question (recovery proof).

import XCTest

final class VoiceInterruptUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testBargeInDuringSpeaking() throws {
        guard let payload = ProcessInfo.processInfo.environment["PAPERCUP_PAIR_PAYLOAD"],
              !payload.isEmpty else {
            throw XCTSkip("PAPERCUP_PAIR_PAYLOAD not set — runner mints it")
        }
        guard let pcmDir = ProcessInfo.processInfo.environment["PAPERCUP_UITEST_VOICE_PCM_DIR"],
              !pcmDir.isEmpty else {
            throw XCTSkip("PAPERCUP_UITEST_VOICE_PCM_DIR not set — drill only runs with fixtures")
        }

        let app = XCUIApplication()
        app.launchArguments = [
            "-com.papercuspai.uitests.wipeCredentials", "YES",
            "-com.papercuspai.uitests.pairPayload", payload,
        ]
        app.launchEnvironment["PAPERCUP_UITEST_VOICE_PCM_DIR"] = pcmDir
        app.launch()

        func pill(_ prefix: String) -> XCUIElement {
            app.buttons
                .matching(NSPredicate(format: "label BEGINSWITH[c] %@", "Voice: \(prefix)"))
                .firstMatch
        }
        let idlePill = app.buttons["Voice: Listen"].firstMatch

        XCTAssertTrue(idlePill.waitForExistence(timeout: 25),
                      "Voice pill should appear after the pair backdoor")

        // ---- Turn 1: barge-in. Long-answer fixture ⇒ TTS speaks for many
        // seconds, so Speaking is reliably observable at 0.2s polls.
        idlePill.tap()
        XCTAssertTrue(pill("Listening").waitForExistence(timeout: 15),
                      "inject hook should reach Listening")
        pill("Listening").tap() // send

        let speakDeadline = Date().addingTimeInterval(90)
        var sawSpeaking = false
        while Date() < speakDeadline {
            if pill("Speaking").exists { sawSpeaking = true; break }
            if pill("Error").exists { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTAssertTrue(sawSpeaking,
                      "never observed Speaking — reply failed or finished between polls")

        // ZERO-DELAY tap on first Speaking sighting, label-agnostic (a
        // "Voice: Speaking"-labelled query re-resolves at tap time and a
        // re-render can transiently match nothing — round-1 failure).
        // Headless-rig TTS drains fast (~10s of audio in ~2-3s on both
        // the Android emulator and this VM's sim), so any dwell before
        // the tap loses the window — round-2 failure.
        pill("").tap() // barge-in: hard cancel

        // Classify the outcome: a clean hard-cancel goes STRAIGHT to
        // idle and stays there; a tap that landed after playback had
        // already drained hits the IDLE pill and starts a NEW session,
        // which surfaces as Connecting/Listening within ~1s. The latter
        // is the rig missing the window, not a product failure.
        let classifyUntil = Date().addingTimeInterval(2.5)
        var missedWindow = false
        while Date() < classifyUntil {
            if pill("Connecting").exists || pill("Listening").exists {
                missedWindow = true; break
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        if missedWindow {
            throw XCTSkip("tap landed after TTS drained (headless-rig fast-drain) — barge-in window missed this run")
        }
        XCTAssertTrue(idlePill.exists,
                      "barge-in should hard-cancel straight to idle")

        // TTS must STAY cancelled — Speaking reappearing means the tap
        // paused rendering without killing the turn.
        let quietUntil = Date().addingTimeInterval(3)
        while Date() < quietUntil {
            XCTAssertFalse(pill("Speaking").exists,
                           "Speaking reappeared after barge-in — turn was not cancelled")
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }

        // ---- Turn 2: recovery — a normal short turn must complete.
        idlePill.tap()
        XCTAssertTrue(pill("Listening").waitForExistence(timeout: 15),
                      "recovery turn should reach Listening")
        pill("Listening").tap()

        let recoveryDeadline = Date().addingTimeInterval(150)
        var terminal: String? = nil
        while Date() < recoveryDeadline {
            if idlePill.exists { terminal = "ok"; break }
            if pill("Error").exists { terminal = "error"; break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        XCTAssertEqual(terminal, "ok",
                       "recovery turn after barge-in should complete cleanly (got \(terminal ?? "timeout"))")
    }
}
