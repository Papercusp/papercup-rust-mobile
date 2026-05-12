// SPDX-License-Identifier: GPL-3.0-or-later
package com.papercuspai.operator.mobile

import ai.picovoice.porcupine.PorcupineManager
import ai.picovoice.porcupine.PorcupineManagerCallback
import android.content.Context
import android.util.Log

/// Wake-word detector. Two engines, one flag-driven:
///   - Picovoice Porcupine (default): activated when
///     `BuildConfig.PICOVOICE_ACCESS_KEY` is non-empty
///   - openWakeWord (fallback): activated when `BuildConfig.USE_OWW=true`,
///     even without a Porcupine key. Scaffolded for the case where the
///     Picovoice AccessKey is unavailable. The actual TFLite/ONNX path
///     is a TODO — the build flag exists so the wiring is ready when
///     the OWW model is bundled.
///
/// **Dormant unless one of the two engines is configured.** The default
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
    private var owwActive: Boolean = false

    fun isAvailable(): Boolean = ACCESS_KEY.isNotBlank() || USE_OWW

    fun start() {
        if (USE_OWW) {
            startOww()
            return
        }
        if (ACCESS_KEY.isBlank()) {
            Log.i(TAG, "wake word disabled — set PICOVOICE_ACCESS_KEY or PAPERCUP_USE_OWW=true to enable")
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
        if (owwActive) stopOww()
    }

    /// openWakeWord backend scaffold. Flag-flipped via
    /// PAPERCUP_USE_OWW=true. Real implementation will bundle a TFLite
    /// `.onnx` model in assets/ and read 16kHz PCM frames via
    /// AudioRecord, feeding them to the OWW inference path. For now,
    /// the start hook just logs intent — keeps the surface area in
    /// place so wiring the actual model is a focused PR rather than
    /// a cross-cutting change.
    private fun startOww() {
        if (owwActive) return
        Log.w(TAG, "openWakeWord path enabled but model not yet bundled — no-op")
        // TODO(wake-word): bundle openwakeword/hey_papercup.onnx in
        // assets/, spin up AudioRecord at 16kHz mono PCM_16, push
        // frames into the OWW inference pipeline, call onDetected()
        // on a score > threshold.
        owwActive = true
    }

    private fun stopOww() {
        owwActive = false
    }

    companion object {
        private const val TAG = "PapercupWake"
        private val ACCESS_KEY: String = BuildConfig.PICOVOICE_ACCESS_KEY
        private val USE_OWW: Boolean = BuildConfig.USE_OWW

        /// Static check used at the Service-start gate: true when
        /// either Picovoice has an AccessKey OR the openWakeWord
        /// fallback is enabled at build time. Avoids ever touching
        /// the foreground microphone service when wake-word is
        /// dormant (default — both engines disabled).
        fun isConfigured(): Boolean = ACCESS_KEY.isNotBlank() || USE_OWW
    }
}
