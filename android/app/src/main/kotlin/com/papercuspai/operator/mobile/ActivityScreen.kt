// SPDX-License-Identifier: GPL-3.0-or-later
package com.papercuspai.operator.mobile

import androidx.compose.foundation.background
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.res.stringResource
import com.papercuspai.operator.mobile.theme.PapercupCard
import com.papercuspai.operator.mobile.theme.PapercupCardHeader
import com.papercuspai.operator.mobile.theme.PapercupColors
import com.papercuspai.operator.mobile.theme.PapercupMetaText
import com.papercuspai.operator.mobile.theme.PapercupPanel
import com.papercuspai.operator.mobile.theme.PapercupScreenHeader
import com.papercuspai.operator.mobile.theme.PapercupStatusChip
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import uniffi.papercup.ApiException
import uniffi.papercup.AuditEntry
import uniffi.papercup.Toast as ToastEntry

private sealed interface ActivityState {
    data object Loading : ActivityState
    data class Ready(val toasts: List<ToastEntry>, val audit: List<AuditEntry>) : ActivityState
    data class Failed(val message: String) : ActivityState
}

enum class ActivitySurface {
    Notifications,
    History,
    Actions,
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ActivityScreen(
    creds: DeviceCredentials,
    invalidationTick: Int,
    onSelectHarness: (String) -> Unit,
    mode: ActivitySurface = ActivitySurface.Notifications,
    onOpenHistory: (() -> Unit)? = null,
    onOpenRecentActions: (() -> Unit)? = null,
    onBack: (() -> Unit)? = null,
) {
    var state by remember { mutableStateOf<ActivityState>(ActivityState.Loading) }

    LaunchedEffect(creds.deviceToken, invalidationTick) {
        state = ActivityState.Loading
        state = try {
            val client = creds.client()
            ActivityState.Ready(
                toasts = client.recentNotifications(),
                audit = client.recentActions(),
            )
        } catch (e: ApiException) {
            ActivityState.Failed(HumanError.describe(e, "Loading activity"))
        } catch (t: Throwable) {
            ActivityState.Failed(HumanError.describe(t, "Loading activity"))
        }
    }

    Scaffold(
        topBar = {
            PapercupScreenHeader(
                title = when (mode) {
                    ActivitySurface.Notifications -> stringResource(R.string.activity_title_notifications)
                    ActivitySurface.History -> stringResource(R.string.activity_title_history)
                    ActivitySurface.Actions -> stringResource(R.string.activity_title_recent_actions)
                },
                subtitle = subtitleFor(state, mode),
                navigationIcon = onBack?.let {
                    {
                        IconButton(onClick = it) {
                            Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
                        }
                    }
                },
                actions = {
                    if (mode != ActivitySurface.History && onOpenHistory != null) {
                        HeaderActionButton(
                            label = stringResource(R.string.activity_header_history),
                            onClick = onOpenHistory,
                        )
                    }
                    if (mode != ActivitySurface.Actions && onOpenRecentActions != null) {
                        HeaderActionButton(
                            label = stringResource(R.string.activity_header_recent_actions),
                            onClick = onOpenRecentActions,
                        )
                    }
                },
            )
        },
        containerColor = PapercupColors.Ink,
    ) { padding ->
        Box(
            Modifier
                .padding(padding)
                .fillMaxSize()
                .background(PapercupColors.ScreenGradient),
        ) {
            when (val s = state) {
                ActivityState.Loading -> LoadingState()
                is ActivityState.Failed -> ErrorState(s.message)
                is ActivityState.Ready -> when (mode) {
                    ActivitySurface.Notifications -> ToastFeedList(s.toasts, onSelectHarness)
                    ActivitySurface.History -> ToastHistoryList(s.toasts, onSelectHarness)
                    ActivitySurface.Actions -> AuditList(s.audit, onSelectHarness)
                }
            }
        }
    }
}

@Composable
private fun subtitleFor(state: ActivityState, mode: ActivitySurface): String = when (state) {
    ActivityState.Loading -> stringResource(R.string.loading)
    is ActivityState.Failed -> stringResource(R.string.activity_subtitle_unavailable)
    is ActivityState.Ready -> when (mode) {
        ActivitySurface.Notifications -> stringResource(R.string.activity_subtitle_recent_count, state.toasts.size)
        ActivitySurface.History -> stringResource(R.string.activity_subtitle_history_count, state.toasts.size)
        ActivitySurface.Actions -> stringResource(R.string.activity_subtitle_actions_count, state.audit.size)
    }
}

@Composable
private fun HeaderActionButton(label: String, onClick: () -> Unit) {
    OutlinedButton(
        onClick = onClick,
        contentPadding = PaddingValues(horizontal = 10.dp, vertical = 0.dp),
        border = BorderStroke(1.dp, PapercupColors.Stroke),
        colors = ButtonDefaults.outlinedButtonColors(
            containerColor = PapercupColors.AccentSoft.copy(alpha = 0.18f),
            contentColor = PapercupColors.AccentStrong,
        ),
        modifier = Modifier.heightIn(min = 30.dp),
    ) {
        Text(label.uppercase(), style = MaterialTheme.typography.labelSmall)
    }
}

@Composable
private fun LoadingState() {
    Box(
        Modifier
            .fillMaxWidth()
            .padding(top = 32.dp)
            .padding(horizontal = 16.dp),
        contentAlignment = Alignment.Center,
    ) {
        PapercupCard(contentPadding = PaddingValues(18.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                CircularProgressIndicator(strokeWidth = 2.dp)
                Spacer(Modifier.width(12.dp))
                Text(stringResource(R.string.loading_activity))
            }
        }
    }
}

@Composable
private fun ErrorState(message: String) {
    Box(Modifier.fillMaxSize().padding(16.dp)) {
        PapercupCard(accent = PapercupColors.ErrorSoft) {
            Text(
                message,
                color = PapercupColors.Error,
                fontFamily = FontFamily.Monospace,
                style = MaterialTheme.typography.bodySmall,
            )
        }
    }
}

@Composable
private fun ToastFeedList(toasts: List<ToastEntry>, onSelectHarness: (String) -> Unit) {
    if (toasts.isEmpty()) {
        EmptyState(stringResource(R.string.activity_no_notifications))
        return
    }
    LazyColumn(
        modifier = Modifier.fillMaxSize(),
        contentPadding = PaddingValues(horizontal = 16.dp, vertical = 12.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        item {
            PapercupCard(contentPadding = PaddingValues(12.dp)) {
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    PapercupCardHeader(
                        stringResource(R.string.activity_section_recent),
                        meta = toasts.size.toString(),
                    )
                    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        toasts.forEach { t ->
                            ToastCard(t, onSelectHarness)
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun ToastCard(t: ToastEntry, onSelectHarness: (String) -> Unit) {
    val accent = when (t.level.lowercase()) {
        "error" -> PapercupColors.ErrorSoft
        "warning", "warn" -> PapercupColors.WarningSoft
        "success" -> PapercupColors.SuccessSoft
        else -> PapercupColors.InfoSoft
    }
    val tone = when (t.level.lowercase()) {
        "error" -> PapercupColors.Error
        "warning", "warn" -> PapercupColors.Warning
        "success" -> PapercupColors.Success
        else -> PapercupColors.Info
    }
    PapercupCard(
        modifier = Modifier.fillMaxWidth(),
        accent = accent,
        contentPadding = PaddingValues(12.dp),
    ) {
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.Top,
            ) {
                Text(
                    t.message,
                    style = MaterialTheme.typography.titleSmall,
                    modifier = Modifier.weight(1f),
                )
                Spacer(Modifier.width(8.dp))
                PapercupMetaText(relativeTime(t.createdAt))
            }
            t.description?.takeIf { it.isNotBlank() }?.let {
                Text(it, style = MaterialTheme.typography.bodySmall)
            }
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Row(
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    PapercupStatusChip(text = t.level.uppercase(), containerColor = accent, contentColor = tone)
                    PapercupMetaText(formatTs(t.createdAt), monospace = true)
                }
                t.harnessSlug?.let { slug ->
                    TextButton(onClick = { onSelectHarness(slug) }) {
                        Text(slug, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    }
                }
            }
        }
    }
}

@Composable
private fun ToastHistoryList(toasts: List<ToastEntry>, onSelectHarness: (String) -> Unit) {
    if (toasts.isEmpty()) {
        EmptyState(stringResource(R.string.activity_no_history))
        return
    }
    LazyColumn(
        modifier = Modifier.fillMaxSize(),
        contentPadding = PaddingValues(horizontal = 16.dp, vertical = 12.dp),
    ) {
        item {
            PapercupPanel(contentPadding = PaddingValues(12.dp)) {
                Column(verticalArrangement = Arrangement.spacedBy(0.dp)) {
                    PapercupCardHeader(
                        stringResource(R.string.activity_section_history),
                        meta = toasts.size.toString(),
                    )
                    toasts.forEachIndexed { index, toast ->
                        if (index > 0) {
                            HorizontalDivider(color = PapercupColors.StrokeSoft)
                        }
                        ToastHistoryRow(toast, onSelectHarness)
                    }
                }
            }
        }
    }
}

@Composable
private fun ToastHistoryRow(t: ToastEntry, onSelectHarness: (String) -> Unit) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 10.dp),
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            PapercupMetaText(
                "${t.level.uppercase()} · ${formatTs(t.createdAt)}",
                monospace = true,
            )
            t.harnessSlug?.let { slug ->
                TextButton(onClick = { onSelectHarness(slug) }, contentPadding = PaddingValues(0.dp)) {
                    Text(slug, style = MaterialTheme.typography.labelSmall)
                }
            }
        }
        Text(t.message, style = MaterialTheme.typography.bodyMedium)
        t.description?.takeIf { it.isNotBlank() }?.let {
            Text(it, style = MaterialTheme.typography.bodySmall, color = PapercupColors.TextFaint)
        }
    }
}

@Composable
private fun AuditList(entries: List<AuditEntry>, onSelectHarness: (String) -> Unit) {
    if (entries.isEmpty()) {
        EmptyState(stringResource(R.string.activity_no_actions))
        return
    }
    LazyColumn(
        modifier = Modifier.fillMaxSize(),
        contentPadding = PaddingValues(horizontal = 16.dp, vertical = 12.dp),
    ) {
        item {
            PapercupPanel(contentPadding = PaddingValues(12.dp)) {
                Column(verticalArrangement = Arrangement.spacedBy(0.dp)) {
                    PapercupCardHeader(
                        stringResource(R.string.activity_section_actions),
                        meta = entries.size.toString(),
                    )
                    entries.forEachIndexed { index, entry ->
                        if (index > 0) {
                            HorizontalDivider(color = PapercupColors.StrokeSoft)
                        }
                        AuditRow(entry, onSelectHarness)
                    }
                }
            }
        }
    }
}

@Composable
private fun AuditRow(e: AuditEntry, onSelectHarness: (String) -> Unit) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 10.dp),
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                e.actor.uppercase(),
                style = MaterialTheme.typography.labelSmall,
                color = PapercupColors.AccentStrong,
            )
            PapercupMetaText(relativeTime(e.ts), monospace = true)
        }
        Text(
            text = e.action,
            style = MaterialTheme.typography.bodyMedium,
            color = PapercupColors.Text,
        )
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            PapercupMetaText(
                e.subject,
                monospace = true,
                modifier = Modifier.weight(1f),
            )
            harnessSlugFromSubject(e.subject)?.let { slug ->
                TextButton(onClick = { onSelectHarness(slug) }) {
                    Text(slug, maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
            }
        }
    }
}

@Composable
private fun EmptyState(text: String) {
    Box(Modifier.fillMaxSize().padding(horizontal = 16.dp), contentAlignment = Alignment.Center) {
        PapercupCard(contentPadding = PaddingValues(18.dp)) {
            PapercupMetaText(text)
        }
    }
}

private fun harnessSlugFromSubject(subject: String): String? =
    subject
        .removePrefix("harness:")
        .substringBefore(':')
        .takeIf { it.isNotBlank() && it != subject }

private val FMT = SimpleDateFormat("MMM d HH:mm:ss", Locale.US)

private fun formatTs(unixSeconds: Long): String =
    FMT.format(Date(unixSeconds * 1000))

private fun relativeTime(unixSeconds: Long): String {
    val seconds = ((System.currentTimeMillis() / 1000) - unixSeconds).coerceAtLeast(0)
    return when {
        seconds < 60 -> "${seconds}s"
        seconds < 3600 -> "${seconds / 60}m"
        seconds < 86_400 -> "${seconds / 3600}h"
        else -> "${seconds / 86_400}d"
    }
}
