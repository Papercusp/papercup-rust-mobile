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

    @Test fun badgeCountsSystemAlertsWithoutNotificationHistory() {
        assertEquals(1, inboxBadgeCount(AttentionFeed("[]", emptyList(), listOf(alert), 0, 0)))
        assertEquals(0, inboxBadgeCount(AttentionFeed("[]", emptyList(), emptyList(), 0, 0)))
        assertNull(inboxBadgeCount(null))
    }

    @Test fun badgeCountsItemsRatherThanGroupsAndSupportsTheEnvelope() {
        val groups = """[{"harnessSlug":"test-pot","items":[{"title":"Approve","needsHuman":true},{"title":"Reply"}]}]"""
        val parsed = parseAttentionRows("""{"groups":$groups}""")
        assertFalse(parsed.contentUnavailable)
        assertEquals(listOf("Approve", "Reply"), parsed.rows.map { it.title })
        assertEquals("test-pot", parsed.rows.first().harnessSlug)
        assertEquals(3, inboxBadgeCount(AttentionFeed(groups, emptyList(), listOf(alert), 1, 0)))
    }

    @Test fun aMalformedRowCannotBeHiddenByOtherVisibleRows() {
        val groups = """[{"items":[{"title":"Visible"},{"body":"Missing title"}]}]"""
        val feed = AttentionFeed(groups, emptyList(), emptyList(), 1, 0)
        val parsed = decodeAttentionFeed(feed)
        assertEquals(1, parsed.rows.size)
        assertTrue(parsed.contentUnavailable)
        assertTrue(inboxPresentation(feed, parsed.rows.size, parsed.contentUnavailable).contentUnavailable)
        assertNull(inboxBadgeCount(feed))
    }

    @Test fun malformedAndMissingGroupPayloadsAreUnavailableRatherThanEmpty() {
        listOf("", "not-json", "{}", "[null]", "[{\"items\":null}]",
            "[{\"items\":[{\"title\":7}]}]").forEach { groups ->
            assertTrue(groups, parseAttentionRows(groups).contentUnavailable)
            assertNull(groups, inboxBadgeCount(AttentionFeed(groups, emptyList(), emptyList(), 0, 0)))
        }
    }

    @Test fun missingRowsOrMismatchedCountsDoNotClaimZero() {
        assertNull(inboxBadgeCount(AttentionFeed("[]", emptyList(), emptyList(), 1, 0)))
        assertNull(inboxBadgeCount(AttentionFeed("[]", emptyList(), emptyList(), 0, 1)))
        assertNull(inboxBadgeCount(AttentionFeed("[{\"items\":[]}]", emptyList(), emptyList(), 1, 0)))
    }
}
