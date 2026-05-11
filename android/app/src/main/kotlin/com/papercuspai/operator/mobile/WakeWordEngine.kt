// SPDX-License-Identifier: GPL-3.0-or-later
package com.papercuspai.operator.mobile

import ai.picovoice.porcupine.PorcupineManager
import ai.picovoice.porcupine.PorcupineManagerCallback
import android.content.Context
import android.util.Log

/// Picovoice Porcupine wake-word detector.
///
/// **Dormant unless an AccessKey is provided.** Set
/// `PICOVOICE_ACCESS_KEY` in `android/local.properties` (or via the
/// environment at build time); `BuildConfig.PICOVOICE_ACCESS_KEY` is
/// empty by default, in which case `start()` is a no-op and the rest
/// of the app runs unchanged.
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

    fun isAvailable(): Boolean = ACCESS_KEY.isNotBlank()

    fun start() {
        if (!isAvailable()) {
            Log.i(TAG, "wake word disabled — set PICOVOICE_ACCESS_KEY to enable")
            return
        }
        if (manager != null) return
        try {
            val cb = PorcupineManagerCallback { _ ->
                Log.i(TAG, "wake word detected")
                onDetected()
            }
            // Prefer a real hey-papercup.ppn from assets/ once licensing
            // lands; fall back to a built-in keyword until then. The
            // Porcupine SDK reads the asset directly via path.
            val customAssetPath = "hey-papercup.ppn"
            val hasCustom = try {
                context.assets.open(customAssetPath).use { true }
            } catch (_: Throwable) {
                false
            }
            val builder = PorcupineManager.Builder()
                .setAccessKey(ACCESS_KEY)
                .setSensitivity(0.6f)
            if (hasCustom) {
                builder.setKeywordPath(customAssetPath)
                Log.i(TAG, "wake word: using custom hey-papercup.ppn from assets")
            } else {
                builder.setKeyword(ai.picovoice.porcupine.Porcupine.BuiltInKeyword.JARVIS)
                Log.i(TAG, "wake word: hey-papercup.ppn not bundled — falling back to JARVIS")
            }
            manager = builder.build(context, cb)
            manager?.start()
            Log.i(TAG, "wake word listening")
        } catch (t: Throwable) {
            Log.w(TAG, "wake word init failed: ${t.message}")
            manager = null
        }
    }

    fun stop() {
        try { manager?.stop() } catch (_: Throwable) {}
        try { manager?.delete() } catch (_: Throwable) {}
        manager = null
    }

    companion object {
        private const val TAG = "PapercupWake"
        private val ACCESS_KEY: String = BuildConfig.PICOVOICE_ACCESS_KEY

        /// Static check used at the Service-start gate: true only when a
        /// Picovoice AccessKey is baked into BuildConfig. Avoids ever
        /// touching the foreground microphone service when wake-word is
        /// dormant (default — Picovoice key approval pending).
        fun isConfigured(): Boolean = ACCESS_KEY.isNotBlank()
    }
}
