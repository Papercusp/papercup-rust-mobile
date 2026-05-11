// SPDX-License-Identifier: GPL-3.0-or-later
package com.papercuspai.operator.mobile

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import kotlinx.coroutines.launch
import uniffi.papercup.ApiException
import uniffi.papercup.Harness
import uniffi.papercup.OperatorClient
import uniffi.papercup.Running
import uniffi.papercup.Toast as ToastEntry
import uniffi.papercup.VoiceLease

/// Tauri-parity landing surface. Aggregates the things you'd want at
/// a glance — pause status, current voice lease holder, top recent
/// harnesses, and the most recent operator notifications. Each card
/// taps through to the appropriate full-tab view.
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun OperatorScreen(
    creds: DeviceCredentials,
    voice: VoiceManager,
    liveTick: Int,
    onSelectHarness: (String) -> Unit,
) {
    var paused by remember { mutableStateOf<Boolean?>(null) }
    var lease by remember { mutableStateOf<VoiceLease?>(null) }
    var leaseUnknown by remember { mutableStateOf(true) }
    var running by remember { mutableStateOf<List<Running>>(emptyList()) }
    var harnesses by remember { mutableStateOf<List<Harness>>(emptyList()) }
    var toasts by remember { mutableStateOf<List<ToastEntry>>(emptyList()) }
    var error by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()

    // Each call is independent so a transient failure on one (e.g. operator
    // mid-restart, route 404) doesn't blank the rest of the surface. The
    // last successful values for each card persist; the error banner shows
    // only when nothing succeeded.
    LaunchedEffect(creds.deviceToken, liveTick) {
        val client = creds.client()
        var anyOk = false
        var lastErr: String? = null
        suspend fun <T> tryFetch(label: String, block: suspend () -> T): T? = try {
            val v = block()
            anyOk = true
            v
        } catch (e: ApiException) { lastErr = "$label: ${e::class.simpleName}"; null }
          catch (t: Throwable)   { lastErr = "$label: ${t::class.simpleName}"; null }

        tryFetch("pause") { client.pauseGet() }?.let { paused = it.paused }
        tryFetch("lease") { client.voiceLeaseGet() }.also { leaseUnknown = !anyOk }?.let { lease = it }
        tryFetch("running") { client.listRunning() }?.let { running = it }
        tryFetch("harnesses") { client.listHarnesses() }
            ?.sortedByDescending { it.lastActiveTs ?: Long.MIN_VALUE }
            ?.let { harnesses = it }
        tryFetch("notifs") { client.recentNotifications() }?.let { toasts = it }
        error = if (anyOk) null else lastErr
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = {
                    Column {
                        Text(stringResource(R.string.operator_screen_title), style = MaterialTheme.typography.titleLarge)
                        Text(
                            "core ${uniffi.papercup.version()} · ${creds.server}",
                            style = MaterialTheme.typography.bodySmall,
                            fontFamily = FontFamily.Monospace,
                        )
                    }
                },
            )
        },
    ) { padding ->
        Column(
            modifier = Modifier.fillMaxSize().padding(padding).padding(horizontal = 16.dp).verticalScroll(rememberScrollState()),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Spacer(Modifier.height(8.dp))
            error?.let { ErrorCard(it) }

            // Pause + voice-lease status row
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                PauseCard(
                    paused = paused,
                    onToggle = { target ->
                        scope.launch {
                            try {
                                paused = creds.client().pauseSet(target)
                            } catch (_: Throwable) {}
                        }
                    },
                    modifier = Modifier.weight(1f),
                )
                VoiceLeaseCard(
                    lease = lease,
                    leaseUnknown = leaseUnknown,
                    selfDeviceId = creds.deviceId,
                    modifier = Modifier.weight(1f),
                )
            }

            RunningCard(running, onSelectHarness)
            RecentHarnessesCard(harnesses, onSelectHarness)
            RecentNotificationsCard(toasts, onSelectHarness)
            IdentityCard(creds)
        }
    }
}

@Composable
private fun ErrorCard(message: String) {
    Card(colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.errorContainer)) {
        Text(
            message,
            modifier = Modifier.padding(12.dp),
            color = MaterialTheme.colorScheme.onErrorContainer,
            fontFamily = FontFamily.Monospace,
            style = MaterialTheme.typography.bodySmall,
        )
    }
}

@Composable
private fun PauseCard(
    paused: Boolean?,
    onToggle: (Boolean) -> Unit,
    modifier: Modifier = Modifier,
) {
    val isPaused = paused == true
    Card(
        modifier = modifier
            .clickable(enabled = paused != null) { onToggle(!isPaused) }
            .semantics {
                contentDescription = when (paused) {
                    true -> "Operator paused. Double-tap to resume."
                    false -> "Operator running. Double-tap to pause."
                    null -> "Operator state loading."
                }
                role = Role.Button
            },
        colors = if (isPaused) {
            CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.errorContainer)
        } else {
            CardDefaults.cardColors()
        },
    ) {
        Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(stringResource(R.string.operator_label), style = MaterialTheme.typography.labelSmall)
            Text(
                when (paused) {
                    true -> "PAUSED"
                    false -> "RUNNING"
                    null -> "…"
                },
                style = MaterialTheme.typography.titleMedium,
            )
            Text(
                "tap to ${if (isPaused) "resume" else "pause"}",
                style = MaterialTheme.typography.labelSmall,
            )
        }
    }
}

@Composable
private fun VoiceLeaseCard(
    lease: VoiceLease?,
    leaseUnknown: Boolean,
    selfDeviceId: String,
    modifier: Modifier = Modifier,
) {
    val (label, sub) = when {
        leaseUnknown -> "…" to ""
        lease == null -> "IDLE" to "no listener"
        lease.ownerId == selfDeviceId -> "THIS PHONE" to "active listener"
        lease.ownerKind == "mobile" -> "OTHER PHONE" to lease.ownerId.take(8) + "…"
        else -> "DESKTOP" to lease.ownerId.take(8) + "…"
    }
    Card(
        modifier = modifier.semantics {
            contentDescription = "Voice lease: $label. $sub"
        },
    ) {
        Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(stringResource(R.string.voice_label), style = MaterialTheme.typography.labelSmall)
            Text(label, style = MaterialTheme.typography.titleMedium)
            Text(sub, style = MaterialTheme.typography.labelSmall)
        }
    }
}

@Composable
private fun RunningCard(running: List<Running>, onSelect: (String) -> Unit) {
    Card(modifier = Modifier.fillMaxWidth()) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(stringResource(R.string.currently_running), style = MaterialTheme.typography.titleSmall)
                AssistChip(
                    onClick = {},
                    label = { Text("${running.size}", style = MaterialTheme.typography.labelSmall) },
                )
            }
            if (running.isEmpty()) {
                Text(stringResource(R.string.no_active_runs), style = MaterialTheme.typography.bodySmall)
            } else {
                running.forEach { r ->
                    Column(
                        modifier = Modifier.fillMaxWidth().clickable { onSelect(r.harnessSlug) }.padding(vertical = 4.dp),
                        verticalArrangement = Arrangement.spacedBy(2.dp),
                    ) {
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.SpaceBetween,
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Text(r.harnessSlug, style = MaterialTheme.typography.bodyMedium)
                            AssistChip(onClick = {}, label = { Text("${r.phase} · ${r.status}") })
                        }
                        // passed/todo/blocked counts + active roles
                        val counts = "✓${r.passedCount} · ☐${r.todoCount}" +
                            (if (r.blockedCount > 0) " · ⚠${r.blockedCount}" else "")
                        Text(
                            "$counts · iter ${r.iteration}",
                            style = MaterialTheme.typography.labelSmall,
                            fontFamily = FontFamily.Monospace,
                        )
                        if (r.activeRoles.isNotEmpty()) {
                            Text(
                                "roles: ${r.activeRoles.joinToString(", ")}",
                                style = MaterialTheme.typography.labelSmall,
                            )
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun RecentHarnessesCard(harnesses: List<Harness>, onSelect: (String) -> Unit) {
    Card(modifier = Modifier.fillMaxWidth()) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Text(stringResource(R.string.recent_harnesses), style = MaterialTheme.typography.titleSmall)
            if (harnesses.isEmpty()) {
                Text(stringResource(R.string.no_harnesses_yet), style = MaterialTheme.typography.bodySmall)
            } else {
                harnesses.take(5).forEach { h ->
                    Row(
                        modifier = Modifier.fillMaxWidth().clickable { onSelect(h.slug) }.padding(vertical = 4.dp),
                        horizontalArrangement = Arrangement.SpaceBetween,
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Column(verticalArrangement = Arrangement.spacedBy(2.dp), modifier = Modifier.weight(1f)) {
                            Text(h.slug, style = MaterialTheme.typography.bodyMedium)
                            val meta = buildList {
                                h.harnessKind?.let { add("kind=$it") }
                                h.iteration?.let { add("iter=$it") }
                                if (!h.hasState) add("no-state")
                            }.joinToString(" · ")
                            if (meta.isNotEmpty()) {
                                Text(meta, style = MaterialTheme.typography.labelSmall)
                            }
                        }
                        h.status?.let { AssistChip(onClick = {}, label = { Text(it) }) }
                    }
                }
            }
        }
    }
}

@Composable
private fun RecentNotificationsCard(toasts: List<ToastEntry>, onSelectHarness: (String) -> Unit) {
    if (toasts.isEmpty()) return
    Card(modifier = Modifier.fillMaxWidth()) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(stringResource(R.string.recent_activity), style = MaterialTheme.typography.titleSmall)
            toasts.take(3).forEach { t ->
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .let { mod ->
                            t.harnessSlug?.let { slug -> mod.clickable { onSelectHarness(slug) } } ?: mod
                        },
                    verticalArrangement = Arrangement.spacedBy(2.dp),
                ) {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.SpaceBetween,
                    ) {
                        Text(t.message, style = MaterialTheme.typography.bodySmall)
                        Text(
                            FMT.format(Date(t.createdAt * 1000)),
                            style = MaterialTheme.typography.labelSmall,
                            fontFamily = FontFamily.Monospace,
                        )
                    }
                    t.harnessSlug?.let {
                        Text(it, style = MaterialTheme.typography.labelSmall)
                    }
                }
            }
        }
    }
}

@Composable
private fun IdentityCard(creds: DeviceCredentials) {
    Card(modifier = Modifier.fillMaxWidth()) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(stringResource(R.string.this_device), style = MaterialTheme.typography.titleSmall)
            KvLine("workspace", creds.workspaceId)
            KvLine("device", creds.deviceId.take(12) + "…")
            creds.meshAssignedIp?.let { KvLine("mesh", it) }
        }
    }
}

@Composable
private fun KvLine(key: String, value: String) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(key, style = MaterialTheme.typography.bodySmall)
        Text(value, style = MaterialTheme.typography.bodySmall, fontFamily = FontFamily.Monospace)
    }
}

private val FMT = SimpleDateFormat("MMM d HH:mm", Locale.US)
