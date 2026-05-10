// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

struct VoicePrefs: Equatable {
    var wakeWord: String = "hey papercup"
    var rate: Float = 1.0
    var pitch: Float = 1.0
    var voiceIdentifier: String? = nil
}

enum VoicePrefsStore {
    private static let key = "papercup.voicePrefs.v1"

    static func load() -> VoicePrefs {
        let d = UserDefaults.standard
        guard d.object(forKey: key) != nil,
              let raw = d.dictionary(forKey: key) else { return VoicePrefs() }
        return VoicePrefs(
            wakeWord: raw["wakeWord"] as? String ?? "hey papercup",
            rate: (raw["rate"] as? NSNumber)?.floatValue ?? 1.0,
            pitch: (raw["pitch"] as? NSNumber)?.floatValue ?? 1.0,
            voiceIdentifier: raw["voiceIdentifier"] as? String
        )
    }

    static func save(_ p: VoicePrefs) {
        var raw: [String: Any] = [
            "wakeWord": p.wakeWord,
            "rate": p.rate,
            "pitch": p.pitch,
        ]
        if let v = p.voiceIdentifier { raw["voiceIdentifier"] = v }
        UserDefaults.standard.set(raw, forKey: key)
    }
}
