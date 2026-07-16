// SPDX-License-Identifier: GPL-3.0-or-later
package com.papercuspai.operator.mobile

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * WI-4967 regression contract: a runtime mic-permission denial must surface
 * as a user-comprehensible MicPermission failure — routed to the banner with
 * its Open-Settings action — never a silent no-op and never raw internals.
 *
 * Rubric: mobile-app-release-readiness → permissions-ux. The 2026-07-15
 * scorecard (EI-12506) graded this DEGRADED because the first denial
 * silently returned to "Voice: Listen" and a permanent denial no-oped with
 * no Settings guidance. These tests pin the fixed copy.
 */
class VoiceMicDenialTest {
    @Test
    fun firstDenialProducesActionableMicPermissionFailure() {
        val failed = VoiceManager.micDenialFailure(permanentlyDenied = false)
        assertEquals(VoiceManager.FailureKind.MicPermission, failed.kind)
        assertTrue(
            "copy must name the microphone: ${failed.message}",
            failed.message.contains("microphone", ignoreCase = true),
        )
        // Tells the user HOW to recover (re-tap and allow).
        assertTrue(
            "copy must include the recovery action: ${failed.message}",
            failed.message.contains("Allow"),
        )
    }

    @Test
    fun permanentDenialPointsAtSettings() {
        val failed = VoiceManager.micDenialFailure(permanentlyDenied = true)
        assertEquals(VoiceManager.FailureKind.MicPermission, failed.kind)
        // The banner's kind-specific action opens app Settings; the copy must
        // point there too, since the system prompt will never show again.
        assertTrue(
            "permanent-denial copy must point at Settings: ${failed.message}",
            failed.message.contains("Settings"),
        )
    }

    @Test
    fun denialCopyNeverLeaksInternals() {
        for (permanent in listOf(true, false)) {
            val msg = VoiceManager.micDenialFailure(permanent).message
            for (leak in listOf("Exception", "uniffi", "reqwest", "java.", "android.permission")) {
                assertFalse("'$leak' leaked into user copy: $msg", msg.contains(leak, ignoreCase = true))
            }
        }
    }
}
