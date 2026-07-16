// SPDX-License-Identifier: GPL-3.0-or-later
package com.papercuspai.operator.mobile

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import uniffi.papercup.ApiException

/**
 * WI-4966 regression contract: transport/API failures surface as copy a
 * human can act on — never raw UniFFI/reqwest/serde text. Pins the
 * error-recovery-ux criterion of the mobile-app-release-readiness rubric
 * (graded DEGRADED on scorecard EI-12506 for exactly this leak).
 */
class HumanErrorTest {
    private val leakMarkers = listOf(
        "reqwest", "uniffi", "detail=", "status=", "Exception", "kotlinx.",
        "java.net", "::", "url (",
    )

    private fun assertNoLeaks(msg: String) {
        for (leak in leakMarkers) {
            assertFalse("'$leak' leaked into user copy: $msg", msg.contains(leak, ignoreCase = true))
        }
    }

    @Test
    fun rawReqwestNetworkErrorBecomesReachabilityGuidance() {
        val msg = HumanError.describe(
            ApiException.Network(
                "error sending request for url (http://10.0.2.2:3055/api/harness): client error (Connect)",
            ),
            "Loading harnesses",
        )
        assertTrue(msg, msg.startsWith("Loading harnesses failed"))
        assertTrue(msg, msg.contains("can't reach", ignoreCase = true))
        assertTrue("must give a recovery step: $msg", msg.contains("retry", ignoreCase = true))
        assertNoLeaks(msg)
    }

    @Test
    fun timeoutBecomesRetryGuidance() {
        val typed = HumanError.describe(java.net.SocketTimeoutException("timeout"), "Sending the message")
        assertTrue(typed, typed.contains("took too long"))
        val text = HumanError.describe(ApiException.Network("operation timed out"), "Sending the message")
        assertTrue(text, text.contains("took too long"))
        assertNoLeaks(typed); assertNoLeaks(text)
    }

    @Test
    fun serverErrorsMapByStatus() {
        val five = HumanError.describe(ApiException.Server(500u, "Internal Server Error"), "Loading plans")
        assertTrue(five, five.contains("internal error", ignoreCase = true))
        val busy = HumanError.describe(ApiException.Server(429u, "Too Many Requests"), "Loading plans")
        assertTrue(busy, busy.contains("busy", ignoreCase = true))
        val auth = HumanError.describe(ApiException.Server(401u, "Unauthorized"), "Loading plans")
        assertTrue(auth, auth.contains("Re-pair"))
        assertNoLeaks(five); assertNoLeaks(busy); assertNoLeaks(auth)
    }

    @Test
    fun unauthorizedPointsAtRePairing() {
        val msg = HumanError.describe(ApiException.Unauthorized(), "Loading the inbox")
        assertTrue(msg, msg.contains("Re-pair"))
        assertTrue(msg, msg.contains("Settings"))
        assertNoLeaks(msg)
    }

    @Test
    fun decodeFailurePointsAtVersionSkew() {
        val msg = HumanError.describe(ApiException.Decode("invalid type: map, expected a string at line 1"), "Loading activity")
        assertTrue(msg, msg.contains("app version", ignoreCase = true))
        assertNoLeaks(msg)
    }

    @Test
    fun unknownThrowableNeverLeaksItsInternals() {
        val msg = HumanError.describe(
            RuntimeException("kotlinx.serialization.json.internal.JsonDecodingException: boom at \$.data[3]"),
            "Updating the item",
        )
        assertTrue(msg, msg.startsWith("Updating the item failed"))
        assertFalse(msg, msg.contains("JsonDecodingException"))
        assertFalse(msg, msg.contains("$.data"))
    }

    @Test
    fun everyShapeStartsWithTheAttemptedAction() {
        val shapes = listOf<Throwable>(
            ApiException.Network("connection refused"),
            ApiException.Server(503u, "unavailable"),
            ApiException.Unauthorized(),
            ApiException.Decode("x"),
            java.net.UnknownHostException("papercup.local"),
            javax.net.ssl.SSLException("handshake failed"),
            RuntimeException(),
        )
        for (t in shapes) {
            val msg = HumanError.describe(t, "Pairing")
            assertTrue("must start with the action: $msg", msg.startsWith("Pairing failed"))
            assertNoLeaks(msg)
        }
    }
}
