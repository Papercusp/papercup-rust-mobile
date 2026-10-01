// SPDX-License-Identifier: GPL-3.0-or-later
package com.papercuspai.operator.mobile

import uniffi.papercup.AttentionFeed
import uniffi.papercup.AttentionSystemAlert
import uniffi.papercup.FleetActivitySummary

internal data class AttentionRow(
    val title: String,
    val body: String,
    val status: String,
    val importance: String,
    val harnessSlug: String?,
    val needsHuman: Boolean,
)

internal fun systemAlertRow(alert: AttentionSystemAlert) = AttentionRow(
    title = alert.title, body = alert.body, status = "attention",
    importance = if (alert.severity == "high") "high" else "normal",
    harnessSlug = null, needsHuman = true,
)

internal data class InboxPresentation(
    val subtitle: String,
    val isEmpty: Boolean,
    val contentUnavailable: Boolean,
)

internal fun inboxPresentation(feed: AttentionFeed?, visibleAttentionRows: Int): InboxPresentation {
    val workItems = feed?.workItems?.size ?: 0
    val alerts = feed?.systemAlerts?.size ?: 0
    // A server reporting attention with no supported rows must not render inbox zero.
    val unavailable = (feed?.groupCount ?: 0) > 0 && visibleAttentionRows == 0
    return InboxPresentation(
        subtitle = "$visibleAttentionRows needs you · $workItems work items · $alerts system alerts",
        isEmpty = !unavailable && visibleAttentionRows == 0 && workItems == 0 && alerts == 0,
        contentUnavailable = unavailable,
    )
}

internal fun fleetAvailabilityText(activity: FleetActivitySummary?): String =
    if (activity == null) "Fleet activity is unavailable. Refresh to try again."
    else "${activity.availableAgents} available · ${activity.agents} agents"
