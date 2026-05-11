// SPDX-License-Identifier: GPL-3.0-or-later
//
// Phase 8 — iOS implementation of the UDL `BiometricPrompt` callback.
// Wraps LocalAuthentication's LAContext. Synchronous from the caller's
// perspective (UDL declared `prompt` non-async because the platform
// APIs need a callback-into-completion-handler bridge that's cleaner
// to dispatch_semaphore than to expose async-await across UniFFI).

import Foundation
import LocalAuthentication
import os.log

private let log = OSLog(subsystem: "com.papercuspai.operator.mobile", category: "Biometric")

final class BiometricGate: BiometricPrompt {
    func prompt(reason: String) -> BiometricResult {
        let ctx = LAContext()
        var err: NSError?
        let policy: LAPolicy = .deviceOwnerAuthentication
        guard ctx.canEvaluatePolicy(policy, error: &err) else {
            let why = err?.localizedDescription ?? "biometric unavailable"
            os_log(.info, log: log, "biometric: unavailable — %{public}@", why)
            return .unavailable(reason: why)
        }
        let sem = DispatchSemaphore(value: 0)
        var outcome: BiometricResult = .denied
        ctx.evaluatePolicy(policy, localizedReason: reason) { success, evalErr in
            outcome = success ? .approved : .denied
            if !success {
                os_log(.info, log: log, "biometric: denied — %{public}@",
                       evalErr?.localizedDescription ?? "user cancelled")
            }
            sem.signal()
        }
        sem.wait()
        return outcome
    }
}
