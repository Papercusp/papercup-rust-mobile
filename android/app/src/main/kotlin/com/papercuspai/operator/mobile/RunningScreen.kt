// SPDX-License-Identifier: GPL-3.0-or-later
package com.papercuspai.operator.mobile

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import com.papercuspai.operator.mobile.theme.PapercupCard
import com.papercuspai.operator.mobile.theme.PapercupColors
import com.papercuspai.operator.mobile.theme.PapercupMetaText
import com.papercuspai.operator.mobile.theme.PapercupPanel
import com.papercuspai.operator.mobile.theme.PapercupScreenHeader
import com.papercuspai.operator.mobile.theme.PapercupStatusChip
import uniffi.papercup.ApiException
import uniffi.papercup.Running

private sealed interface RunningState {
    data object Loading : RunningState
    data class Ready(val running: List<Running>) : RunningState
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
            RunningState.Ready(creds.client().listRunning())
        } catch (e: ApiException) {
            RunningState.Failed("API: ${e::class.simpleName}: ${e.message ?: "no detail"}")
        } catch (t: Throwable) {
            RunningState.Failed("Unexpected: ${t::class.simpleName}: ${t.message ?: "no detail"}")
        }
    }

    Scaffold(
        topBar = {
            PapercupScreenHeader(
                title = "Now running",
                subtitle = if (state is RunningState.Loading) "Loading…" else null,
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
            contentPadding = PaddingValues(top = 12.dp, bottom = 96.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            item {
                SectionLabel("Operator")
                PapercupPanel(contentPadding = PaddingValues(16.dp)) {
                    PapercupMetaText("No active scan.")
                }
            }

            when (val s = state) {
                RunningState.Loading -> item {
                    Box(Modifier.fillMaxWidth().padding(top = 16.dp), contentAlignment = Alignment.Center) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            CircularProgressIndicator(strokeWidth = 2.dp)
                            Spacer(Modifier.width(12.dp))
                            Text("Loading…", style = MaterialTheme.typography.bodySmall)
                        }
                    }
                }
                is RunningState.Failed -> item {
                    PapercupCard(accent = PapercupColors.ErrorSoft) {
                        Text(
                            s.message,
                            color = PapercupColors.Error,
                            fontFamily = FontFamily.Monospace,
                            style = MaterialTheme.typography.bodySmall,
                        )
                    }
                }
                is RunningState.Ready -> {
                    item { SectionLabel("Harnesses (${s.running.size})") }
                    if (s.running.isEmpty()) {
                        item {
                            PapercupPanel(contentPadding = PaddingValues(16.dp)) {
                                PapercupMetaText("No harnesses currently running.")
                            }
                        }
                    } else {
                        items(s.running) { running ->
                            RunningHarnessRow(running, onClick = { onSelectHarness(running.harnessSlug) })
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun SectionLabel(text: String) {
    Text(
        text = text.uppercase(),
        modifier = Modifier.padding(bottom = 8.dp),
        style = MaterialTheme.typography.labelSmall,
        color = PapercupColors.TextFaint,
    )
}

@Composable
private fun RunningHarnessRow(running: Running, onClick: () -> Unit) {
    val total = running.passedCount + running.todoCount + running.blockedCount
    val passedPct = if (total > 0) running.passedCount.toFloat() / total.toFloat() else 0f

    PapercupPanel(
        modifier = Modifier.clickable(onClick = onClick),
        contentPadding = PaddingValues(12.dp),
    ) {
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(running.harnessSlug, style = MaterialTheme.typography.titleSmall)
                PapercupMetaText(running.phase.uppercase())
            }
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
                Text(running.status, color = PapercupColors.AccentStrong, style = MaterialTheme.typography.labelSmall)
                PapercupMetaText("iter ${running.iteration}")
                PapercupMetaText("${running.passedCount}/$total done")
                if (running.blockedCount > 0) {
                    PapercupMetaText("${running.blockedCount} blocked", modifier = Modifier.weight(1f))
                }
            }
            Box(
                Modifier
                    .fillMaxWidth()
                    .height(6.dp)
                    .clip(RoundedCornerShape(999.dp))
                    .background(PapercupColors.InkRaised),
            ) {
                Box(
                    Modifier
                        .fillMaxWidth(passedPct)
                        .height(6.dp)
                        .background(
                            Brush.horizontalGradient(
                                listOf(PapercupColors.Teal, PapercupColors.Accent, PapercupColors.Gold),
                            ),
                        ),
                )
            }
            if (running.activeRoles.isNotEmpty()) {
                Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                    running.activeRoles.forEach { role ->
                        PapercupStatusChip(
                            text = role,
                            containerColor = Color(0x1F94A3B8),
                            contentColor = PapercupColors.TextMuted,
                            borderColor = PapercupColors.StrokeSoft,
                        )
                    }
                }
            }
        }
    }
}
