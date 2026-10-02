// SPDX-License-Identifier: GPL-3.0-or-later
package com.papercuspai.operator.mobile

import uniffi.papercup.AttentionFeed
import uniffi.papercup.AttentionSystemAlert
import uniffi.papercup.FleetActivitySummary
import org.json.JSONArray
import org.json.JSONObject

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

internal data class ParsedAttention(
    val rows: List<AttentionRow>,
    val groupCount: Long,
    val contentUnavailable: Boolean,
)

internal fun parseAttentionRows(json: String?): ParsedAttention {
    if (json.isNullOrBlank()) return ParsedAttention(emptyList(), 0, true)
    return try {
        val trimmed = json.trim()
        val groups = if (trimmed.startsWith("[")) JSONArray(trimmed)
            else JSONObject(trimmed).getJSONArray("groups")
        val rows = mutableListOf<AttentionRow>()
        var unavailable = false
        for (g in 0 until groups.length()) {
            try {
                val group = groups.getJSONObject(g)
                val items = group.getJSONArray("items")
                for (i in 0 until items.length()) {
                    try {
                        val item = items.getJSONObject(i)
                        val title = (item.get("title") as? String)?.trim()
                        require(!title.isNullOrEmpty())
                        val slug = item.optString("harnessSlug", "")
                            .ifBlank { group.optString("harnessSlug", "") }.trim()
                        rows += AttentionRow(
                            title = title,
                            body = item.optString("body", "").trim(),
                            status = item.optString("status", "open").trim().ifEmpty { "open" },
                            importance = item.optString("importance", "normal").trim().lowercase()
                                .ifEmpty { "normal" },
                            harnessSlug = slug.ifBlank { null },
                            needsHuman = item.optBoolean("needsHuman", false),
                        )
                    } catch (_: Exception) { unavailable = true }
                }
            } catch (_: Exception) { unavailable = true }
        }
        ParsedAttention(rows, groups.length().toLong(), unavailable)
    } catch (_: Exception) {
        ParsedAttention(emptyList(), 0, true)
    }
}

internal fun decodeAttentionFeed(feed: AttentionFeed): ParsedAttention {
    val parsed = parseAttentionRows(feed.groupsJson)
    return parsed.copy(contentUnavailable = parsed.contentUnavailable ||
        parsed.groupCount != feed.groupCount || feed.workItemCount != feed.workItems.size.toLong())
}

internal fun inboxPresentation(
    feed: AttentionFeed?, visibleAttentionRows: Int, groupsUnavailable: Boolean = false,
): InboxPresentation {
    val workItems = feed?.workItems?.size ?: 0
    val alerts = feed?.systemAlerts?.size ?: 0
    // A server reporting attention with no supported rows must not render inbox zero.
    val unavailable = groupsUnavailable || ((feed?.groupCount ?: 0) > 0 && visibleAttentionRows == 0)
    return InboxPresentation(
        subtitle = "$visibleAttentionRows needs you · $workItems work items · $alerts system alerts",
        isEmpty = !unavailable && visibleAttentionRows == 0 && workItems == 0 && alerts == 0,
        contentUnavailable = unavailable,
    )
}

// Count the entries the Inbox actually displays, never notification history or
// the number of groups. A failed/partial read is unknown, rather than zero.
internal fun inboxBadgeCount(feed: AttentionFeed?): Int? {
    if (feed == null) return null
    val parsed = decodeAttentionFeed(feed)
    if (inboxPresentation(feed, parsed.rows.size, parsed.contentUnavailable).contentUnavailable) return null
    return parsed.rows.size + feed.workItems.size + feed.systemAlerts.size
}

internal fun fleetAvailabilityText(activity: FleetActivitySummary?): String =
    if (activity == null) "Fleet activity is unavailable. Refresh to try again."
    else "${activity.availableAgents} available · ${activity.agents} agents"
