// SPDX-License-Identifier: GPL-3.0-or-later
package com.papercuspai.operator.mobile

import android.content.Context
import android.util.Log
import androidx.biometric.BiometricManager
import androidx.biometric.BiometricPrompt
import androidx.fragment.app.FragmentActivity
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.runBlocking
import uniffi.papercup.BiometricPrompt as UniffiBiometricPrompt
import uniffi.papercup.BiometricResult

/// Phase 8 — Android implementation of the UDL `BiometricPrompt`
/// callback. Wraps androidx.biometric.BiometricPrompt; calls block
/// the calling thread (Rust side runs on a tokio worker, not main)
/// while the prompt UI animates on the FragmentActivity.
///
/// Set on the OperatorClient at app startup once the FragmentActivity
/// is ready:
///   client.setBiometricPrompt(BiometricGate(activity))
class BiometricGate(
    private val activity: FragmentActivity,
) : UniffiBiometricPrompt {

    override fun `prompt`(reason: String): BiometricResult {
        // BiometricManager check must run on main; the prompt itself
        // posts to main via Activity.runOnUiThread inside authenticate().
        val mgr = BiometricManager.from(activity)
        val ok = mgr.canAuthenticate(
            BiometricManager.Authenticators.BIOMETRIC_WEAK or
                BiometricManager.Authenticators.DEVICE_CREDENTIAL,
        )
        if (ok != BiometricManager.BIOMETRIC_SUCCESS) {
            val why = when (ok) {
                BiometricManager.BIOMETRIC_ERROR_NO_HARDWARE -> "no biometric hardware"
                BiometricManager.BIOMETRIC_ERROR_HW_UNAVAILABLE -> "biometric hardware unavailable"
                BiometricManager.BIOMETRIC_ERROR_NONE_ENROLLED -> "no biometric enrolled"
                BiometricManager.BIOMETRIC_ERROR_SECURITY_UPDATE_REQUIRED -> "security update required"
                else -> "biometric unavailable ($ok)"
            }
            Log.i(TAG, "biometric: unavailable — $why")
            return BiometricResult.Unavailable(why)
        }

        val deferred = CompletableDeferred<BiometricResult>()
        val info = BiometricPrompt.PromptInfo.Builder()
            .setTitle(activity.getString(R.string.biometric_title))
            .setSubtitle(reason)
            .setAllowedAuthenticators(
                BiometricManager.Authenticators.BIOMETRIC_WEAK or
                    BiometricManager.Authenticators.DEVICE_CREDENTIAL,
            )
            .build()

        activity.runOnUiThread {
            val callback = object : BiometricPrompt.AuthenticationCallback() {
                override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) {
                    Log.i(TAG, "biometric: approved")
                    deferred.complete(BiometricResult.Approved)
                }
                override fun onAuthenticationFailed() {
                    // Single failed attempt — system may give the user
                    // another shot before calling onAuthenticationError.
                    Log.i(TAG, "biometric: attempt failed")
                }
                override fun onAuthenticationError(errorCode: Int, errString: CharSequence) {
                    Log.i(TAG, "biometric: error $errorCode $errString")
                    deferred.complete(BiometricResult.Denied)
                }
            }
            val executor = androidx.core.content.ContextCompat.getMainExecutor(activity)
            BiometricPrompt(activity, executor, callback).authenticate(info)
        }

        // Block the (non-main) calling thread until the user resolves.
        // Acceptable here because Rust core invokes this from a tokio
        // worker, never from the main thread.
        return runBlocking { deferred.await() }
    }

    private companion object {
        const val TAG = "PapercupBiometric"
    }
}
