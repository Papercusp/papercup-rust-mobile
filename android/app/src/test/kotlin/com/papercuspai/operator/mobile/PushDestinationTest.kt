// SPDX-License-Identifier: GPL-3.0-or-later
package com.papercuspai.operator.mobile

import org.junit.Assert.assertEquals
import org.junit.Test

class PushDestinationTest {
    @Test
    fun harnessAttentionKeepsItsDetailDestination() {
        for (kind in listOf("intervention", "needs-human", "plan-review")) {
            assertEquals(PushDestination.HarnessDetail("pot"), resolvePushDestination(kind, "pot"))
        }
    }

    @Test
    fun smokeFailureOpensItsRunLog() {
        assertEquals(PushDestination.RunLog("pot"), resolvePushDestination("smoke-fail", "pot"))
        assertEquals(PushDestination.Inbox, resolvePushDestination("smoke-fail", null))
    }

    @Test
    fun operatorSuggestionOpensOperator() {
        assertEquals(PushDestination.Operator, resolvePushDestination("operator-suggestion", null))
    }

    @Test
    fun missingHarnessFallsBackToInbox() {
        for (kind in listOf("intervention", "needs-human", "plan-review", "smoke-fail")) {
            assertEquals(PushDestination.Inbox, resolvePushDestination(kind, " \t "))
        }
    }

    @Test
    fun unknownAndEmptyPayloadsOpenInbox() {
        assertEquals(PushDestination.Inbox, resolvePushDestination("mystery", "pot"))
        assertEquals(PushDestination.Inbox, resolvePushDestination(null, null))
    }

    @Test
    fun legacySlugOnlyPushPreservesDeepLink() {
        assertEquals(PushDestination.HarnessDetail("pot"), resolvePushDestination(null, " pot "))
    }
}
