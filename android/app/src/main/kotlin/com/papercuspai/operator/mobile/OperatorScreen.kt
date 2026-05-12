// SPDX-License-Identifier: GPL-3.0-or-later
package com.papercuspai.operator.mobile

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.papercuspai.operator.mobile.theme.PapercupCard
import com.papercuspai.operator.mobile.theme.PapercupChipRow
import com.papercuspai.operator.mobile.theme.PapercupColors
import com.papercuspai.operator.mobile.theme.PapercupMetaText
import com.papercuspai.operator.mobile.theme.PapercupPanel
import com.papercuspai.operator.mobile.theme.PapercupScreenHeader
import com.papercuspai.operator.mobile.theme.PapercupStatusChip
import kotlinx.coroutines.launch
import uniffi.papercup.ApiException
import uniffi.papercup.OperatorCard

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun OperatorScreen(
    creds: DeviceCredentials,
    voice: VoiceManager,
    liveTick: Int,
    onSelectHarness: (String) -> Unit,
) {
    var loading by remember { mutableStateOf(true) }
    var cards by remember { mutableStateOf<List<OperatorCard>>(emptyList()) }
    var fetchError by remember { mutableStateOf<String?>(null) }
    var actionError by remember { mutableStateOf<String?>(null) }
    var pendingIds by remember { mutableStateOf<Set<String>>(emptySet()) }
    var hiddenIds by remember { mutableStateOf<Set<String>>(emptySet()) }
    val scope = rememberCoroutineScope()

    LaunchedEffect(creds.deviceToken, liveTick) {
        loading = true
        try {
            cards = creds.client().listOperatorCards()
            fetchError = null
        } catch (t: Throwable) {
            fetchError = t.toOperatorMessage()
        } finally {
            loading = false
        }
    }

    val visibleCards = remember(cards, hiddenIds) {
        cards.filterNot { hiddenIds.contains(it.id) }
    }
    val subtitle = if (loading) "Loading…" else "${visibleCards.size} pending"
    val error = fetchError ?: actionError

    fun actOnCard(cardId: String, action: suspend (String) -> String) {
        actionError = null
        pendingIds = pendingIds + cardId
        hiddenIds = hiddenIds + cardId
        scope.launch {
            try {
                action(cardId)
            } catch (t: Throwable) {
                actionError = t.toOperatorMessage()
                hiddenIds = hiddenIds - cardId
            } finally {
                pendingIds = pendingIds - cardId
            }
        }
    }

    Scaffold(
        topBar = {
            PapercupScreenHeader(
                title = stringResource(R.string.operator_screen_title),
                subtitle = subtitle,
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
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Spacer(Modifier.height(8.dp))
            error?.let { ErrorCard(it) }

            if (!loading && visibleCards.isEmpty()) {
                EmptyStateCard()
            }

            visibleCards.forEachIndexed { index, card ->
                OperatorSuggestionCard(
                    index = index,
                    card = card,
                    busy = pendingIds.contains(card.id),
                    onSelectHarness = onSelectHarness,
                    onDispatch = { actOnCard(card.id) { creds.client().dispatchOperatorCard(it) } },
                    onDismiss = { actOnCard(card.id) { creds.client().dismissOperatorCard(it) } },
                )
            }

            Spacer(Modifier.height(12.dp))
        }
    }
}

@Composable
private fun ErrorCard(message: String) {
    PapercupCard(accent = PapercupColors.ErrorSoft, contentPadding = PaddingValues(12.dp)) {
        Text(
            text = message,
            color = PapercupColors.Error,
            fontFamily = FontFamily.Monospace,
            style = MaterialTheme.typography.bodySmall,
        )
    }
}

@Composable
private fun EmptyStateCard() {
    PapercupCard(
        accent = PapercupColors.AccentSoft,
        contentPadding = PaddingValues(horizontal = 14.dp, vertical = 16.dp),
    ) {
        Text(
            text = "No pending suggestions.",
            style = MaterialTheme.typography.bodyMedium,
            color = PapercupColors.TextMuted,
        )
    }
}

@Composable
private fun OperatorSuggestionCard(
    index: Int,
    card: OperatorCard,
    busy: Boolean,
    onSelectHarness: (String) -> Unit,
    onDispatch: () -> Unit,
    onDismiss: () -> Unit,
) {
    PapercupCard(
        accent = cardAccent(card),
        contentPadding = PaddingValues(12.dp),
    ) {
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.Top,
            ) {
                Column(
                    modifier = Modifier.weight(1f),
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    PapercupChipRow {
                        PapercupStatusChip(
                            text = "#${index + 1} · ${card.action.operatorLabel()}",
                            containerColor = PapercupColors.AccentSoft,
                            contentColor = PapercupColors.AccentCool,
                        )
                    }
                    Text(
                        text = card.directiveSubject?.takeIf { it.isNotBlank() } ?: card.action.operatorTitle(),
                        style = MaterialTheme.typography.titleMedium,
                        color = PapercupColors.Text,
                    )
                }
                Spacer(Modifier.width(8.dp))
                PapercupStatusChip(
                    text = card.status.operatorLabel(),
                    containerColor = statusContainer(card.status),
                    contentColor = statusContent(card.status),
                    borderColor = statusContent(card.status).copy(alpha = 0.45f),
                )
            }

            card.targetHarness?.takeIf { it.isNotBlank() }?.let { target ->
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clickable { onSelectHarness(target) }
                        .semantics {
                            contentDescription = "Target harness $target"
                            role = Role.Button
                        },
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    PapercupMetaText("→", monospace = true)
                    Text(
                        text = target,
                        style = MaterialTheme.typography.bodySmall,
                        color = PapercupColors.TextMuted,
                        fontFamily = FontFamily.Monospace,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
            }

            card.reason?.takeIf { it.isNotBlank() }?.let {
                Text(
                    text = it,
                    style = MaterialTheme.typography.bodyMedium,
                    color = PapercupColors.TextMuted,
                )
            }

            card.directiveBody?.takeIf { it.isNotBlank() }?.let {
                PapercupPanel(contentPadding = PaddingValues(horizontal = 12.dp, vertical = 10.dp)) {
                    Text(
                        text = it,
                        color = PapercupColors.TextMuted,
                        fontFamily = FontFamily.Monospace,
                        style = MaterialTheme.typography.bodySmall,
                    )
                }
            }

            OperatorActionTray(
                sendDirective = card.action == "send_directive",
                busy = busy,
                onDispatch = onDispatch,
                onDismiss = onDismiss,
            )
        }
    }
}

@Composable
private fun OperatorActionTray(
    sendDirective: Boolean,
    busy: Boolean,
    onDispatch: () -> Unit,
    onDismiss: () -> Unit,
) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        if (sendDirective) {
            Button(
                onClick = onDispatch,
                enabled = !busy,
                modifier = Modifier.weight(1f),
                colors = ButtonDefaults.buttonColors(
                    containerColor = PapercupColors.AccentStrong,
                    contentColor = PapercupColors.ButtonInk,
                    disabledContainerColor = PapercupColors.AccentStrong.copy(alpha = 0.36f),
                    disabledContentColor = PapercupColors.ButtonInk.copy(alpha = 0.7f),
                ),
            ) {
                Text(if (busy) "…" else "Dispatch")
            }
            OutlinedButton(
                onClick = onDismiss,
                enabled = !busy,
                modifier = Modifier.weight(1f),
                colors = ButtonDefaults.outlinedButtonColors(
                    contentColor = PapercupColors.TextMuted,
                    disabledContentColor = PapercupColors.TextFaint,
                ),
                border = androidx.compose.foundation.BorderStroke(
                    1.dp,
                    if (busy) PapercupColors.StrokeSoft else PapercupColors.StrokeStrong,
                ),
            ) {
                Text("Dismiss")
            }
        } else {
            OutlinedButton(
                onClick = onDismiss,
                enabled = !busy,
                modifier = Modifier.fillMaxWidth(),
                colors = ButtonDefaults.outlinedButtonColors(
                    contentColor = PapercupColors.Success,
                    disabledContentColor = PapercupColors.TextFaint,
                ),
                border = androidx.compose.foundation.BorderStroke(
                    1.dp,
                    if (busy) PapercupColors.StrokeSoft else PapercupColors.Success.copy(alpha = 0.45f),
                ),
            ) {
                Text(if (busy) "…" else "Acknowledge")
            }
        }
    }
}

private fun cardAccent(card: OperatorCard): Color = when {
    card.action == "send_directive" -> PapercupColors.AccentSoft
    card.status.equals("failed", ignoreCase = true) -> PapercupColors.ErrorSoft
    else -> PapercupColors.TealSoft
}

private fun statusContainer(status: String): Color = when {
    status.equals("failed", ignoreCase = true) -> PapercupColors.ErrorSoft
    status.equals("pending", ignoreCase = true) -> PapercupColors.WarningSoft
    else -> PapercupColors.AccentSoft
}

private fun statusContent(status: String): Color = when {
    status.equals("failed", ignoreCase = true) -> PapercupColors.Error
    status.equals("pending", ignoreCase = true) -> PapercupColors.Warning
    else -> PapercupColors.AccentStrong
}

private fun String.operatorLabel(): String = replace('_', ' ').uppercase()

private fun String.operatorTitle(): String = split('_')
    .joinToString(" ") { part -> part.lowercase().replaceFirstChar { c -> c.titlecase() } }

private fun Throwable.toOperatorMessage(): String = when (this) {
    is ApiException -> message ?: this::class.simpleName ?: "Operator request failed"
    else -> message ?: this::class.simpleName ?: "Operator request failed"
}
