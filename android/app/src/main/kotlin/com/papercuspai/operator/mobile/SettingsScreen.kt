// SPDX-License-Identifier: GPL-3.0-or-later
package com.papercuspai.operator.mobile

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.*
import com.papercuspai.operator.mobile.theme.PapercupCardHeader
import com.papercuspai.operator.mobile.theme.PapercupCard
import com.papercuspai.operator.mobile.theme.PapercupColors
import com.papercuspai.operator.mobile.theme.PapercupMetaText
import com.papercuspai.operator.mobile.theme.PapercupPanel
import com.papercuspai.operator.mobile.theme.PapercupStatusChip
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch
import uniffi.papercup.ApiException
import uniffi.papercup.Device
import uniffi.papercup.OperatorClient
import uniffi.papercup.Workspace

/// Catch-all 'Settings' page reachable from the overflow menu. Surfaces
/// the things that don't earn dedicated nav: workspaces, paired devices,
/// device + mesh + server identity.
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen(
    creds: DeviceCredentials,
    onForget: () -> Unit,
) {
    var workspaces by remember { mutableStateOf<List<Workspace>?>(null) }
    var devices by remember { mutableStateOf<List<Device>?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    var revoking by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()

    suspend fun load() {
        try {
            val client = OperatorClient(creds.server, creds.deviceToken)
            workspaces = client.listWorkspaces()
            devices = client.listDesktopDevices()
            error = null
        } catch (e: ApiException) {
            error = "API: ${e::class.simpleName}: ${e.message ?: ""}"
        } catch (t: Throwable) {
            error = "Unexpected: ${t::class.simpleName}: ${t.message ?: ""}"
        }
    }

    LaunchedEffect(creds.deviceToken) { load() }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Settings") },
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = PapercupColors.InkRaised,
                    titleContentColor = PapercupColors.Text,
                    navigationIconContentColor = PapercupColors.Text,
                ),
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
                            it,
                            color = PapercupColors.Error,
                            fontFamily = FontFamily.Monospace,
                            style = MaterialTheme.typography.bodySmall,
                        )
                    }
                }
            }

            item {
                IdentityCard(creds)
            }

            item {
                PapercupCardHeader("Workspaces", meta = workspaces?.size?.toString())
            }
            val ws = workspaces
            if (ws == null) {
                item { PapercupMetaText("Loading…") }
            } else {
                items(ws) { w -> WorkspaceRow(w) }
            }

            item {
                Spacer(Modifier.height(4.dp))
                PapercupCardHeader("Paired devices", meta = devices?.size?.toString())
            }
            val dv = devices
            if (dv == null) {
                item { PapercupMetaText("Loading…") }
            } else {
                items(dv) { d ->
                    DeviceRowCard(
                        device = d,
                        isSelf = d.deviceId == creds.deviceId,
                        revoking = revoking == d.deviceId,
                        onRevoke = {
                            scope.launch {
                                revoking = d.deviceId
                                try {
                                    OperatorClient(creds.server, creds.deviceToken)
                                        .revokeDevice(d.deviceId)
                                    load()
                                } catch (t: Throwable) {
                                    error = "Revoke failed: ${t.message}"
                                } finally {
                                    revoking = null
                                }
                            }
                        },
                    )
                }
            }

            item {
                Spacer(Modifier.height(8.dp))
                Button(
                    onClick = onForget,
                    modifier = Modifier.fillMaxWidth(),
                    colors = ButtonDefaults.buttonColors(
                        containerColor = MaterialTheme.colorScheme.error,
                    ),
                ) { Text("Forget this device") }
            }
        }
    }
}

@Composable
private fun IdentityCard(creds: DeviceCredentials) {
    PapercupCard(modifier = Modifier.fillMaxWidth(), contentPadding = PaddingValues(16.dp)) {
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            PapercupCardHeader("This device", meta = creds.workspaceId)
            Kv("server", creds.server)
            Kv("device id", creds.deviceId)
            Kv("workspace id", creds.workspaceId)
            creds.meshAssignedIp?.let { Kv("mesh address", it) }
        }
    }
}

@Composable
private fun WorkspaceRow(w: Workspace) {
    PapercupPanel(modifier = Modifier.fillMaxWidth(), contentPadding = PaddingValues(12.dp)) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(w.name, style = MaterialTheme.typography.titleSmall)
                Text(w.id, style = MaterialTheme.typography.labelSmall, fontFamily = FontFamily.Monospace)
            }
            if (w.current) {
                PapercupStatusChip(text = "current", containerColor = PapercupColors.SuccessSoft, contentColor = PapercupColors.Success)
            }
        }
    }
}

@Composable
private fun DeviceRowCard(device: Device, isSelf: Boolean, revoking: Boolean, onRevoke: () -> Unit) {
    PapercupPanel(modifier = Modifier.fillMaxWidth(), contentPadding = PaddingValues(12.dp)) {
        Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    device.deviceLabel ?: device.deviceId.take(12),
                    style = MaterialTheme.typography.titleSmall,
                )
                if (isSelf) PapercupStatusChip(text = "this phone", containerColor = PapercupColors.InfoSoft, contentColor = PapercupColors.Info)
            }
            device.lastSeen?.let { Kv("last seen", it) }
            device.pairedAt?.let { Kv("paired at", it) }
            Kv("workspace", device.workspaceId)
            if (!isSelf) {
                TextButton(onClick = onRevoke, enabled = !revoking) {
                    Text(if (revoking) "Revoking…" else "Revoke")
                }
            }
        }
    }
}

@Composable
private fun Kv(key: String, value: String) {
    Row(
        modifier = Modifier.fillMaxWidth().padding(vertical = 1.dp),
        horizontalArrangement = Arrangement.SpaceBetween,
    ) {
        PapercupMetaText(key)
        PapercupMetaText(value, monospace = true)
    }
}
