// SPDX-License-Identifier: GPL-3.0-or-later
package com.papercuspai.operator.mobile

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import com.papercuspai.operator.mobile.theme.PapercupCard
import com.papercuspai.operator.mobile.theme.PapercupColors
import com.papercuspai.operator.mobile.theme.PapercupMetaText
import com.papercuspai.operator.mobile.theme.PapercupScreenHeader
import com.papercuspai.operator.mobile.theme.PapercupStatusChip
import org.json.JSONArray
import org.json.JSONObject
import uniffi.papercup.AttentionFeed
import uniffi.papercup.AttentionWorkItem

/**
 * A single flattened attention row, parsed defensively from
 * [AttentionFeed.groupsJson]. Each group in that JSON carries an `items`
 * array; we flatten every group's items into this list.
 */
private data class AttentionRow(
    val title: String,
    val body: String,
    val status: String,
    val importance: String,
    val harnessSlug: String?,
    val needsHuman: Boolean,
)

private fun parseAttentionRows(json: String?): List<AttentionRow> {
    if (json.isNullOrBlank()) return emptyList()
    return try {
        val groups: JSONArray = run {
            val trimmed = json.trim()
            when {
                trimmed.startsWith("[") -> JSONArray(trimmed)
                else -> {
                    val obj = JSONObject(trimmed)
                    obj.optJSONArray("groups") ?: JSONArray()
                }
            }
        }
        val rows = mutableListOf<AttentionRow>()
        for (g in 0 until groups.length()) {
            val group = groups.optJSONObject(g) ?: continue
            val items = group.optJSONArray("items") ?: continue
            for (i in 0 until items.length()) {
                val item = items.optJSONObject(i) ?: continue
                val title = item.optString("title", "").trim()
                if (title.isEmpty()) continue
                val slug = item.optString("harnessSlug", "")
                    .ifBlank { group.optString("harnessSlug", "") }
                    .trim()
                rows += AttentionRow(
                    title = title,
                    body = item.optString("body", "").trim(),
                    status = item.optString("status", "open").trim().ifEmpty { "open" },
                    importance = item.optString("importance", "normal").trim().lowercase()
                        .ifEmpty { "normal" },
                    harnessSlug = slug.ifBlank { null },
                    needsHuman = item.optBoolean("needsHuman", false),
                )
            }
        }
        rows
    } catch (t: Throwable) {
        emptyList()
    }
}

/** Container/content color pair for an importance level. */
private fun importanceColors(importance: String): Pair<Color, Color> = when (importance) {
    "urgent" -> PapercupColors.ErrorSoft to PapercupColors.Error
    "high" -> PapercupColors.WarningSoft to PapercupColors.Warning
    "normal" -> PapercupColors.AccentSoft to PapercupColors.Accent
    "low" -> PapercupColors.Ink to PapercupColors.TextMuted
    else -> PapercupColors.AccentSoft to PapercupColors.Accent
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun InboxScreen(
    creds: DeviceCredentials,
    liveTick: Int,
    onSelectHarness: (String) -> Unit,
) {
    var loading by remember { mutableStateOf(true) }
    var feed by remember { mutableStateOf<AttentionFeed?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(creds.deviceToken, liveTick) {
        loading = true
        try { feed = creds.client().attention(); error = null }
        catch (t: Throwable) { error = t.message ?: t::class.simpleName ?: "Failed to load inbox" }
        finally { loading = false }
    }

    val attentionRows = remember(feed) { parseAttentionRows(feed?.groupsJson) }
    val workItems: List<AttentionWorkItem> = feed?.workItems ?: emptyList()

    val subtitle = when {
        loading && feed == null -> "Loading…"
        else -> {
            val needs = attentionRows.size
            val work = workItems.size
            "$needs needs you · $work work items"
        }
    }

    Scaffold(
        topBar = { PapercupScreenHeader(title = "Inbox", subtitle = subtitle) },
        containerColor = PapercupColors.Ink,
    ) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .background(PapercupColors.ScreenGradient)
                .padding(padding)
                .padding(horizontal = 16.dp),
        ) {
            when {
                loading && feed == null -> LoadingState()
                error != null -> ErrorState(error!!)
                attentionRows.isEmpty() && workItems.isEmpty() -> EmptyState()
                else -> InboxList(
                    attentionRows = attentionRows,
                    workItems = workItems,
                    onSelectHarness = onSelectHarness,
                )
            }
        }
    }
}

@Composable
private fun LoadingState() {
    Column(
        modifier = Modifier.fillMaxSize(),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        CircularProgressIndicator(strokeWidth = 2.dp, color = PapercupColors.Accent)
        Spacer(Modifier.height(12.dp))
        Text(
            text = "Loading inbox…",
            style = MaterialTheme.typography.bodyMedium,
            color = PapercupColors.TextMuted,
        )
    }
}

@Composable
private fun ErrorState(message: String) {
    Column(
        modifier = Modifier.fillMaxSize(),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Spacer(Modifier.height(8.dp))
        PapercupCard(accent = PapercupColors.ErrorSoft) {
            Column {
                Text(
                    text = "Could not load inbox",
                    style = MaterialTheme.typography.titleSmall,
                    color = PapercupColors.Error,
                )
                Spacer(Modifier.height(6.dp))
                Text(
                    text = message,
                    style = MaterialTheme.typography.bodySmall,
                    color = PapercupColors.Error,
                    fontFamily = FontFamily.Monospace,
                )
            }
        }
    }
}

@Composable
private fun EmptyState() {
    Column(
        modifier = Modifier.fillMaxSize(),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Spacer(Modifier.height(8.dp))
        PapercupCard(accent = PapercupColors.AccentSoft) {
            Column {
                Text(
                    text = "Inbox zero — nothing needs you right now.",
                    style = MaterialTheme.typography.bodyMedium,
                    color = PapercupColors.TextMuted,
                )
            }
        }
    }
}

@Composable
private fun InboxList(
    attentionRows: List<AttentionRow>,
    workItems: List<AttentionWorkItem>,
    onSelectHarness: (String) -> Unit,
) {
    LazyColumn(
        modifier = Modifier.fillMaxSize(),
        contentPadding = PaddingValues(top = 8.dp, bottom = 96.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        if (attentionRows.isNotEmpty()) {
            item { SectionLabel("Needs you") }
            items(attentionRows) { row ->
                AttentionCard(row = row, onSelectHarness = onSelectHarness)
            }
        }
        if (workItems.isNotEmpty()) {
            item { SectionLabel("Work items") }
            items(workItems) { wi ->
                WorkItemCard(item = wi, onSelectHarness = onSelectHarness)
            }
        }
    }
}

@Composable
private fun SectionLabel(text: String) {
    Text(
        text = text.uppercase(),
        style = MaterialTheme.typography.labelSmall,
        color = PapercupColors.TextMuted,
        modifier = Modifier.padding(top = 8.dp, bottom = 2.dp),
    )
}

@Composable
private fun AttentionCard(
    row: AttentionRow,
    onSelectHarness: (String) -> Unit,
) {
    val slug = row.harnessSlug?.takeIf { it.isNotBlank() }
    val clickMod = if (slug != null) {
        Modifier.clickable { onSelectHarness(slug) }
    } else {
        Modifier
    }
    val (importContainer, importContent) = importanceColors(row.importance)

    PapercupCard(modifier = clickMod) {
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.Top,
            ) {
                Text(
                    text = row.title,
                    modifier = Modifier.weight(1f).padding(end = 8.dp),
                    style = MaterialTheme.typography.titleMedium,
                    color = PapercupColors.Text,
                )
                PapercupStatusChip(
                    text = row.status,
                    containerColor = PapercupColors.AccentSoft,
                    contentColor = PapercupColors.Accent,
                )
            }
            Row(
                horizontalArrangement = Arrangement.spacedBy(6.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                PapercupStatusChip(
                    text = row.importance,
                    containerColor = importContainer,
                    contentColor = importContent,
                )
                if (row.needsHuman) {
                    PapercupStatusChip(
                        text = "needs human",
                        containerColor = PapercupColors.WarningSoft,
                        contentColor = PapercupColors.Warning,
                    )
                }
            }
            if (row.body.isNotBlank()) {
                Text(
                    text = row.body,
                    style = MaterialTheme.typography.bodySmall,
                    color = PapercupColors.TextMuted,
                )
            }
            if (slug != null) {
                PapercupMetaText(text = "→ $slug", monospace = true)
            }
        }
    }
}

@Composable
private fun WorkItemCard(
    item: AttentionWorkItem,
    onSelectHarness: (String) -> Unit,
) {
    val slug = item.harness?.takeIf { it.isNotBlank() }
    val clickMod = if (slug != null) {
        Modifier.clickable { onSelectHarness(slug) }
    } else {
        Modifier
    }

    PapercupCard(modifier = clickMod) {
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.Top,
            ) {
                Text(
                    text = item.title,
                    modifier = Modifier.weight(1f).padding(end = 8.dp),
                    style = MaterialTheme.typography.titleMedium,
                    color = PapercupColors.Text,
                )
                PapercupStatusChip(
                    text = item.state,
                    containerColor = PapercupColors.InfoSoft,
                    contentColor = PapercupColors.Info,
                )
            }
            val harnessLabel = slug ?: "—"
            PapercupMetaText(text = "${item.kind} · $harnessLabel", monospace = true)
        }
    }
}
