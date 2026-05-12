// SPDX-License-Identifier: GPL-3.0-or-later
package com.papercuspai.operator.mobile

import android.os.Build
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import com.google.firebase.messaging.FirebaseMessaging
import com.papercuspai.operator.mobile.theme.PapercupCard
import com.papercuspai.operator.mobile.theme.PapercupColors
import com.papercuspai.operator.mobile.theme.PapercupMetaText
import com.papercuspai.operator.mobile.theme.PapercupScreenHeader
import com.papercuspai.operator.mobile.theme.PapercupStatusChip
import kotlinx.coroutines.launch
import kotlinx.coroutines.tasks.await
import java.text.DateFormat
import java.util.Date

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun DiagnosticsScreen(
    creds: DeviceCredentials,
    monitor: ConnectionMonitor,
    onBack: () -> Unit,
    onOpenPushTapTest: () -> Unit,
) {
    val state by monitor.state.collectAsState()
    val meshState by MeshState.state.collectAsState()
    val scope = rememberCoroutineScope()
    var pinging by remember { mutableStateOf(false) }
    var fcmToken by remember { mutableStateOf<String?>(null) }
    var fcmError by remember { mutableStateOf<String?>(null) }

    LaunchedEffect(creds.deviceToken) {
        runCatching { FirebaseMessaging.getInstance().token.await() }
            .onSuccess { fcmToken = it }
            .onFailure { fcmError = it.message ?: it.javaClass.simpleName }
    }

    Scaffold(
        topBar = {
            PapercupScreenHeader(
                title = stringResource(R.string.diagnostics_title),
                subtitle = creds.workspaceId,
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(
                            imageVector = Icons.AutoMirrored.Filled.ArrowBack,
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
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Spacer(Modifier.height(12.dp))
            SectionShell(title = "Connection") {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 16.dp, vertical = 12.dp),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(
                        text = stringResource(R.string.diagnostics_status),
                        style = MaterialTheme.typography.bodySmall,
                        color = PapercupColors.TextMuted,
                    )
                    StatusPill(state.status)
                }
                HorizontalDivider(color = PapercupColors.StrokeSoft.copy(alpha = 0.55f))
                ValueRow(label = "Last ping", value = state.lastPingMs?.let { "$it ms" } ?: "—", last = false)
                state.offlineSinceMs?.let {
                    ValueRow(label = "Offline since", value = formatTimestamp(it), last = false)
                }
                ValueRow(label = "Runtime", value = "Native Android", last = false)
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(12.dp),
                    horizontalArrangement = Arrangement.Start,
                ) {
                    Button(
                        onClick = {
                            pinging = true
                            scope.launch {
                                monitor.probe()
                                pinging = false
                            }
                        },
                        enabled = !pinging,
                        colors = ButtonDefaults.buttonColors(
                            containerColor = PapercupColors.AccentStrong,
                            contentColor = PapercupColors.ButtonInk,
                        ),
                    ) {
                        Text(if (pinging) stringResource(R.string.diagnostics_pinging) else stringResource(R.string.diagnostics_ping_button))
                    }
                }
            }

            SectionShell(title = "Pairing") {
                ValueRow(label = "Device ID", value = creds.deviceId, mono = true, last = false)
                ValueRow(label = "Workspace", value = creds.workspaceId, last = false)
                ValueRow(label = "Desktop host", value = creds.server, last = false)
                ValueRow(label = "Token (first 12)", value = creds.deviceToken.take(12) + "…", mono = true, last = false)
                ValueRow(label = "Token length", value = "${creds.deviceToken.length} chars", last = true)
            }

            SectionShell(title = "WireGuard mesh") {
                ValueRow(label = "State", value = meshState.toString(), last = creds.meshUrl == null && creds.meshAssignedIp == null)
                creds.meshUrl?.let {
                    ValueRow(label = "Peer", value = it, mono = true, last = creds.meshAssignedIp == null)
                }
                creds.meshAssignedIp?.let { ValueRow(label = "Address", value = it, mono = true, last = true) }
            }

            SectionShell(title = "Build") {
                ValueRow(label = "Core version", value = uniffi.papercup.version(), mono = true, last = false)
                ValueRow(label = "Android", value = "${Build.VERSION.RELEASE} (sdk ${Build.VERSION.SDK_INT})", last = false)
                ValueRow(label = "Device", value = "${Build.MANUFACTURER} ${Build.MODEL}", last = true)
            }

            SectionShell(title = "Push") {
                val pushLabel = when {
                    fcmToken != null -> "registered"
                    fcmError != null -> "error: ${fcmError}"
                    else -> "fetching…"
                }
                ValueRow(label = "FCM status", value = pushLabel, last = false)
                fcmToken?.let {
                    ValueRow(label = "FCM token (first 12)", value = it.take(12) + "…", mono = true, last = false)
                }
                ActionRow(
                    title = "Push tap test",
                    subtitle = "Simulate tapped notification routes without APNs / FCM delivery.",
                    onClick = onOpenPushTapTest,
                    last = true,
                )
            }
            Spacer(Modifier.height(12.dp))
        }
    }
}

@Composable
private fun SectionShell(
    title: String,
    content: @Composable ColumnScope.() -> Unit,
) {
    PapercupCard(
        modifier = Modifier.fillMaxWidth(),
        contentPadding = PaddingValues(0.dp),
    ) {
        Column {
            Text(
                text = title.uppercase(),
                modifier = Modifier.padding(horizontal = 16.dp, vertical = 12.dp),
                style = MaterialTheme.typography.labelSmall,
                color = PapercupColors.TextMuted,
            )
            HorizontalDivider(color = PapercupColors.StrokeSoft)
            Column(content = content)
        }
    }
}

@Composable
private fun ValueRow(
    label: String,
    value: String,
    mono: Boolean = false,
    last: Boolean = false,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 12.dp),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.Top,
    ) {
        Text(
            text = label,
            modifier = Modifier.weight(1f),
            style = MaterialTheme.typography.bodySmall,
            color = PapercupColors.TextMuted,
        )
        Text(
            text = value,
            style = MaterialTheme.typography.bodyMedium,
            color = PapercupColors.Text,
            fontFamily = if (mono) FontFamily.Monospace else FontFamily.Default,
        )
    }
    if (!last) {
        HorizontalDivider(color = PapercupColors.StrokeSoft.copy(alpha = 0.55f))
    }
}

@Composable
private fun ActionRow(
    title: String,
    subtitle: String,
    onClick: () -> Unit,
    last: Boolean = false,
) {
    TextButton(
        onClick = onClick,
        modifier = Modifier.fillMaxWidth(),
        contentPadding = PaddingValues(0.dp),
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp, vertical = 12.dp),
            horizontalAlignment = Alignment.Start,
            verticalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            Text(
                text = title,
                style = MaterialTheme.typography.bodyMedium,
                color = PapercupColors.Text,
            )
            Text(
                text = subtitle,
                style = MaterialTheme.typography.bodySmall,
                color = PapercupColors.TextMuted,
            )
        }
    }
    if (!last) {
        HorizontalDivider(color = PapercupColors.StrokeSoft.copy(alpha = 0.55f))
    }
}

@Composable
private fun StatusPill(status: ConnStatus) {
    val (label, container, content) = when (status) {
        ConnStatus.Online -> Triple("ONLINE", PapercupColors.SuccessSoft, PapercupColors.Success)
        ConnStatus.Offline -> Triple("OFFLINE", PapercupColors.ErrorSoft, PapercupColors.Error)
        ConnStatus.Unknown -> Triple("UNKNOWN", PapercupColors.WarningSoft, PapercupColors.Warning)
    }
    PapercupStatusChip(
        text = label,
        containerColor = container,
        contentColor = content,
        modifier = Modifier.semantics { contentDescription = "Status ${label.lowercase()}" },
    )
}

private fun formatTimestamp(epochMs: Long): String =
    DateFormat.getDateTimeInstance(DateFormat.MEDIUM, DateFormat.SHORT).format(Date(epochMs))
