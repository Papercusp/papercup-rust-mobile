// SPDX-License-Identifier: GPL-3.0-or-later
package com.papercuspai.operator.mobile

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test
import uniffi.papercup.ApiException
import uniffi.papercup.WorkspaceSwitchResult

class WorkspaceSwitchTest {
    @Test
    fun identitySurvivesTokenRotationWithoutAppearingInDiagnostics() = runBlocking {
        val paired = original.copy(noiseSeed = "private-seed-canary", noiseKey = "machine-pin")
        val switched = paired.switchWorkspace("second", { WorkspaceSwitchResult("new-token", it) }, {})
        assertEquals(paired.noiseSeed, switched.noiseSeed)
        assertEquals(paired.noiseKey, switched.noiseKey)
        assertFalse(switched.toString().contains("private-seed-canary"))
        assertFalse(switched.toString().contains("new-token"))
    }

    private val original = DeviceCredentials(
        server = "https://operator.example",
        deviceToken = "old-token",
        deviceId = "phone-1",
        workspaceId = "first",
        meshUrl = "https://mesh.example",
        defguardEnrollmentUrl = "https://enroll.example",
    )

    @Test
    fun successfulSwitchPersistsTokenAndWorkspaceBeforeReturning() = runBlocking {
        var active = original
        val events = mutableListOf<String>()
        val fresh = active.switchWorkspace(
            "second",
            request = { target ->
                assertEquals("second", target)
                assertEquals("old-token", active.deviceToken)
                events += "request"
                WorkspaceSwitchResult("new-token", target)
            },
            onSwitched = {
                events += "persist"
                active = it
            },
        )
        assertEquals(listOf("request", "persist"), events)
        assertEquals(original.copy(deviceToken = "new-token", workspaceId = "second"), active)
        assertEquals(active, fresh)
    }

    @Test
    fun subsequentSwitchUsesTheReplacementCredentials() = runBlocking {
        var active = original
        for ((target, token) in listOf("second" to "new-token", "third" to "latest-token")) {
            val expectedPreviousToken = if (target == "second") "old-token" else "new-token"
            active.switchWorkspace(
                target,
                request = {
                    assertEquals(expectedPreviousToken, active.deviceToken)
                    WorkspaceSwitchResult(token, it)
                },
                onSwitched = { active = it },
            )
        }
        assertEquals("latest-token", active.deviceToken)
        assertEquals("third", active.workspaceId)
    }

    @Test
    fun revokedOrExpiredSessionPreservesExistingCredentials() = runBlocking {
        val rejection = ApiException.Unauthorized()
        var persisted = false
        try {
            original.switchWorkspace("second", { throw rejection }, { persisted = true })
            fail("Rejected switch must fail")
        } catch (failure: ApiException.Unauthorized) {
            assertSame(rejection, failure)
        }
        assertFalse(persisted)
    }

    @Test
    fun cancelledBiometricOrRequestDoesNotPersist() = runBlocking {
        val cancellation = CancellationException("cancelled")
        var persisted = false
        try {
            original.switchWorkspace("second", { throw cancellation }, { persisted = true })
            fail("Cancelled switch must propagate")
        } catch (failure: CancellationException) {
            assertSame(cancellation, failure)
        }
        assertFalse(persisted)
    }

    @Test
    fun mismatchedWorkspaceOrEmptyTokenCannotReplaceCredentials() = runBlocking {
        for (response in listOf(
            WorkspaceSwitchResult("new-token", "unexpected"),
            WorkspaceSwitchResult("", "second"),
            WorkspaceSwitchResult("   ", "second"),
        )) {
            var persisted = false
            try {
                original.switchWorkspace("second", { response }, { persisted = true })
                fail("Invalid switch response must fail")
            } catch (_: ApiException.Decode) {
                // A response contract failure must leave the old pairing intact.
            }
            assertFalse(persisted)
        }
    }

    @Test
    fun storageFailureIsNotReportedAsSuccessfulSwitch() = runBlocking {
        val storageFailure = IllegalStateException("storage unavailable")
        try {
            original.switchWorkspace(
                "second",
                { WorkspaceSwitchResult("new-token", it) },
                { throw storageFailure },
            )
            fail("Persistence failure must propagate")
        } catch (failure: IllegalStateException) {
            assertSame(storageFailure, failure)
        }
    }
}
