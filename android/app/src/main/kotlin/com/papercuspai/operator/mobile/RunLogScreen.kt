// SPDX-License-Identifier: GPL-3.0-or-later
package com.papercuspai.operator.mobile

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

/// Run log tail. Iteration 1 just shows a placeholder; the live SSE
/// stream from `/api/harness/{slug}/log/stream` lands in the next
/// commit (Phase 10c).
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun RunLogScreen(
    creds: DeviceCredentials,
    slug: String,
    onBack: () -> Unit,
) {
    Scaffold(
        topBar = {
            TopAppBar(
                title = {
                    Column {
                        Text("Run log", style = MaterialTheme.typography.titleLarge)
                        Text(slug, style = MaterialTheme.typography.bodySmall, fontFamily = FontFamily.Monospace)
                    }
                },
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
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Card {
                Text(
                    "Live log stream coming next commit. Will tail " +
                        "`/api/harness/$slug/log/stream` (SSE) plus a one-shot " +
                        "history fetch from `/api/harness/$slug/log/history`.",
                    style = MaterialTheme.typography.bodySmall,
                    modifier = Modifier.padding(16.dp),
                )
            }
        }
    }
}
