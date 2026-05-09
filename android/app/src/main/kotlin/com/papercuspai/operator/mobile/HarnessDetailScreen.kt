// SPDX-License-Identifier: GPL-3.0-or-later
package com.papercuspai.operator.mobile

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
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
                .padding(16.dp)
                .verticalScroll(rememberScrollState()),
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
                is DetailState.Ready -> StatusCards(s.status)
            }
        }
    }
}

@Composable
private fun StatusCards(s: HarnessStatus) {
    HeaderCard(s)
    MissionCard(s)
    if (s.counts.isNotEmpty()) FeaturesCard(s)
    s.lastDecision?.takeIf { it.isNotBlank() }?.let { LastDecisionCard(it) }
}

@Composable
private fun HeaderCard(s: HarnessStatus) {
    Card(modifier = Modifier.fillMaxWidth()) {
        Column(Modifier.padding(16.dp)) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(s.slug, style = MaterialTheme.typography.titleLarge)
                StatusChips(s)
            }
            if (s.path.isNotBlank()) {
                Spacer(Modifier.height(4.dp))
                Text(
                    s.path,
                    style = MaterialTheme.typography.bodySmall,
                    fontFamily = FontFamily.Monospace,
                )
            }
            Spacer(Modifier.height(8.dp))
            KeyValue("iteration", s.iteration.toString())
            KeyValue("features", s.featureCount.toString())
            KeyValue("pending checkpoints", s.pendingCheckpoints.toString())
            if (s.activeCompetitions > 0) {
                KeyValue("active competitions", s.activeCompetitions.toString())
            }
        }
    }
}

@Composable
private fun StatusChips(s: HarnessStatus) {
    Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
        AssistChip(onClick = {}, label = { Text(if (s.alive) "alive" else "idle") })
        if (s.escalated) {
            AssistChip(
                onClick = {},
                label = { Text("escalated") },
                colors = AssistChipDefaults.assistChipColors(
                    containerColor = MaterialTheme.colorScheme.errorContainer,
                ),
            )
        }
        if (s.smokeFail) {
            AssistChip(
                onClick = {},
                label = { Text("smoke fail") },
                colors = AssistChipDefaults.assistChipColors(
                    containerColor = MaterialTheme.colorScheme.errorContainer,
                ),
            )
        }
    }
}

@Composable
private fun MissionCard(s: HarnessStatus) {
    Card(modifier = Modifier.fillMaxWidth()) {
        Column(Modifier.padding(16.dp)) {
            Text("Mission", style = MaterialTheme.typography.titleSmall)
            Spacer(Modifier.height(8.dp))
            KeyValue("cost", String.format("$%.4f", s.missionCostUsd))
            KeyValue("input tokens", "%,d".format(s.missionInputTokens))
            KeyValue("output tokens", "%,d".format(s.missionOutputTokens))
        }
    }
}

@Composable
private fun FeaturesCard(s: HarnessStatus) {
    Card(modifier = Modifier.fillMaxWidth()) {
        Column(Modifier.padding(16.dp)) {
            Text("Features by status", style = MaterialTheme.typography.titleSmall)
            Spacer(Modifier.height(8.dp))
            s.counts.entries.sortedByDescending { it.value }.forEach { (k, v) ->
                KeyValue(k, v.toString())
            }
        }
    }
}

@Composable
private fun LastDecisionCard(text: String) {
    Card(modifier = Modifier.fillMaxWidth()) {
        Column(Modifier.padding(16.dp)) {
            Text("Last decision", style = MaterialTheme.typography.titleSmall)
            Spacer(Modifier.height(8.dp))
            Text(text, style = MaterialTheme.typography.bodySmall)
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
