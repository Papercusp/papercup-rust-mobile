// SPDX-License-Identifier: GPL-3.0-or-later
package com.papercuspai.operator.mobile

import org.junit.Assert.*
import org.junit.Test
import uniffi.papercup.AttentionFeed
import uniffi.papercup.AttentionSystemAlert
import uniffi.papercup.FleetActivitySummary

class CompanionFeedTest {
    private val alert = AttentionSystemAlert("system:release-red-gate", "release-red-gate", "high", "Release gate is red", "Changes cannot ship.")

    @Test fun systemAlertOnlyFeedIsVisibleAndCounted() {
        val state = inboxPresentation(AttentionFeed("[]", emptyList(), listOf(alert), 0, 0), 0)
        assertFalse(state.isEmpty)
        assertFalse(state.contentUnavailable)
        assertTrue(state.subtitle.contains("1 system alerts"))
        val row = systemAlertRow(alert)
        assertEquals(alert.title, row.title)
        assertEquals(alert.body, row.body)
        assertEquals("high", row.importance)
        assertTrue(row.needsHuman)
        assertNull(row.harnessSlug)
    }

    @Test fun missingGroupContentCannotClaimInboxZero() {
        val state = inboxPresentation(AttentionFeed("{}", emptyList(), emptyList(), 2, 0), 0)
        assertTrue(state.contentUnavailable)
        assertFalse(state.isEmpty)
    }

    @Test fun genuinelyEmptyFeedCanShowInboxZero() {
        assertTrue(inboxPresentation(AttentionFeed("[]", emptyList(), emptyList(), 0, 0), 0).isEmpty)
    }

    @Test fun unavailableMonitoringIsDistinctFromZeroPresence() {
        assertTrue(fleetAvailabilityText(null).contains("unavailable"))
        assertEquals("0 available · 0 agents", fleetAvailabilityText(FleetActivitySummary(0uL, 0uL, emptyList(), emptyList())))
    }

    @Test fun presenceDoesNotClaimExecutingWork() {
        val text = fleetAvailabilityText(FleetActivitySummary(12uL, 4uL, emptyList(), emptyList()))
        assertEquals("4 available · 12 agents", text)
        assertFalse(text.contains("running", ignoreCase = true))
    }
}
