// SPDX-License-Identifier: GPL-3.0-or-later
package com.papercuspai.operator.mobile

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.papercuspai.operator.mobile.theme.PapercupCard
import com.papercuspai.operator.mobile.theme.PapercupColors
import com.papercuspai.operator.mobile.theme.PapercupMetaText
import com.papercuspai.operator.mobile.theme.PapercupScreenHeader
import com.papercuspai.operator.mobile.theme.PapercupStatusChip
import kotlinx.coroutines.launch
import org.json.JSONArray
import org.json.JSONObject
import uniffi.papercup.PlanDetail
import uniffi.papercup.PlanSummary

// ---------------------------------------------------------------------------
// Local item model parsed defensively from PlanDetail.itemsJson.
// ---------------------------------------------------------------------------
private data class PlanItem(
    val id: String,
    val status: String,
    val text: String,
    val importance: String,
)

private data class NowBlock(val state: String?, val next: String?)

private fun parsePlanItems(itemsJson: String): List<PlanItem> {
    return try {
        val arr = JSONArray(itemsJson)
        val out = ArrayList<PlanItem>(arr.length())
        for (i in 0 until arr.length()) {
            val obj = arr.optJSONObject(i) ?: continue
            val id = obj.optString("id", "").trim()
            if (id.isEmpty()) continue
            out.add(
                PlanItem(
                    id = id,
                    status = obj.optString("status", "").ifBlank { "todo" },
                    text = obj.optString("text", ""),
                    importance = obj.optString("importance", "normal"),
                ),
            )
        }
        out
    } catch (t: Throwable) {
        emptyList()
    }
}

private fun parseNow(nowJson: String): NowBlock? {
    return try {
        val obj = JSONObject(nowJson)
        val state = obj.optString("state", "").takeIf { it.isNotBlank() }
        val next = obj.optString("next", "").takeIf { it.isNotBlank() }
        if (state == null && next == null) null else NowBlock(state, next)
    } catch (t: Throwable) {
        null
    }
}

private fun itemCountSummary(counts: Map<String, Long>): String {
    if (counts.isEmpty()) return "no items"
    return counts.entries
        .filter { it.value > 0 }
        .sortedByDescending { it.value }
        .joinToString(" · ") { "${it.value} ${it.key}" }
        .ifBlank { "no items" }
}

private fun statusChipColors(status: String): Pair<Color, Color> {
    val normalized = status.lowercase()
    return when {
        normalized.contains("done") || normalized.contains("complete") || normalized.contains("pass") ->
            PapercupColors.SuccessSoft to PapercupColors.Success
        normalized.contains("block") || normalized.contains("fail") || normalized.contains("error") ||
            normalized.contains("needs-human") || normalized.contains("needs human") ->
            PapercupColors.ErrorSoft to PapercupColors.Error
        normalized.contains("wip") || normalized.contains("progress") || normalized.contains("running") ->
            PapercupColors.WarningSoft to PapercupColors.Warning
        normalized.contains("todo") || normalized.contains("queue") || normalized.contains("pending") ->
            PapercupColors.InfoSoft to PapercupColors.Info
        else ->
            PapercupColors.AccentSoft to PapercupColors.AccentStrong
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PlansScreen(
    creds: DeviceCredentials,
    liveTick: Int,
    potFilter: String?,
) {
    var selected by remember { mutableStateOf<PlanSummary?>(null) }

    // System back pops the internal detail instead of exiting the activity
    // (found by the on-device E2E pass — back from a plan detail left the app).
    androidx.activity.compose.BackHandler(enabled = selected != null) { selected = null }

    val current = selected
    if (current == null) {
        PlansListView(
            creds = creds,
            liveTick = liveTick,
            potFilter = potFilter,
            onSelect = { selected = it },
        )
    } else {
        PlanDetailView(
            creds = creds,
            liveTick = liveTick,
            plan = current,
            onBack = { selected = null },
        )
    }
}

// ---------------------------------------------------------------------------
// LIST
// ---------------------------------------------------------------------------
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun PlansListView(
    creds: DeviceCredentials,
    liveTick: Int,
    potFilter: String?,
    onSelect: (PlanSummary) -> Unit,
) {
    var loading by remember { mutableStateOf(true) }
    var plans by remember { mutableStateOf<List<PlanSummary>>(emptyList()) }
    var error by remember { mutableStateOf<String?>(null) }

    LaunchedEffect(creds.deviceToken, liveTick, potFilter) {
        loading = true
        try {
            plans = creds.client().plansList(potFilter, false)
            error = null
        } catch (t: Throwable) {
            error = t.message ?: "Failed to load plans"
        } finally {
            loading = false
        }
    }

    val subtitle = when {
        loading -> "Loading…"
        else -> "${plans.size} plans"
    }

    Scaffold(
        topBar = {
            PapercupScreenHeader(
                title = "Plans",
                subtitle = subtitle,
            )
        },
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
                loading -> {
                    Box(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(top = 48.dp),
                        contentAlignment = Alignment.Center,
                    ) {
                        CircularProgressIndicator(
                            strokeWidth = 2.dp,
                            color = PapercupColors.Accent,
                            modifier = Modifier.size(28.dp),
                        )
                    }
                }
                error != null -> {
                    PapercupCard(
                        modifier = Modifier.padding(top = 16.dp),
                        accent = PapercupColors.ErrorSoft,
                    ) {
                        Text(
                            text = error ?: "Failed to load plans",
                            color = PapercupColors.Error,
                            style = MaterialTheme.typography.bodySmall,
                            fontFamily = FontFamily.Monospace,
                        )
                    }
                }
                plans.isEmpty() -> {
                    PapercupCard(modifier = Modifier.padding(top = 16.dp)) {
                        Text(
                            text = "No plans.",
                            color = PapercupColors.TextMuted,
                            style = MaterialTheme.typography.bodyMedium,
                        )
                    }
                }
                else -> {
                    LazyColumn(
                        modifier = Modifier.fillMaxSize(),
                        contentPadding = PaddingValues(top = 8.dp, bottom = 96.dp),
                        verticalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        items(plans) { plan ->
                            PlanRow(plan = plan, onClick = { onSelect(plan) })
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun PlanRow(plan: PlanSummary, onClick: () -> Unit) {
    val (chipContainer, chipContent) = statusChipColors(plan.status ?: "")
    PapercupCard(modifier = Modifier.clickable { onClick() }) {
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.Top,
            ) {
                Text(
                    text = plan.title,
                    modifier = Modifier.weight(1f),
                    style = MaterialTheme.typography.titleMedium,
                    color = PapercupColors.Text,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
                Spacer(Modifier.width(8.dp))
                PapercupStatusChip(
                    text = plan.status ?: "—",
                    containerColor = chipContainer,
                    contentColor = chipContent,
                )
            }
            PapercupMetaText(text = itemCountSummary(plan.itemCounts))
            val next = plan.nowNext
            if (!next.isNullOrBlank()) {
                Text(
                    text = "▸ $next",
                    style = MaterialTheme.typography.bodySmall,
                    color = PapercupColors.TextMuted,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            PapercupMetaText(text = "pot ${plan.harness}", monospace = true)
        }
    }
}

// ---------------------------------------------------------------------------
// DETAIL
// ---------------------------------------------------------------------------
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun PlanDetailView(
    creds: DeviceCredentials,
    liveTick: Int,
    plan: PlanSummary,
    onBack: () -> Unit,
) {
    var loading by remember { mutableStateOf(true) }
    var detail by remember { mutableStateOf<PlanDetail?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    var actionError by remember { mutableStateOf<String?>(null) }
    var busyItem by remember { mutableStateOf<String?>(null) }
    var refresh by remember { mutableStateOf(0) }
    val scope = rememberCoroutineScope()

    LaunchedEffect(plan.slug, liveTick, refresh) {
        loading = true
        try {
            detail = creds.client().planGet(plan.slug, plan.harness)
            error = null
        } catch (t: Throwable) {
            error = t.message ?: "Failed to load plan"
        } finally {
            loading = false
        }
    }

    Scaffold(
        topBar = {
            PapercupScreenHeader(
                title = plan.title,
                subtitle = "pot ${plan.harness}",
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(
                            Icons.AutoMirrored.Filled.ArrowBack,
                            contentDescription = "Back",
                            tint = PapercupColors.Text,
                        )
                    }
                },
            )
        },
        containerColor = PapercupColors.Ink,
    ) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .background(PapercupColors.ScreenGradient)
                .padding(padding)
                .padding(horizontal = 16.dp)
                .verticalScroll(rememberScrollState()),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Spacer(Modifier.height(8.dp))

            actionError?.let { msg ->
                PapercupCard(accent = PapercupColors.ErrorSoft) {
                    Text(
                        text = msg,
                        color = PapercupColors.Error,
                        style = MaterialTheme.typography.bodySmall,
                        fontFamily = FontFamily.Monospace,
                    )
                }
            }

            when {
                loading && detail == null -> {
                    Box(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(top = 40.dp),
                        contentAlignment = Alignment.Center,
                    ) {
                        CircularProgressIndicator(
                            strokeWidth = 2.dp,
                            color = PapercupColors.Accent,
                            modifier = Modifier.size(28.dp),
                        )
                    }
                }
                error != null && detail == null -> {
                    PapercupCard(accent = PapercupColors.ErrorSoft) {
                        Text(
                            text = error ?: "Failed to load plan",
                            color = PapercupColors.Error,
                            style = MaterialTheme.typography.bodySmall,
                            fontFamily = FontFamily.Monospace,
                        )
                    }
                }
                detail != null -> {
                    val d = detail!!
                    val now = remember(d.nowJson) { parseNow(d.nowJson) }
                    if (now != null) {
                        NowCard(now)
                    }
                    val items = remember(d.itemsJson) { parsePlanItems(d.itemsJson) }
                    if (items.isEmpty()) {
                        PapercupCard {
                            Text(
                                text = "No items.",
                                color = PapercupColors.TextMuted,
                                style = MaterialTheme.typography.bodyMedium,
                            )
                        }
                    } else {
                        items.forEach { item ->
                            PlanItemCard(
                                item = item,
                                busy = busyItem != null,
                                onAction = { newStatus ->
                                    actionError = null
                                    busyItem = item.id
                                    scope.launch {
                                        try {
                                            creds.client().planItemSetStatus(
                                                d.slug,
                                                item.id,
                                                newStatus,
                                                null,
                                                d.harness,
                                            )
                                            refresh++
                                        } catch (t: Throwable) {
                                            actionError = t.message ?: "Failed to update item"
                                        } finally {
                                            busyItem = null
                                        }
                                    }
                                },
                            )
                        }
                    }
                }
            }

            Spacer(Modifier.height(96.dp))
        }
    }
}

@Composable
private fun NowCard(now: NowBlock) {
    PapercupCard {
        Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
            PapercupMetaText(text = "NOW", monospace = true)
            now.state?.let { state ->
                Text(
                    text = state,
                    style = MaterialTheme.typography.titleMedium,
                    color = PapercupColors.Text,
                )
            }
            now.next?.let { next ->
                Text(
                    text = "▸ $next",
                    style = MaterialTheme.typography.bodyMedium,
                    color = PapercupColors.TextMuted,
                )
            }
        }
    }
}

@Composable
private fun PlanItemCard(
    item: PlanItem,
    busy: Boolean,
    onAction: (String) -> Unit,
) {
    val (chipContainer, chipContent) = statusChipColors(item.status)
    PapercupCard {
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    text = item.id,
                    modifier = Modifier.weight(1f),
                    style = MaterialTheme.typography.titleMedium,
                    color = PapercupColors.Text,
                    fontFamily = FontFamily.Monospace,
                )
                Spacer(Modifier.width(8.dp))
                PapercupStatusChip(
                    text = item.status,
                    containerColor = chipContainer,
                    contentColor = chipContent,
                )
            }
            if (item.text.isNotBlank()) {
                Text(
                    text = item.text,
                    style = MaterialTheme.typography.bodyMedium,
                    color = PapercupColors.TextMuted,
                )
            }
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                OutlinedButton(
                    onClick = { onAction("done") },
                    enabled = !busy,
                    colors = ButtonDefaults.outlinedButtonColors(
                        contentColor = PapercupColors.Success,
                    ),
                ) {
                    Text("Approve", style = MaterialTheme.typography.labelMedium)
                }
                OutlinedButton(
                    onClick = { onAction("wip") },
                    enabled = !busy,
                    colors = ButtonDefaults.outlinedButtonColors(
                        contentColor = PapercupColors.Warning,
                    ),
                ) {
                    Text("Nudge", style = MaterialTheme.typography.labelMedium)
                }
                OutlinedButton(
                    onClick = { onAction("needs-human") },
                    enabled = !busy,
                    colors = ButtonDefaults.outlinedButtonColors(
                        contentColor = PapercupColors.Error,
                    ),
                ) {
                    Text("Hold", style = MaterialTheme.typography.labelMedium)
                }
            }
        }
    }
}
