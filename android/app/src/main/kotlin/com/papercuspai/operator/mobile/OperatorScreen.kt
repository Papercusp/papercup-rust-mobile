// SPDX-License-Identifier: GPL-3.0-or-later
package com.papercuspai.operator.mobile

import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp

/// Landing/home surface — Tauri parity stub. Iteration 1 just shows
/// identity + pause status; real content (recent runs, voice status,
/// quick actions) lands in subsequent commits.
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun OperatorScreen(
    creds: DeviceCredentials,
    voice: VoiceManager,
    liveTick: Int,
) {
    Scaffold(
        topBar = {
            TopAppBar(
                title = {
                    Column {
                        Text("Operator", style = MaterialTheme.typography.titleLarge)
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
            modifier = Modifier.fillMaxSize().padding(padding).padding(horizontal = 16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Spacer(Modifier.height(12.dp))
            Card(modifier = Modifier.fillMaxWidth()) {
                Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Text("This device", style = MaterialTheme.typography.titleSmall)
                    KvLine("workspace", creds.workspaceId)
                    KvLine("device", creds.deviceId.take(12) + "…")
                    creds.meshAssignedIp?.let { KvLine("mesh", it) }
                }
            }
            Card(modifier = Modifier.fillMaxWidth()) {
                Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text("Coming soon", style = MaterialTheme.typography.titleSmall)
                    Text(
                        "Live run summary, voice lease state, quick actions, and " +
                            "recent activity preview will land here.",
                        style = MaterialTheme.typography.bodySmall,
                    )
                }
            }
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
