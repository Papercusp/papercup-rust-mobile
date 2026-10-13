// SPDX-License-Identifier: GPL-3.0-or-later
package com.papercuspai.operator.mobile

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import com.papercuspai.operator.mobile.theme.PapercupCard
import com.papercuspai.operator.mobile.theme.PapercupColors
import com.papercuspai.operator.mobile.theme.PapercupScreenHeader

private data class PushTapSample(
    val label: String,
    val kind: String? = null,
    val harness: String? = null,
    val payloadText: String,
    val expectedRoute: String,
)

private val pushTapSamples = listOf(
    PushTapSample(
        label = "intervention (harness=foo)",
        kind = "intervention",
        harness = "foo",
        payloadText = "{\"kind\":\"intervention\",\"harness\":\"foo\"}",
        expectedRoute = "/harness/foo",
    ),
    PushTapSample(
        label = "intervention (no harness)",
        kind = "intervention",
        payloadText = "{\"kind\":\"intervention\"}",
        expectedRoute = "/notifications",
    ),
    PushTapSample(
        label = "plan-review (harness=bar)",
        kind = "plan-review",
        harness = "bar",
        payloadText = "{\"kind\":\"plan-review\",\"harness\":\"bar\"}",
        expectedRoute = "/harness/bar",
    ),
    PushTapSample(
        label = "plan-review (no harness)",
        kind = "plan-review",
        payloadText = "{\"kind\":\"plan-review\"}",
        expectedRoute = "/notifications",
    ),
    PushTapSample(
        label = "smoke-fail (harness=baz)",
        kind = "smoke-fail",
        harness = "baz",
        payloadText = "{\"kind\":\"smoke-fail\",\"harness\":\"baz\"}",
        expectedRoute = "/log/baz",
    ),
    PushTapSample(
        label = "smoke-fail (no harness)",
        kind = "smoke-fail",
        payloadText = "{\"kind\":\"smoke-fail\"}",
        expectedRoute = "/notifications",
    ),
    PushTapSample(
        label = "operator-suggestion",
        kind = "operator-suggestion",
        payloadText = "{\"kind\":\"operator-suggestion\"}",
        expectedRoute = "/operator",
    ),
    PushTapSample(
        label = "unknown kind",
        kind = "mystery",
        payloadText = "{\"kind\":\"mystery\"}",
        expectedRoute = "/notifications",
    ),
    PushTapSample(
        label = "empty payload",
        payloadText = "{}",
        expectedRoute = "/notifications",
    ),
)

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PushTapTestScreen(
    onBack: () -> Unit,
    onOpenHarnessDetail: (String) -> Unit,
    onOpenRunLog: (String) -> Unit,
    onOpenOperator: () -> Unit,
    onOpenInbox: () -> Unit,
) {
    Scaffold(
        topBar = {
            PapercupScreenHeader(
                title = "Push tap test",
                subtitle = "Simulates a tapped notification and runs the routing handler.",
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(
                            imageVector = Icons.AutoMirrored.Filled.ArrowBack,
                            contentDescription = "Back",
                            tint = PapercupColors.Text,
                        )
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
                .padding(horizontal = 16.dp)
                .verticalScroll(rememberScrollState()),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Spacer(Modifier.height(12.dp))
            PapercupCard(
                modifier = Modifier.fillMaxWidth(),
                contentPadding = PaddingValues(0.dp),
            ) {
                Column {
                    pushTapSamples.forEachIndexed { index, sample ->
                        PushTapSampleButton(
                            sample = sample,
                            isLast = index == pushTapSamples.lastIndex,
                            onClick = {
                                routePushTapSample(
                                    sample = sample,
                                    onOpenHarnessDetail = onOpenHarnessDetail,
                                    onOpenRunLog = onOpenRunLog,
                                    onOpenOperator = onOpenOperator,
                                    onOpenInbox = onOpenInbox,
                                )
                            },
                        )
                    }
                }
            }
            Text(
                text = "Buttons run the same route mapping the native tap handler should use. Real push delivery still requires APNs / FCM credentials.",
                style = MaterialTheme.typography.bodySmall,
                color = PapercupColors.TextMuted,
            )
            Spacer(Modifier.height(12.dp))
        }
    }
}

@Composable
private fun PushTapSampleButton(
    sample: PushTapSample,
    isLast: Boolean,
    onClick: () -> Unit,
) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(horizontal = 16.dp, vertical = 12.dp),
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Text(
            text = sample.label,
            style = MaterialTheme.typography.bodyMedium,
            color = PapercupColors.Text,
        )
        SelectionContainer {
            Text(
                text = "payload: ${sample.payloadText}",
                style = MaterialTheme.typography.bodySmall,
                color = PapercupColors.TextMuted,
                fontFamily = FontFamily.Monospace,
            )
        }
        Text(
            text = "→ ${sample.expectedRoute}",
            style = MaterialTheme.typography.bodySmall,
            color = PapercupColors.AccentStrong,
            fontFamily = FontFamily.Monospace,
        )
    }
    if (!isLast) {
        HorizontalDivider(color = PapercupColors.StrokeSoft.copy(alpha = 0.55f))
    }
}

private fun routePushTapSample(
    sample: PushTapSample,
    onOpenHarnessDetail: (String) -> Unit,
    onOpenRunLog: (String) -> Unit,
    onOpenOperator: () -> Unit,
    onOpenInbox: () -> Unit,
) {
    when (val destination = resolvePushDestination(sample.kind, sample.harness)) {
        is PushDestination.HarnessDetail -> onOpenHarnessDetail(destination.slug)
        is PushDestination.RunLog -> onOpenRunLog(destination.slug)
        PushDestination.Operator -> onOpenOperator()
        PushDestination.Inbox -> onOpenInbox()
    }
}
