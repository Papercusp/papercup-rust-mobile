// SPDX-License-Identifier: GPL-3.0-or-later
package com.papercuspai.operator.mobile

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlin.coroutines.Continuation
import kotlin.coroutines.resume
import kotlin.coroutines.suspendCoroutine
import org.junit.Assert.*
import org.junit.Test

class CloudVoiceStartupTest {
    @Test
    fun sdkFailureReleasesAttemptAndPermitsRetry() = runBlocking {
        var active = true
        var releases = 0
        var failure: Throwable? = null
        var session: String? = null
        val unavailable = IllegalStateException("SDK startup unavailable")
        runCloudVoiceStartup<String>(
            isCurrent = { active }, start = { throw unavailable }, accept = { session = it },
            closeStale = { fail("No session was created") }, onFailure = { failure = it },
            release = { active = false; releases++ },
        )
        assertSame(unavailable, failure)
        assertFalse(active)
        assertEquals(1, releases)
        assertNull(session)
        // The same boundary can now start a new attempt, without an app restart.
        active = true
        runCloudVoiceStartup(
            isCurrent = { active }, start = { "retry-session" }, accept = { session = it },
            closeStale = { fail("Retry is current") }, onFailure = { fail(it.message) },
            release = { active = false; releases++ },
        )
        assertEquals("retry-session", session)
        assertTrue(active)
        assertEquals(1, releases)
    }

    @Test
    fun cancellationReleasesWithoutReportingSdkFailure() = runBlocking {
        var active = true
        var failures = 0
        val cancelled = CancellationException("user stopped")
        try {
            runCloudVoiceStartup<String>(
                isCurrent = { active }, start = { throw cancelled }, accept = { fail("cancelled") },
                closeStale = { fail("No session") }, onFailure = { failures++ },
                release = { active = false },
            )
            fail("Cancellation must propagate")
        } catch (actual: CancellationException) { assertSame(cancelled, actual) }
        assertFalse(active)
        assertEquals(0, failures)
    }

    @Test
    fun stoppedOrRevokedAttemptClosesLateSdkSession() = runBlocking {
        var current = true
        val closed = mutableListOf<String>()
        runCloudVoiceStartup(
            isCurrent = { current }, start = { current = false; "late-session" },
            accept = { fail("Stopped attempt must not retain a microphone session") },
            closeStale = { closed.add(it) }, onFailure = { fail(it.message) },
            release = { fail("Already released") },
        )
        assertEquals(listOf("late-session"), closed)
    }

    @Test
    fun staleFailureCannotChangeOrReleaseReplacementAttempt() = runBlocking {
        runCloudVoiceStartup<String>(
            isCurrent = { false }, start = { throw IllegalStateException("old attempt") },
            accept = { fail("No session") }, closeStale = { fail("No session") },
            onFailure = { fail("Must not replace current UI state") },
            release = { fail("Must not cancel the new scope") },
        )
    }

    @Test
    fun cancellationCannotInterruptLateSessionCleanup() = runBlocking {
        var current = true
        var pending: Continuation<String>? = null
        var closed = false
        val startup = launch(start = CoroutineStart.UNDISPATCHED) {
            runCloudVoiceStartup(
                isCurrent = { current },
                start = { suspendCoroutine<String> { pending = it } },
                accept = { fail("Stopped attempt") },
                closeStale = { delay(1); closed = true },
                onFailure = { fail("Cancelled attempt must not change UI") },
                release = { fail("Already released") },
            )
        }
        current = false
        startup.cancel()
        pending!!.resume("late-session")
        startup.join()
        assertTrue(closed)
    }

    @Test
    fun failurePresentationStillReleasesIfItThrows() = runBlocking {
        var released = false
        val presentationFailure = IllegalStateException("presentation")
        try {
            runCloudVoiceStartup<String>(
                isCurrent = { true }, start = { throw IllegalStateException("SDK") },
                accept = {}, closeStale = {}, onFailure = { throw presentationFailure },
                release = { released = true },
            )
            fail("Presentation failure must propagate")
        } catch (actual: IllegalStateException) { assertSame(presentationFailure, actual) }
        assertTrue(released)
    }
}
