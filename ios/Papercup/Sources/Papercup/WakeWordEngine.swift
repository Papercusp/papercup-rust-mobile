// SPDX-License-Identifier: GPL-3.0-or-later
//
// Picovoice Porcupine wake-word scaffold for iOS — mirror of Android's
// WakeWordEngine.kt. **Dormant unless an AccessKey is provided.**
//
// Read at runtime from Bundle.main.infoDictionary["PICOVOICE_ACCESS_KEY"]
// (set in Info.plist via the build environment) — empty by default, in
// which case `start()` is a no-op and the rest of the app runs unchanged.
//
// To enable:
//   1. Add the SwiftPM package https://github.com/Picovoice/porcupine
//      (product `Porcupine`) to the Papercup target in project.yml.
//   2. Drop a `hey-papercup.ppn` keyword file into ios/Papercup/Resources
//      and add it to the bundle.
//   3. Set PICOVOICE_ACCESS_KEY in Info.plist (or via xcconfig).
//   4. Replace the `#if canImport(Porcupine)` block below with the
//      PorcupineManager builder call (mirrors Android's keyword path
//      fallback to BuiltInKeyword.JARVIS while a custom .ppn is pending).
//
// Wake word: "hey papercup". On detection the supplied `onDetected`
// callback fires; caller invokes `VoiceManager.start()`.

import Foundation
import os.log

#if canImport(Porcupine)
import Porcupine
#endif

final class WakeWordEngine {
    private let log = OSLog(subsystem: "com.papercuspai.operator.mobile", category: "WakeWord")
    private let onDetected: () -> Void
    private var running: Bool = false

    #if canImport(Porcupine)
    private var manager: PorcupineManager?
    #endif

    init(onDetected: @escaping () -> Void) { self.onDetected = onDetected }

    var isAvailable: Bool { !accessKey.isEmpty }

    func start() {
        guard !running else { return }
        guard isAvailable else {
            os_log(.info, log: log, "wake word disabled — set PICOVOICE_ACCESS_KEY in Info.plist to enable")
            return
        }
        #if canImport(Porcupine)
        do {
            // Mirror Android: prefer custom hey-papercup.ppn from the
            // bundle; fall back to built-in JARVIS while licensing for
            // the custom keyword is pending.
            let custom = Bundle.main.path(forResource: "hey-papercup", ofType: "ppn")
            let builder: PorcupineManager
            if let path = custom {
                builder = try PorcupineManager(
                    accessKey: accessKey,
                    keywordPath: path,
                    sensitivity: 0.6
                ) { [weak self] _ in
                    os_log(.info, log: self?.log ?? .default, "wake word detected")
                    self?.onDetected()
                }
            } else {
                builder = try PorcupineManager(
                    accessKey: accessKey,
                    keyword: Porcupine.BuiltInKeyword.jarvis,
                    sensitivity: 0.6
                ) { [weak self] _ in
                    os_log(.info, log: self?.log ?? .default, "wake word detected (builtin)")
                    self?.onDetected()
                }
            }
            try builder.start()
            manager = builder
            os_log(.info, log: log, "wake word listening")
            running = true
        } catch {
            os_log(.error, log: log, "wake word init failed: %{public}@", String(describing: error))
            manager = nil
        }
        #else
        os_log(.info, log: log, "wake word: Porcupine SwiftPM package not linked — engine inert")
        #endif
    }

    func stop() {
        guard running else { return }
        #if canImport(Porcupine)
        try? manager?.stop()
        manager?.delete()
        manager = nil
        #endif
        running = false
    }

    private var accessKey: String {
        (Bundle.main.object(forInfoDictionaryKey: "PICOVOICE_ACCESS_KEY") as? String) ?? ""
    }
}
