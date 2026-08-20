// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import PapercupCore

enum VoiceMode: String, CaseIterable, Equatable {
    case continuous = "continuous"
    case hybrid = "hybrid"
    case singleUtterance = "single-utterance"

    var label: String {
        switch self {
        case .continuous: return "Continuous"
        case .hybrid: return "Hybrid"
        case .singleUtterance: return "Single utterance"
        }
    }

    var blurb: String {
        switch self {
        case .continuous:
            return "Hands-free conversation, ChatGPT-style. Session stays open until you tap to end or it idles out."
        case .hybrid:
            return "Continuous, but the agent hangs up after definitive answers (\"marked done\"). Best of both."
        case .singleUtterance:
            return "One question, one answer, then disconnect. Cheapest. Best on cellular."
        }
    }
}

/// Device-local voice preferences. Distinct from the workspace-shared
/// prefs in `operator_voice_prefs` (PG) — these stay on the device and
/// get passed to `/api/device/voice-session-init` as query params so
/// the server can resolve mode-dependent behavior without overwriting
/// another device's choice.
struct VoicePrefs: Equatable {
    var wakeWord: String = "hey papercup"
    var rate: Float = 1.0
    var pitch: Float = 1.0
    var voiceIdentifier: String? = nil
    /// Conversation flow. Default continuous = ChatGPT-style.
    var voiceMode: VoiceMode = .continuous
    /// Idle minutes before auto-disconnect on user silence. 0 = use
    /// server's workspace default. Server clamps to ≤1 in single-utterance
    /// mode regardless of this value.
    var idleTimeoutMin: Int = 0
    /// Hard session ceiling. 0 = use server's workspace default.
    var sessionMaxMin: Int = 0
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
            voiceIdentifier: raw["voiceIdentifier"] as? String,
            voiceMode: VoiceMode(rawValue: raw["voiceMode"] as? String ?? "") ?? .continuous,
            idleTimeoutMin: (raw["idleTimeoutMin"] as? NSNumber)?.intValue ?? 0,
            sessionMaxMin: (raw["sessionMaxMin"] as? NSNumber)?.intValue ?? 0
        )
    }

    static func save(_ p: VoicePrefs) {
        var raw: [String: Any] = [
            "wakeWord": p.wakeWord,
            "rate": p.rate,
            "pitch": p.pitch,
            "voiceMode": p.voiceMode.rawValue,
            "idleTimeoutMin": p.idleTimeoutMin,
            "sessionMaxMin": p.sessionMaxMin,
        ]
        if let v = p.voiceIdentifier { raw["voiceIdentifier"] = v }
        UserDefaults.standard.set(raw, forKey: key)
    }
}
