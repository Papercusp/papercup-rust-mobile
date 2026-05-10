// SPDX-License-Identifier: GPL-3.0-or-later
package com.papercuspai.operator.mobile

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.*
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
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = PapercupColors.InkRaised,
                    titleContentColor = PapercupColors.Text,
                    navigationIconContentColor = PapercupColors.Text,
                ),
            )
        },
        containerColor = PapercupColors.Ink,
    ) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .background(PapercupColors.ScreenGradient)
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
                    PapercupCard(accent = PapercupColors.ErrorSoft) {
                        Text(
                            s.message,
                            color = PapercupColors.Error,
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
    PapercupCard(modifier = Modifier.fillMaxWidth()) {
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
                PapercupMetaText(s.path, monospace = true)
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
        PapercupStatusChip(
            text = if (s.alive) "alive" else "idle",
            containerColor = if (s.alive) PapercupColors.SuccessSoft else PapercupColors.InfoSoft,
            contentColor = if (s.alive) PapercupColors.Success else PapercupColors.Info,
        )
        if (s.escalated) {
            PapercupStatusChip(
                text = "escalated",
                containerColor = PapercupColors.ErrorSoft,
                contentColor = PapercupColors.Error,
            )
        }
        if (s.smokeFail) {
            PapercupStatusChip(
                text = "smoke fail",
                containerColor = PapercupColors.ErrorSoft,
                contentColor = PapercupColors.Error,
            )
        }
    }
}

@Composable
private fun MissionCard(s: HarnessStatus) {
    PapercupPanel(modifier = Modifier.fillMaxWidth()) {
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
    PapercupPanel(modifier = Modifier.fillMaxWidth()) {
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
    PapercupPanel(modifier = Modifier.fillMaxWidth()) {
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
        PapercupMetaText(key)
        PapercupMetaText(value, monospace = true)
    }
}
