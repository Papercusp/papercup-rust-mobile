// SPDX-License-Identifier: GPL-3.0-or-later
package com.papercuspai.operator.mobile

import androidx.compose.foundation.layout.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import uniffi.papercup.ApiException
import uniffi.papercup.HarnessStatus
import uniffi.papercup.OperatorClient

private sealed interface DetailState {
    data object Loading : DetailState
    data class Ready(val status: HarnessStatus) : DetailState
    data class Failed(val message: String) : DetailState
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun HarnessDetailScreen(
    creds: DeviceCredentials,
    slug: String,
    invalidationTick: Int,
    onBack: () -> Unit,
) {
    var state by remember { mutableStateOf<DetailState>(DetailState.Loading) }

    LaunchedEffect(slug, invalidationTick) {
        state = DetailState.Loading
        state = try {
            val client = OperatorClient(creds.server, creds.deviceToken)
            DetailState.Ready(client.getHarnessStatus(slug))
        } catch (e: ApiException) {
            DetailState.Failed("API: ${e::class.simpleName}: ${e.message ?: "no detail"}")
        } catch (t: Throwable) {
            DetailState.Failed("Unexpected: ${t::class.simpleName}: ${t.message ?: "no detail"}")
        }
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(slug, style = MaterialTheme.typography.titleLarge) },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
                    }
                },
            )
        },
    ) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            when (val s = state) {
                DetailState.Loading -> {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        CircularProgressIndicator(strokeWidth = 2.dp, modifier = Modifier.size(16.dp))
                        Spacer(Modifier.width(12.dp))
                        Text("Loading status…")
                    }
                }
                is DetailState.Failed -> {
                    Card(
                        colors = CardDefaults.cardColors(
                            containerColor = MaterialTheme.colorScheme.errorContainer,
                        ),
                    ) {
                        Text(
                            s.message,
                            modifier = Modifier.padding(16.dp),
                            color = MaterialTheme.colorScheme.onErrorContainer,
                            fontFamily = FontFamily.Monospace,
                            style = MaterialTheme.typography.bodySmall,
                        )
                    }
                }
                is DetailState.Ready -> {
                    StatusCard(s.status)
                    // Backend-extension placeholder. The mobile endpoint
                    // currently returns only slug/status/iteration/
                    // last_active_ts. Fields below light up once backend
                    // folds the desktop StatusResp shape into mobile.
                    Card {
                        Column(Modifier.padding(16.dp)) {
                            Text(
                                "More detail coming",
                                style = MaterialTheme.typography.titleSmall,
                            )
                            Spacer(Modifier.height(4.dp))
                            Text(
                                "Cost / tokens / last decision / pending checkpoints / smoke / " +
                                    "alive — pending a backend update to /api/mobile/harnesses/:slug.",
                                style = MaterialTheme.typography.bodySmall,
                            )
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun StatusCard(s: HarnessStatus) {
    Card(modifier = Modifier.fillMaxWidth()) {
        Column(Modifier.padding(16.dp)) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(s.slug, style = MaterialTheme.typography.titleLarge)
                AssistChip(onClick = {}, label = { Text(s.status) })
            }
            Spacer(Modifier.height(8.dp))
            KeyValue("iteration", s.iteration.toString())
            s.lastActiveTs?.let {
                val fmt = SimpleDateFormat("yyyy-MM-dd HH:mm:ss", Locale.US)
                KeyValue("last active", fmt.format(Date(it * 1000)))
            }
        }
    }
}

@Composable
private fun KeyValue(key: String, value: String) {
    Row(
        modifier = Modifier.fillMaxWidth().padding(vertical = 2.dp),
        horizontalArrangement = Arrangement.SpaceBetween,
    ) {
        Text(key, style = MaterialTheme.typography.bodySmall)
        Text(
            value,
            style = MaterialTheme.typography.bodySmall,
            fontFamily = FontFamily.Monospace,
        )
    }
}
