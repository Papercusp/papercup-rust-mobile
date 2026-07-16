// SPDX-License-Identifier: GPL-3.0-or-later
package com.papercuspai.operator.mobile

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import com.papercuspai.operator.mobile.theme.PapercupCard
import com.papercuspai.operator.mobile.theme.PapercupColors
import com.papercuspai.operator.mobile.theme.PapercupMetaText
import com.papercuspai.operator.mobile.theme.PapercupScreenHeader
import com.papercuspai.operator.mobile.theme.PapercupStatusChip
import kotlinx.coroutines.launch
import uniffi.papercup.ApiException
import uniffi.papercup.StandingCandidate
import java.time.Duration
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeParseException

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun StandingApprovalsScreen(
    creds: DeviceCredentials,
    onBack: () -> Unit,
) {
    var candidates by remember { mutableStateOf<List<StandingCandidate>?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    var pending by remember { mutableStateOf<Set<String>>(emptySet()) }
    var hidden by remember { mutableStateOf<Set<String>>(emptySet()) }
    val scope = rememberCoroutineScope()

    fun key(candidate: StandingCandidate) = "${candidate.capability}::${candidate.targetHarness}"

    suspend fun load() {
        try {
            candidates = creds.client().standingCandidates()
            error = null
        } catch (e: ApiException) {
            error = HumanError.describe(e, "Loading approvals")
        } catch (t: Throwable) {
            error = HumanError.describe(t, "Loading approvals")
        }
    }

    LaunchedEffect(creds.deviceToken) { load() }

    fun decide(candidate: StandingCandidate, approve: Boolean) {
        val candidateKey = key(candidate)
        pending = pending + candidateKey
        hidden = hidden + candidateKey
        scope.launch {
            try {
                creds.client().standingCandidateDecide(candidate.capability, candidate.targetHarness, approve)
            } catch (t: Throwable) {
                error = HumanError.describe(t, "Sending the decision")
                hidden = hidden - candidateKey
            } finally {
                pending = pending - candidateKey
            }
        }
    }

    val visible = candidates?.filter { key(it) !in hidden }
    val subtitle = when {
        visible == null -> stringResource(R.string.loading)
        else -> "${visible.size} pending"
    }

    Scaffold(
        topBar = {
            PapercupScreenHeader(
                title = stringResource(R.string.standing_approvals_title),
                subtitle = subtitle,
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
        LazyColumn(
            modifier = Modifier
                .fillMaxSize()
                .background(PapercupColors.ScreenGradient)
                .padding(padding)
                .padding(horizontal = 16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
            contentPadding = PaddingValues(vertical = 12.dp),
        ) {
            item {
                PapercupCard {
                    PapercupMetaText(
                        text = "Patterns dispatched silently 3+ times in the last 24h. Approve to grant standing authority for this capability and target.",
                    )
                }
            }

            error?.let {
                item {
                    PapercupCard(accent = PapercupColors.ErrorSoft) {
                        Text(
                            text = it,
                            style = MaterialTheme.typography.bodySmall,
                            color = PapercupColors.Error,
                        )
                    }
                }
            }

            when {
                visible == null -> item {
                    PapercupCard {
                        Box(
                            modifier = Modifier.fillMaxWidth(),
                            contentAlignment = Alignment.Center,
                        ) {
                            CircularProgressIndicator(color = PapercupColors.AccentStrong)
                        }
                    }
                }

                visible.isEmpty() -> item {
                    PapercupCard {
                        Text(
                            text = "No standing-approval candidates.",
                            style = MaterialTheme.typography.bodyMedium,
                            color = PapercupColors.TextMuted,
                        )
                    }
                }

                else -> items(visible, key = { key(it) }) { candidate ->
                    val candidateKey = key(candidate)
                    val busy = candidateKey in pending
                    PapercupCard(contentPadding = PaddingValues(14.dp)) {
                        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                            Row(
                                modifier = Modifier.fillMaxWidth(),
                                horizontalArrangement = Arrangement.SpaceBetween,
                                verticalAlignment = Alignment.Top,
                            ) {
                                Text(
                                    text = candidate.capability,
                                    modifier = Modifier.weight(1f),
                                    style = MaterialTheme.typography.bodyMedium,
                                    color = PapercupColors.Text,
                                    fontFamily = FontFamily.Monospace,
                                )
                                PapercupStatusChip(
                                    text = "${candidate.count}×",
                                    containerColor = PapercupColors.WarningSoft,
                                    contentColor = PapercupColors.Warning,
                                )
                            }
                            Text(
                                text = candidate.targetHarness,
                                style = MaterialTheme.typography.bodySmall,
                                color = PapercupColors.Text,
                            )
                            PapercupMetaText(
                                text = buildString {
                                    append("last seen ")
                                    append(formatAge(candidate.lastSeenAt))
                                    candidate.firstShownAt?.let {
                                        append(" · first shown ")
                                        append(formatAge(it))
                                    }
                                },
                            )
                            Row(
                                modifier = Modifier.fillMaxWidth(),
                                horizontalArrangement = Arrangement.spacedBy(8.dp),
                            ) {
                                Button(
                                    onClick = { decide(candidate, true) },
                                    enabled = !busy,
                                    modifier = Modifier.weight(1f),
                                    colors = ButtonDefaults.buttonColors(
                                        containerColor = PapercupColors.AccentStrong,
                                        contentColor = PapercupColors.ButtonInk,
                                    ),
                                ) {
                                    Text(if (busy) "…" else stringResource(R.string.standing_approvals_approve))
                                }
                                OutlinedButton(
                                    onClick = { decide(candidate, false) },
                                    enabled = !busy,
                                    modifier = Modifier.weight(1f),
                                    colors = ButtonDefaults.outlinedButtonColors(contentColor = PapercupColors.Text),
                                ) {
                                    Text(stringResource(R.string.standing_approvals_dismiss))
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

private fun formatAge(iso: String): String {
    val instant = try {
        Instant.parse(iso)
    } catch (_: DateTimeParseException) {
        return iso
    }
    val seconds = Duration.between(instant, Instant.now()).seconds.coerceAtLeast(0)
    return when {
        seconds < 60 -> "${seconds}s ago"
        seconds < 3_600 -> "${seconds / 60}m ago"
        seconds < 86_400 -> "${seconds / 3_600}h ago"
        else -> instant.atZone(ZoneId.systemDefault()).toLocalDate().toString()
    }
}
