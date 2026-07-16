// SPDX-License-Identifier: GPL-3.0-or-later
package com.papercuspai.operator.mobile

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.papercuspai.operator.mobile.theme.PapercupCard
import com.papercuspai.operator.mobile.theme.PapercupCardHeader
import com.papercuspai.operator.mobile.theme.PapercupChipRow
import com.papercuspai.operator.mobile.theme.PapercupColors
import com.papercuspai.operator.mobile.theme.PapercupMetaText
import com.papercuspai.operator.mobile.theme.PapercupPanel
import com.papercuspai.operator.mobile.theme.PapercupScreenHeader
import com.papercuspai.operator.mobile.theme.PapercupSectionLabel
import com.papercuspai.operator.mobile.theme.PapercupStatusChip
import uniffi.papercup.ApiException
import uniffi.papercup.HarnessStatus
import kotlin.math.max

private sealed interface DetailState {
    data object Loading : DetailState
    data class Ready(val status: HarnessStatus) : DetailState
    data class Failed(val message: String) : DetailState
}

private data class CountBucket(
    val key: String,
    val count: Long,
    val containerColor: Color,
    val contentColor: Color,
)

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun HarnessDetailScreen(
    creds: DeviceCredentials,
    slug: String,
    invalidationTick: Int,
    onBack: () -> Unit,
    onOpenRunLog: (() -> Unit)? = null,
) {
    var state by remember { mutableStateOf<DetailState>(DetailState.Loading) }

    LaunchedEffect(slug, invalidationTick) {
        state = DetailState.Loading
        state = try {
            val client = creds.client()
            DetailState.Ready(client.getHarnessStatus(slug))
        } catch (e: ApiException) {
            DetailState.Failed(HumanError.describe(e, "Loading this harness"))
        } catch (t: Throwable) {
            DetailState.Failed(HumanError.describe(t, "Loading this harness"))
        }
    }

    Scaffold(
        topBar = {
            PapercupScreenHeader(
                title = slug,
                subtitle = "HARNESS DETAIL",
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
                    }
                },
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
                DetailState.Loading -> LoadingCard()
                is DetailState.Failed -> ErrorCard(s.message)
                is DetailState.Ready -> StatusCards(s.status, onOpenRunLog)
            }
        }
    }
}

@Composable
private fun LoadingCard() {
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .padding(top = 32.dp)
            .border(1.dp, PapercupColors.Stroke.copy(alpha = 0.55f), RoundedCornerShape(18.dp))
            .background(PapercupColors.InkRaised.copy(alpha = 0.92f), RoundedCornerShape(18.dp))
            .padding(18.dp),
        contentAlignment = Alignment.Center,
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            CircularProgressIndicator(strokeWidth = 2.dp, modifier = Modifier.size(16.dp))
            Spacer(Modifier.width(12.dp))
            Text(stringResource(R.string.loading_status))
        }
    }
}

@Composable
private fun ErrorCard(message: String) {
    PapercupCard(accent = PapercupColors.ErrorSoft) {
        Text(
            message,
            color = PapercupColors.Error,
            fontFamily = FontFamily.Monospace,
            style = MaterialTheme.typography.bodySmall,
        )
    }
}

@Composable
private fun StatusCards(s: HarnessStatus, onOpenRunLog: (() -> Unit)?) {
    OverviewCard(s, onOpenRunLog)
    MissionCard(s)
    if (s.counts.isNotEmpty()) {
        FeatureStatusPanel(s)
    }
    s.lastDecision?.takeIf { it.isNotBlank() }?.let { LastDecisionCard(it) }
}

@Composable
private fun OverviewCard(s: HarnessStatus, onOpenRunLog: (() -> Unit)?) {
    val buckets = remember(s.counts) { countBuckets(s) }
    val totalTracked = remember(s.featureCount, s.counts) {
        max(s.featureCount, s.counts.values.sum())
    }
    val summaryTone = when {
        s.escalated -> "escalated"
        s.smokeFail -> "smoke fail"
        s.alive -> "alive"
        else -> "idle"
    }

    PapercupCard(modifier = Modifier.fillMaxWidth(), contentPadding = PaddingValues(16.dp)) {
        Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
            PapercupCardHeader("Harness dashboard", meta = summaryTone)
            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(s.slug, style = MaterialTheme.typography.headlineSmall, color = PapercupColors.Text)
                if (s.path.isNotBlank()) {
                    Text(
                        text = s.path,
                        style = MaterialTheme.typography.bodySmall,
                        color = PapercupColors.TextMuted,
                        fontFamily = FontFamily.Monospace,
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
            }
            ProgressStrip(
                totalTracked = totalTracked,
                pendingCheckpoints = s.pendingCheckpoints,
                buckets = buckets,
            )
            StatGrid(s, totalTracked)
            FlagRow(s, onOpenRunLog)
        }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun ProgressStrip(
    totalTracked: Long,
    pendingCheckpoints: Long,
    buckets: List<CountBucket>,
) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                PapercupSectionLabel("summary")
                Text(
                    text = if (totalTracked > 0) "$totalTracked tracked features" else "No tracked features yet",
                    style = MaterialTheme.typography.bodyMedium,
                    color = PapercupColors.Text,
                )
            }
            PapercupMetaText(
                text = if (pendingCheckpoints > 0) "$pendingCheckpoints pending checkpoints" else "checkpoints clear",
                monospace = true,
            )
        }
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .height(10.dp)
                .clip(RoundedCornerShape(999.dp))
                .background(PapercupColors.Ink.copy(alpha = 0.7f))
                .border(1.dp, PapercupColors.StrokeSoft, RoundedCornerShape(999.dp)),
        ) {
            if (totalTracked == 0L || buckets.isEmpty()) {
                Box(
                    modifier = Modifier
                        .fillMaxHeight()
                        .weight(1f)
                        .background(PapercupColors.AccentSoft),
                )
            } else {
                buckets.forEach { bucket ->
                    Box(
                        modifier = Modifier
                            .fillMaxHeight()
                            .weight(bucket.count.toFloat())
                            .background(bucket.contentColor),
                    )
                }
            }
        }
        if (buckets.isNotEmpty()) {
            FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                buckets.forEach { bucket ->
                    PapercupStatusChip(
                        text = "${bucket.key} ${bucket.count}",
                        containerColor = bucket.containerColor,
                        contentColor = bucket.contentColor,
                        borderColor = bucket.contentColor.copy(alpha = 0.36f),
                    )
                }
            }
        }
    }
}

@Composable
private fun StatGrid(s: HarnessStatus, totalTracked: Long) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        PapercupSectionLabel("telemetry")
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                StatBlock(
                    modifier = Modifier.weight(1f),
                    label = "iteration",
                    value = s.iteration.toString(),
                )
                StatBlock(
                    modifier = Modifier.weight(1f),
                    label = "features",
                    value = totalTracked.toString(),
                )
            }
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                StatBlock(
                    modifier = Modifier.weight(1f),
                    label = "checkpoints",
                    value = s.pendingCheckpoints.toString(),
                )
                StatBlock(
                    modifier = Modifier.weight(1f),
                    label = "competitions",
                    value = s.activeCompetitions.toString(),
                )
            }
        }
    }
}

@Composable
private fun StatBlock(modifier: Modifier = Modifier, label: String, value: String) {
    Surface(
        modifier = modifier,
        shape = RoundedCornerShape(16.dp),
        color = PapercupColors.Ink.copy(alpha = 0.42f),
        tonalElevation = 0.dp,
        border = androidx.compose.foundation.BorderStroke(1.dp, PapercupColors.StrokeSoft),
    ) {
        Column(
            modifier = Modifier.padding(horizontal = 12.dp, vertical = 10.dp),
            verticalArrangement = Arrangement.spacedBy(2.dp),
        ) {
            PapercupSectionLabel(label)
            Text(
                text = value,
                style = MaterialTheme.typography.titleLarge,
                color = PapercupColors.Text,
                fontFamily = FontFamily.Monospace,
            )
        }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun FlagRow(s: HarnessStatus, onOpenRunLog: (() -> Unit)?) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        PapercupSectionLabel("flags")
        FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
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
                    containerColor = PapercupColors.WarningSoft,
                    contentColor = PapercupColors.Warning,
                )
            }
            if (onOpenRunLog != null) {
                PapercupStatusChip(
                    text = "run log",
                    containerColor = PapercupColors.AccentSoft,
                    contentColor = PapercupColors.AccentStrong,
                    onClick = onOpenRunLog,
                )
            }
        }
    }
}

@Composable
private fun MissionCard(s: HarnessStatus) {
    PapercupPanel(modifier = Modifier.fillMaxWidth(), contentPadding = PaddingValues(16.dp)) {
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            PapercupCardHeader(stringResource(R.string.harness_detail_mission), meta = "usage")
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                StatBlock(
                    modifier = Modifier.weight(1f),
                    label = "cost usd",
                    value = String.format("$%.4f", s.missionCostUsd),
                )
                StatBlock(
                    modifier = Modifier.weight(1f),
                    label = "input",
                    value = "%,d".format(s.missionInputTokens),
                )
                StatBlock(
                    modifier = Modifier.weight(1f),
                    label = "output",
                    value = "%,d".format(s.missionOutputTokens),
                )
            }
        }
    }
}

@Composable
private fun FeatureStatusPanel(s: HarnessStatus) {
    PapercupPanel(modifier = Modifier.fillMaxWidth(), contentPadding = PaddingValues(16.dp)) {
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            PapercupCardHeader(stringResource(R.string.harness_detail_features_by_status), meta = "live counts")
            Column(verticalArrangement = Arrangement.spacedBy(0.dp)) {
                countBuckets(s).forEach { bucket ->
                    KeyValue(bucket.key, bucket.count.toString(), tint = bucket.contentColor)
                }
            }
        }
    }
}

@Composable
private fun LastDecisionCard(text: String) {
    PapercupPanel(modifier = Modifier.fillMaxWidth(), contentPadding = PaddingValues(0.dp)) {
        Column(verticalArrangement = Arrangement.spacedBy(0.dp)) {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .background(PapercupColors.SurfaceStrong.copy(alpha = 0.86f))
                    .border(1.dp, PapercupColors.StrokeSoft)
                    .padding(horizontal = 16.dp, vertical = 12.dp),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                PapercupChipRow {
                    PapercupStatusChip(
                        text = stringResource(R.string.harness_detail_last_decision),
                        containerColor = PapercupColors.AccentSoft,
                        contentColor = PapercupColors.AccentStrong,
                    )
                }
                PapercupMetaText("terminal")
            }
            Text(
                text = text,
                modifier = Modifier
                    .fillMaxWidth()
                    .background(PapercupColors.Ink.copy(alpha = 0.94f))
                    .padding(16.dp),
                style = MaterialTheme.typography.bodySmall,
                color = PapercupColors.TextMuted,
                fontFamily = FontFamily.Monospace,
            )
        }
    }
}

@Composable
private fun KeyValue(key: String, value: String, tint: Color = PapercupColors.TextMuted) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 8.dp),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        PapercupMetaText(key)
        Text(
            text = value,
            color = tint,
            fontFamily = FontFamily.Monospace,
            style = MaterialTheme.typography.bodySmall,
        )
    }
}

private fun countBuckets(s: HarnessStatus): List<CountBucket> =
    s.counts.entries
        .filter { it.value > 0 }
        .sortedByDescending { it.value }
        .map { (key, countValue) ->
            val count = countValue.toLong()
            val normalized = key.lowercase()
            when {
                normalized.contains("pass") || normalized.contains("done") || normalized.contains("complete") ->
                    CountBucket(key = key, count = count, containerColor = PapercupColors.SuccessSoft, contentColor = PapercupColors.Success)
                normalized.contains("block") || normalized.contains("fail") || normalized.contains("error") ->
                    CountBucket(key = key, count = count, containerColor = PapercupColors.ErrorSoft, contentColor = PapercupColors.Error)
                normalized.contains("todo") || normalized.contains("queue") || normalized.contains("plan") || normalized.contains("pending") ->
                    CountBucket(key = key, count = count, containerColor = PapercupColors.WarningSoft, contentColor = PapercupColors.Warning)
                else ->
                    CountBucket(key = key, count = count, containerColor = PapercupColors.InfoSoft, contentColor = PapercupColors.AccentStrong)
            }
        }
