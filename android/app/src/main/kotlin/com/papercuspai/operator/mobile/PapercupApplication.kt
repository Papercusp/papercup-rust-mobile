// SPDX-License-Identifier: GPL-3.0-or-later
package com.papercuspai.operator.mobile

import android.app.Application
import com.sun.jna.CallbackThreadInitializer
import com.sun.jna.Native
import uniffi.papercup.uniffiRustFutureContinuationCallbackImpl

class PapercupApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        // UniFFI resumes Kotlin continuations inline on Rust worker threads.
        // A resumed continuation can immediately poll another Rust future.
        // JNA's default per-callback detach also runs for that nested callback,
        // which ART aborts while the outer Java frame is still on the stack.
        // Use JNA's supported callback lifetime policy before any UI/service
        // starts. Its pthread TLS destructor detaches when the worker exits.
        Native.setCallbackThreadInitializer(
            uniffiRustFutureContinuationCallbackImpl,
            CallbackThreadInitializer(true, false),
        )
    }
}
