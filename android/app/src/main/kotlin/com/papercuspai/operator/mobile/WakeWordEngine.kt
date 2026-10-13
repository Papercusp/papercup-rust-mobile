// SPDX-License-Identifier: GPL-3.0-or-later
package com.papercuspai.operator.mobile

import ai.picovoice.porcupine.PorcupineManager
import ai.picovoice.porcupine.PorcupineManagerCallback
import android.content.Context
import android.util.Log

/// Wake-word detector using the implemented Picovoice Porcupine backend.
/// A nonblank `BuildConfig.PICOVOICE_ACCESS_KEY` enables the default backend.
/// `BuildConfig.USE_OWW` selects an unimplemented backend, so it is unavailable
/// and must never advertise detection or start a microphone service.
///
/// **Dormant unless the implemented backend is configured.** The default
/// build emits a no-op start() so the app runs without any wake-word
/// service touching the foreground microphone.
///
/// Wake word: "hey papercup" (custom Porcupine `.ppn` keyword).
/// `keywordPath` is the asset path the engine streams from. While
/// approval / a custom-keyword build is pending, the engine falls back
/// to one of Porcupine's built-in keywords if `KEYWORD_PATH` resolves
/// to nothing on disk.
///
/// On detection: invokes the supplied `onDetected` callback. Caller is
/// responsible for what happens next (typically `VoiceManager.start()`).
class WakeWordEngine(
    private val context: Context,
    private val onDetected: () -> Unit,
) {
    private var manager: PorcupineManager? = null

    fun isAvailable(): Boolean = isConfigured()

    fun start(): Boolean {
        if (!isAvailable()) {
            Log.i(TAG, "wake word unavailable — Porcupine requires a key; openWakeWord detection is not implemented")
            return false
        }
        if (manager != null) return true
        try {
            val cb = PorcupineManagerCallback { _ ->
                Log.i(TAG, "wake word detected")
                onDetected()
            }
            // Prefer a real hey-papercup.ppn from assets/ once licensing
            // lands; fall back to a built-in keyword until then. The
            // Porcupine SDK reads the asset directly via path.
            val hasCustom = hasCustomKeyword(context)
            val builder = PorcupineManager.Builder()
                .setAccessKey(ACCESS_KEY)
                .setSensitivity(0.6f)
            if (hasCustom) {
                builder.setKeywordPath(CUSTOM_ASSET_PATH)
                Log.i(TAG, "wake word: using custom hey-papercup.ppn from assets")
            } else {
                builder.setKeyword(ai.picovoice.porcupine.Porcupine.BuiltInKeyword.JARVIS)
                Log.i(TAG, "wake word: hey-papercup.ppn not bundled — falling back to JARVIS")
            }
            manager = builder.build(context, cb)
            manager?.start()
            Log.i(TAG, "wake word listening")
            return true
        } catch (t: Throwable) {
            Log.w(TAG, "wake word init failed: ${t.message}")
            stop()
            return false
        }
    }

    fun stop() {
        try { manager?.stop() } catch (_: Throwable) {}
        try { manager?.delete() } catch (_: Throwable) {}
        manager = null
    }

    companion object {
        private const val TAG = "PapercupWake"
        private const val CUSTOM_ASSET_PATH = "hey-papercup.ppn"
        private val ACCESS_KEY: String = BuildConfig.PICOVOICE_ACCESS_KEY
        private val USE_OWW: Boolean = BuildConfig.USE_OWW

        /// Shared by the engine and foreground-service gates. A build flag
        /// alone cannot establish that the selected detector is implemented.
        fun isConfigured(): Boolean = wakeWordEngineConfigured(ACCESS_KEY, USE_OWW)

        fun configuredKeyword(context: Context): String? =
            wakeWordKeyword(isConfigured(), hasCustomKeyword(context))

        private fun hasCustomKeyword(context: Context): Boolean = try {
            context.assets.open(CUSTOM_ASSET_PATH).use { true }
        } catch (_: java.io.IOException) {
            false
        }
    }
}
