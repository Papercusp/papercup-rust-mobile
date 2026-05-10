// SPDX-License-Identifier: GPL-3.0-or-later
package com.papercuspai.operator.mobile

import android.os.Build
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun DiagnosticsScreen(
    creds: DeviceCredentials,
    monitor: ConnectionMonitor,
    onBack: () -> Unit,
) {
    val state by monitor.state.collectAsState()
    val scope = rememberCoroutineScope()
    var pinging by remember { mutableStateOf(false) }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Diagnostics") },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
                    }
                },
            )
        },
    ) { padding ->
        Column(
            modifier = Modifier.fillMaxSize().padding(padding).padding(16.dp).verticalScroll(rememberScrollState()),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Section("Connection") {
                Row(verticalAlignment = androidx.compose.ui.Alignment.CenterVertically) {
                    Text("Status", modifier = Modifier.weight(1f), style = MaterialTheme.typography.bodySmall)
                    StatusPill(state.status)
                }
                state.lastPingMs?.let { Kv("Last ping", "$it ms") }
                state.offlineSinceMs?.let { Kv("Offline since", java.util.Date(it).toString()) }
                Spacer(Modifier.height(8.dp))
                Button(
                    onClick = {
                        pinging = true
                        scope.launch { monitor.probe(); pinging = false }
                    },
                    enabled = !pinging,
                ) { Text(if (pinging) "Pinging…" else "Ping desktop") }
            }
            Section("Pairing") {
                Kv("Device ID", creds.deviceId, mono = true)
                Kv("Workspace", creds.workspaceId)
                Kv("Server", creds.server)
                Kv("Token (first 12)", creds.deviceToken.take(12) + "…", mono = true)
                Kv("Token length", "${creds.deviceToken.length} chars")
                creds.meshAssignedIp?.let { Kv("Mesh address", it) }
            }
            Section("Build") {
                Kv("Core version", uniffi.papercup.version())
                Kv("Android", "${Build.VERSION.RELEASE} (sdk ${Build.VERSION.SDK_INT})")
                Kv("Device", "${Build.MANUFACTURER} ${Build.MODEL}")
            }
        }
    }
}

@Composable
private fun Section(title: String, content: @Composable ColumnScope.() -> Unit) {
    Card(modifier = Modifier.fillMaxWidth()) {
        Column(modifier = Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Text(title, style = MaterialTheme.typography.titleSmall)
            content()
        }
    }
}

@Composable
private fun Kv(k: String, v: String, mono: Boolean = false) {
    Row {
        Text(k, modifier = Modifier.weight(1f), style = MaterialTheme.typography.bodySmall)
        Text(
            v,
            style = MaterialTheme.typography.bodySmall,
            fontFamily = if (mono) FontFamily.Monospace else null,
        )
    }
}

@Composable
private fun StatusPill(s: ConnStatus) {
    val (label, container) = when (s) {
        ConnStatus.Online -> "online" to MaterialTheme.colorScheme.primaryContainer
        ConnStatus.Offline -> "offline" to MaterialTheme.colorScheme.errorContainer
        ConnStatus.Unknown -> "unknown" to MaterialTheme.colorScheme.surfaceVariant
    }
    Surface(color = container, shape = MaterialTheme.shapes.small) {
        Text(label.uppercase(), style = MaterialTheme.typography.labelSmall, modifier = Modifier.padding(horizontal = 8.dp, vertical = 2.dp))
    }
}
