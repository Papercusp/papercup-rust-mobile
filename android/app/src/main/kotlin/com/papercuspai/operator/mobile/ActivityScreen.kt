// SPDX-License-Identifier: GPL-3.0-or-later
package com.papercuspai.operator.mobile

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.*
import com.papercuspai.operator.mobile.theme.PapercupCard
import com.papercuspai.operator.mobile.theme.PapercupColors
import com.papercuspai.operator.mobile.theme.PapercupMetaText
import com.papercuspai.operator.mobile.theme.PapercupPanel
import com.papercuspai.operator.mobile.theme.PapercupStatusChip
import com.papercuspai.operator.mobile.theme.PapercupCardHeader
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import uniffi.papercup.ApiException
import uniffi.papercup.AuditEntry
import uniffi.papercup.OperatorClient
import uniffi.papercup.Toast as ToastEntry

private sealed interface ActivityState {
    data object Loading : ActivityState
    data class Ready(val toasts: List<ToastEntry>, val audit: List<AuditEntry>) : ActivityState
    data class Failed(val message: String) : ActivityState
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ActivityScreen(
    creds: DeviceCredentials,
    invalidationTick: Int,
    onSelectHarness: (String) -> Unit,
) {
    var state by remember { mutableStateOf<ActivityState>(ActivityState.Loading) }
    var tab by remember { mutableStateOf(0) }

    LaunchedEffect(creds.deviceToken, invalidationTick) {
        state = ActivityState.Loading
        state = try {
            val client = OperatorClient(creds.server, creds.deviceToken)
            ActivityState.Ready(
                toasts = client.recentNotifications(),
                audit = client.recentActions(),
            )
        } catch (e: ApiException) {
            ActivityState.Failed("API: ${e::class.simpleName}: ${e.message ?: ""}")
        } catch (t: Throwable) {
            ActivityState.Failed("Unexpected: ${t::class.simpleName}: ${t.message ?: ""}")
        }
    }

    Scaffold(
        topBar = {
            Column {
                TopAppBar(
                    title = { Text("Activity") },
                    colors = TopAppBarDefaults.topAppBarColors(
                        containerColor = PapercupColors.InkRaised,
                        titleContentColor = PapercupColors.Text,
                        navigationIconContentColor = PapercupColors.Text,
                    ),
                )
                TabRow(selectedTabIndex = tab, containerColor = PapercupColors.InkRaised, contentColor = PapercupColors.Accent) {
                    Tab(selected = tab == 0, onClick = { tab = 0 }, text = { Text("Notifications") })
                    Tab(selected = tab == 1, onClick = { tab = 1 }, text = { Text("Actions") })
                }
            }
        },
        containerColor = PapercupColors.Ink,
    ) { padding ->
        Box(Modifier.padding(padding).fillMaxSize().background(PapercupColors.ScreenGradient)) {
            when (val s = state) {
                ActivityState.Loading -> Box(
                    Modifier.fillMaxWidth().padding(top = 32.dp).padding(horizontal = 16.dp),
                    contentAlignment = Alignment.Center,
                ) {
                    PapercupCard(contentPadding = PaddingValues(18.dp)) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            CircularProgressIndicator(strokeWidth = 2.dp)
                            Spacer(Modifier.width(12.dp))
                            Text("Loading activity…")
                        }
                    }
                }
                is ActivityState.Failed -> Box(
                    Modifier.fillMaxSize().padding(16.dp),
                ) {
                    PapercupCard(accent = PapercupColors.ErrorSoft) {
                        Text(
                            s.message,
                            color = PapercupColors.Error,
                            fontFamily = FontFamily.Monospace,
                            style = MaterialTheme.typography.bodySmall,
                        )
                    }
                }
                is ActivityState.Ready -> {
                    if (tab == 0) ToastList(s.toasts, onSelectHarness)
                    else AuditList(s.audit, onSelectHarness)
                }
            }
        }
    }
}

@Composable
private fun ToastList(toasts: List<ToastEntry>, onSelectHarness: (String) -> Unit) {
    if (toasts.isEmpty()) {
        EmptyState("No recent notifications")
        return
    }
    PapercupCard(contentPadding = PaddingValues(12.dp)) {
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            PapercupCardHeader("Notifications", meta = toasts.size.toString())
            LazyColumn(
                modifier = Modifier.heightIn(max = 640.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                items(toasts) { t -> ToastCard(t, onSelectHarness) }
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
        Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.Top,
            ) {
                Text(t.message, style = MaterialTheme.typography.titleSmall)
                PapercupStatusChip(text = t.level, containerColor = accent, contentColor = tone)
            }
            t.description?.takeIf { it.isNotBlank() }?.let {
                Text(it, style = MaterialTheme.typography.bodySmall)
            }
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                PapercupMetaText(formatTs(t.createdAt), monospace = true)
                t.harnessSlug?.let { slug ->
                    TextButton(onClick = { onSelectHarness(slug) }) { Text(slug) }
                }
            }
        }
    }
}

@Composable
private fun AuditList(entries: List<AuditEntry>, onSelectHarness: (String) -> Unit) {
    if (entries.isEmpty()) {
        EmptyState("No recent actions")
        return
    }
    PapercupPanel(contentPadding = PaddingValues(12.dp)) {
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            PapercupCardHeader("Actions", meta = entries.size.toString())
            LazyColumn(
                modifier = Modifier.heightIn(max = 640.dp),
                verticalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                items(entries) { e -> AuditCard(e, onSelectHarness) }
            }
        }
    }
}

@Composable
private fun AuditCard(e: AuditEntry, onSelectHarness: (String) -> Unit) {
    PapercupPanel(modifier = Modifier.fillMaxWidth(), contentPadding = PaddingValues(12.dp)) {
        Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(e.action, style = MaterialTheme.typography.titleSmall)
                PapercupMetaText(formatTs(e.ts), monospace = true)
            }
            Text("by ${e.actor}", style = MaterialTheme.typography.bodySmall)
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
                val slug = e.subject
                    .removePrefix("harness:")
                    .substringBefore(':')
                    .takeIf { it.isNotBlank() && it != e.subject }
                slug?.let {
                    TextButton(onClick = { onSelectHarness(it) }) { Text(it) }
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

private val FMT = SimpleDateFormat("MMM d HH:mm:ss", Locale.US)

private fun formatTs(unixSeconds: Long): String =
    FMT.format(Date(unixSeconds * 1000))
