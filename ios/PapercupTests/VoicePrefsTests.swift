// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import PapercupCore
@testable import Papercup

final class VoicePrefsTests: XCTestCase {
    private let testKey = "papercup.voicePrefs.v1"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: testKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: testKey)
        super.tearDown()
    }

    func testLoadDefaultsWhenEmpty() {
        let prefs = VoicePrefsStore.load()
        XCTAssertEqual(prefs.wakeWord, "hey papercup")
        XCTAssertEqual(prefs.rate, 1.0)
        XCTAssertEqual(prefs.pitch, 1.0)
        XCTAssertNil(prefs.voiceIdentifier)
    }

    func testRoundTripPersistsAllFields() {
        let original = VoicePrefs(
            wakeWord: "computer",
            rate: 1.4,
            pitch: 0.8,
            voiceIdentifier: "com.apple.voice.test"
        )
        VoicePrefsStore.save(original)
        let loaded = VoicePrefsStore.load()
        XCTAssertEqual(loaded.wakeWord, "computer")
        XCTAssertEqual(loaded.rate, 1.4, accuracy: 0.001)
        XCTAssertEqual(loaded.pitch, 0.8, accuracy: 0.001)
        XCTAssertEqual(loaded.voiceIdentifier, "com.apple.voice.test")
    }

    func testNilVoiceIdentifierRoundTrips() {
        let original = VoicePrefs(wakeWord: "x", rate: 1.0, pitch: 1.0, voiceIdentifier: nil)
        VoicePrefsStore.save(original)
        XCTAssertNil(VoicePrefsStore.load().voiceIdentifier)
    }

    func testResetReturnsDefaults() {
        VoicePrefsStore.save(VoicePrefs(wakeWord: "x", rate: 2.0, pitch: 0.5, voiceIdentifier: "y"))
        VoicePrefsStore.save(VoicePrefs())
        let p = VoicePrefsStore.load()
        XCTAssertEqual(p.wakeWord, "hey papercup")
        XCTAssertEqual(p.rate, 1.0)
    }
}
