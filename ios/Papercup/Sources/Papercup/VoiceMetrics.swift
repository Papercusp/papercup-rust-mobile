// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import PapercupCore

/// Rolling sample buffer for the Performance HUD on Settings → Voice.
/// We track first-word latency (time from `start()` until the first
/// `onAgentResponse`) and session-length distributions. The HUD shows
/// P50/P95 over the last `sampleCap` sessions; raw samples persist
/// across app restarts so users can spot regressions between builds.
enum VoiceMetrics {
    /// Keep the last N samples. 50 = enough for P50/P95 stability,
    /// small enough that the UserDefaults write stays under a couple KB.
    private static let sampleCap = 50
    private static let keyFirstWord = "papercup.voiceMetrics.firstWordMs"
    private static let keySessionLen = "papercup.voiceMetrics.sessionLenMs"

    struct Stats {
        let count: Int
        let p50: Int
        let p95: Int
        let max: Int
    }

    static func recordFirstWordMs(_ ms: Int) {
        guard ms >= 0, ms <= 60_000 else { return }
        append(key: keyFirstWord, value: ms)
    }

    static func recordSessionLenMs(_ ms: Int) {
        guard ms >= 0, ms <= 60 * 60_000 else { return }
        append(key: keySessionLen, value: ms)
    }

    static func firstWordStats() -> Stats { readStats(key: keyFirstWord) }
    static func sessionLenStats() -> Stats { readStats(key: keySessionLen) }

    static func reset() {
        UserDefaults.standard.removeObject(forKey: keyFirstWord)
        UserDefaults.standard.removeObject(forKey: keySessionLen)
    }

    private static func append(key: String, value: Int) {
        var arr = (UserDefaults.standard.array(forKey: key) as? [Int]) ?? []
        arr.append(value)
        if arr.count > sampleCap { arr.removeFirst(arr.count - sampleCap) }
        UserDefaults.standard.set(arr, forKey: key)
    }

    private static func readStats(key: String) -> Stats {
        let arr = (UserDefaults.standard.array(forKey: key) as? [Int]) ?? []
        if arr.isEmpty { return Stats(count: 0, p50: 0, p95: 0, max: 0) }
        let sorted = arr.sorted()
        func pct(_ p: Double) -> Int {
            let idx = max(0, min(sorted.count - 1, Int(Double(sorted.count - 1) * p)))
            return sorted[idx]
        }
        return Stats(count: sorted.count, p50: pct(0.5), p95: pct(0.95), max: sorted.last ?? 0)
    }
}
