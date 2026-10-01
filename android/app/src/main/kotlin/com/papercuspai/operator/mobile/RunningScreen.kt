// SPDX-License-Identifier: GPL-3.0-or-later
package com.papercuspai.operator.mobile

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.papercuspai.operator.mobile.theme.PapercupCard
import com.papercuspai.operator.mobile.theme.PapercupColors
import com.papercuspai.operator.mobile.theme.PapercupMetaText
import com.papercuspai.operator.mobile.theme.PapercupScreenHeader
import kotlinx.coroutines.CancellationException
import uniffi.papercup.FleetActivitySummary

private sealed interface RunningState {
    data object Loading : RunningState
    data class Ready(val activity: FleetActivitySummary?) : RunningState
    data class Failed(val message: String) : RunningState
}

@Composable
fun RunningScreen(
    creds: DeviceCredentials,
    liveTick: Int,
    onSelectHarness: (String) -> Unit,
) {
    var state by remember { mutableStateOf<RunningState>(RunningState.Loading) }
    LaunchedEffect(creds.deviceToken, liveTick) {
        state = RunningState.Loading
        state = try {
            RunningState.Ready(creds.client().fleetActivity())
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Throwable) {
            RunningState.Failed(HumanError.describe(error, "Loading fleet activity"))
        }
    }

    Scaffold(
        topBar = { PapercupScreenHeader(title = "Fleet activity") },
        containerColor = PapercupColors.Ink,
    ) { padding ->
        LazyColumn(
            modifier = Modifier.fillMaxSize().background(PapercupColors.ScreenGradient)
                .padding(padding).padding(horizontal = 16.dp),
            contentPadding = PaddingValues(top = 12.dp, bottom = 96.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            when (val current = state) {
                RunningState.Loading -> item {
                    Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
                        CircularProgressIndicator()
                    }
                }
                is RunningState.Failed -> item {
                    PapercupCard(accent = PapercupColors.ErrorSoft) {
                        Text(current.message, color = PapercupColors.Error)
                    }
                }
                is RunningState.Ready -> {
                    val activity = current.activity
                    item {
                        PapercupCard {
                            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                                Text(fleetAvailabilityText(activity), style = MaterialTheme.typography.titleMedium)
                                if (activity != null) {
                                    PapercupMetaText("Availability means recently connected; agents may be idle.")
                                }
                            }
                        }
                    }
                    if (activity != null) {
                        item { Text("Fleets", style = MaterialTheme.typography.titleMedium) }
                        if (activity.fleets.isEmpty()) {
                            item { PapercupMetaText("No fleet presence reported.") }
                        }
                        items(activity.fleets, key = { it.slug }) { fleet ->
                            PapercupCard {
                                Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                                    Text(fleet.slug, style = MaterialTheme.typography.titleMedium)
                                    PapercupMetaText("${fleet.availableAgents} available · ${fleet.members} members")
                                    fleet.leader?.let { PapercupMetaText("Leader: $it") }
                                }
                            }
                        }
                        item { Text("Pots", style = MaterialTheme.typography.titleMedium) }
                        if (activity.pots.isEmpty()) {
                            item { PapercupMetaText("No pot presence reported.") }
                        }
                        items(activity.pots, key = { it.slug }) { pot ->
                            PapercupCard(modifier = Modifier.clickable { onSelectHarness(pot.slug) }) {
                                Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                                    Text(pot.slug, style = MaterialTheme.typography.titleMedium)
                                    PapercupMetaText("${pot.availableAgents} available · ${pot.agents} agents")
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
