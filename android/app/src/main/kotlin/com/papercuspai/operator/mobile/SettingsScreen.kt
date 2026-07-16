// SPDX-License-Identifier: GPL-3.0-or-later
package com.papercuspai.operator.mobile

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import com.papercuspai.operator.mobile.theme.PapercupCard
import com.papercuspai.operator.mobile.theme.PapercupColors
import com.papercuspai.operator.mobile.theme.PapercupMetaText
import com.papercuspai.operator.mobile.theme.PapercupScreenHeader
import com.papercuspai.operator.mobile.theme.PapercupStatusChip
import kotlinx.coroutines.launch
import uniffi.papercup.ApiException
import uniffi.papercup.Device
import uniffi.papercup.OperatorClient


@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen(
    creds: DeviceCredentials,
    onForget: () -> Unit,
    onOpenWorkspaceSelector: () -> Unit = {},
    onOpenStandingApprovals: () -> Unit = {},
    onOpenVoiceSettings: () -> Unit = {},
    onOpenDiagnostics: () -> Unit = {},
) {
    val activity = androidx.compose.ui.platform.LocalContext.current.let { ctx ->
        var c: android.content.Context = ctx
        while (c is android.content.ContextWrapper && c !is androidx.fragment.app.FragmentActivity) {
            c = c.baseContext
        }
        c as? androidx.fragment.app.FragmentActivity
    }
    val gatedClient: () -> OperatorClient = {
        creds.client().also { client ->
            activity?.let { client.setBiometricPrompt(BiometricGate(it)) }
        }
    }
    var devices by remember { mutableStateOf<List<Device>?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    var busyKey by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()

    suspend fun load() {
        try {
            devices = creds.client().listDesktopDevices()
            error = null
        } catch (e: ApiException) {
            error = HumanError.describe(e, "Loading paired devices")
        } catch (t: Throwable) {
            error = HumanError.describe(t, "Loading paired devices")
        }
    }

    LaunchedEffect(creds.deviceToken) { load() }

    val selfDevice = devices?.firstOrNull { it.deviceId == creds.deviceId }

    Scaffold(
        topBar = {
            PapercupScreenHeader(
                title = stringResource(R.string.settings_title),
                subtitle = creds.workspaceId,
            )
        },
        containerColor = PapercupColors.Ink,
    ) { padding ->
        LazyColumn(
            modifier = Modifier
                .fillMaxSize()
                .background(PapercupColors.ScreenGradient)
                .padding(padding)
                .padding(horizontal = 16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
            contentPadding = PaddingValues(vertical = 12.dp),
        ) {
            error?.let {
                item {
                    PapercupCard(accent = PapercupColors.ErrorSoft) {
                        Text(
                            text = it,
                            color = PapercupColors.Error,
                            style = MaterialTheme.typography.bodySmall,
                            fontFamily = FontFamily.Monospace,
                        )
                    }
                }
            }

            item {
                SectionShell(title = "Pairing") {
                    ValueRow(label = "Desktop", value = creds.server)
                    selfDevice?.pairedAt?.let { ValueRow(label = "Paired", value = it) }
                    ValueRow(label = "Workspace", value = creds.workspaceId)
                    ValueRow(label = "Device ID", value = creds.deviceId, mono = true, last = creds.defguardEnrollmentUrl == null)
                    creds.defguardEnrollmentUrl?.let { ValueRow(label = "Mesh", value = "Defguard enrolled", last = true) }
                }
            }

            item {
                SectionShell(title = "Connection") {
                    ActionRow(
                        title = "Workspace selector",
                        subtitle = "Current claim · ${creds.workspaceId}",
                        onClick = onOpenWorkspaceSelector,
                        last = true,
                    )
                }
            }

            item {
                SectionShell(title = "Voice") {
                    ActionRow(
                        title = "Voice settings",
                        subtitle = stringResource(R.string.settings_voice_subtitle),
                        onClick = onOpenVoiceSettings,
                        last = false,
                    )
                    ValueRow(label = "STT / TTS", value = "Android local speech", last = false)
                    ValueRow(label = "Audio routing", value = "Phone speaker", last = true)
                }
            }

            item {
                SectionShell(title = "About") {
                    ValueRow(label = "Version", value = uniffi.papercup.version(), mono = true, last = false)
                    ActionRow(
                        title = stringResource(R.string.settings_diagnostics),
                        subtitle = stringResource(R.string.settings_diagnostics_subtitle),
                        onClick = onOpenDiagnostics,
                        last = true,
                    )
                }
            }

            item {
                SectionShell(title = "Paired devices", meta = devices?.size?.toString()) {
                    when (val dv = devices) {
                        null -> LoadingRow(last = true)
                        else -> dv.forEachIndexed { index, device ->
                            DeviceRow(
                                device = device,
                                isSelf = device.deviceId == creds.deviceId,
                                revoking = busyKey == device.deviceId,
                                isLast = index == dv.lastIndex,
                                onRevoke = if (device.deviceId == creds.deviceId) {
                                    null
                                } else {
                                    {
                                        scope.launch {
                                            busyKey = device.deviceId
                                            try {
                                                gatedClient().revokeDevice(device.deviceId)
                                                load()
                                            } catch (t: Throwable) {
                                                error = "Revoke failed: ${t.message}"
                                            } finally {
                                                busyKey = null
                                            }
                                        }
                                    }
                                },
                            )
                        }
                    }
                }
            }

            item {
                SectionShell(title = "Actions") {
                    ActionRow(
                        title = stringResource(R.string.settings_standing_approvals),
                        subtitle = stringResource(R.string.settings_standing_approvals_subtitle),
                        onClick = onOpenStandingApprovals,
                        last = false,
                    )
                    ActionRow(
                        title = stringResource(R.string.settings_forget_device),
                        subtitle = "Remove this phone from the paired desktop",
                        onClick = onForget,
                        danger = true,
                        trailing = null,
                        last = true,
                    )
                }
            }
        }
    }
}

@Composable
private fun SectionShell(
    title: String,
    meta: String? = null,
    content: @Composable ColumnScope.() -> Unit,
) {
    PapercupCard(
        modifier = Modifier.fillMaxWidth(),
        contentPadding = PaddingValues(0.dp),
    ) {
        Column {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp, vertical = 12.dp),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    text = title.uppercase(),
                    style = MaterialTheme.typography.labelSmall,
                    color = PapercupColors.TextMuted,
                )
                meta?.let {
                    PapercupStatusChip(
                        text = it,
                        containerColor = PapercupColors.WarningSoft,
                        contentColor = PapercupColors.Warning,
                    )
                }
            }
            HorizontalDivider(color = PapercupColors.StrokeSoft)
            Column(content = content)
        }
    }
}

@Composable
private fun LoadingRow(last: Boolean) {
    ValueRow(label = "Status", value = stringResource(R.string.loading), last = last)
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
    onClick: (() -> Unit)? = null,
    enabled: Boolean = true,
    danger: Boolean = false,
    trailing: String? = "›",
    last: Boolean = false,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .then(
                if (onClick != null) {
                    Modifier.clickable(enabled = enabled, onClick = onClick)
                } else {
                    Modifier
                }
            )
            .semantics(mergeDescendants = true) {
                contentDescription = listOf(title, subtitle).joinToString(". ")
                if (onClick != null) role = androidx.compose.ui.semantics.Role.Button
            }
            .padding(horizontal = 16.dp, vertical = 14.dp),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(
                text = title,
                style = MaterialTheme.typography.bodyMedium,
                color = if (danger) PapercupColors.Error else PapercupColors.Text,
            )
            PapercupMetaText(text = subtitle)
        }
        trailing?.let {
            Text(
                text = it,
                style = MaterialTheme.typography.titleMedium,
                color = if (danger) PapercupColors.Error else PapercupColors.TextMuted,
            )
        }
    }
    if (!last) {
        HorizontalDivider(color = PapercupColors.StrokeSoft.copy(alpha = 0.55f))
    }
}



@Composable
private fun DeviceRow(
    device: Device,
    isSelf: Boolean,
    revoking: Boolean,
    isLast: Boolean,
    onRevoke: (() -> Unit)?,
) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 12.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                text = device.deviceLabel ?: device.deviceId.take(12),
                style = MaterialTheme.typography.bodyMedium,
                color = PapercupColors.Text,
            )
            if (isSelf) {
                PapercupStatusChip(
                    text = stringResource(R.string.this_device),
                    containerColor = PapercupColors.InfoSoft,
                    contentColor = PapercupColors.Info,
                )
            }
        }
        PapercupMetaText(text = device.deviceId, monospace = true)
        PapercupMetaText(text = "workspace · ${device.workspaceId}")
        device.pairedAt?.let { PapercupMetaText(text = "paired · $it") }
        device.lastSeen?.let { PapercupMetaText(text = "last seen · $it") }
        if (onRevoke != null) {
            TextButton(
                onClick = onRevoke,
                enabled = !revoking,
                contentPadding = PaddingValues(0.dp),
            ) {
                Text(
                    text = if (revoking) "Revoking…" else stringResource(R.string.settings_revoke),
                    color = PapercupColors.Error,
                )
            }
        }
    }
    if (!isLast) {
        HorizontalDivider(color = PapercupColors.StrokeSoft.copy(alpha = 0.55f))
    }
}
