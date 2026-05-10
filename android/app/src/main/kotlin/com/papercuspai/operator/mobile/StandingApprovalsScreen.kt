// SPDX-License-Identifier: GPL-3.0-or-later
package com.papercuspai.operator.mobile

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch
import uniffi.papercup.ApiException
import uniffi.papercup.OperatorClient
import uniffi.papercup.StandingCandidate

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

    fun key(c: StandingCandidate) = "${c.capability}::${c.targetHarness}"

    suspend fun load() {
        try {
            candidates = OperatorClient(creds.server, creds.deviceToken).standingCandidates()
            error = null
        } catch (e: ApiException) {
            error = e.message ?: e::class.simpleName ?: "load failed"
        } catch (t: Throwable) {
            error = t.message ?: t::class.simpleName ?: "load failed"
        }
    }

    LaunchedEffect(creds.deviceToken) { load() }

    fun decide(c: StandingCandidate, approve: Boolean) {
        val k = key(c)
        pending = pending + k
        hidden = hidden + k
        scope.launch {
            try {
                OperatorClient(creds.server, creds.deviceToken)
                    .standingCandidateDecide(c.capability, c.targetHarness, approve)
            } catch (t: Throwable) {
                error = t.message ?: "decision failed"
                hidden = hidden - k
            } finally {
                pending = pending - k
            }
        }
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Standing approvals") },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
                    }
                },
            )
        },
    ) { padding ->
        Column(modifier = Modifier.fillMaxSize().padding(padding)) {
            Text(
                "Patterns the operator has dispatched silently 3+ times in the last 24h. " +
                    "Approve to grant standing authority for this capability + target.",
                style = MaterialTheme.typography.bodySmall,
                modifier = Modifier.padding(16.dp),
            )
            error?.let {
                Card(
                    modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp),
                    colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.errorContainer),
                ) { Text(it, modifier = Modifier.padding(12.dp), style = MaterialTheme.typography.bodySmall) }
                Spacer(Modifier.height(8.dp))
            }
            val visible = candidates?.filter { key(it) !in hidden }
            when {
                visible == null -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    CircularProgressIndicator()
                }
                visible.isEmpty() -> Text(
                    "No standing-approval candidates.",
                    modifier = Modifier.padding(16.dp),
                    style = MaterialTheme.typography.bodyMedium,
                )
                else -> LazyColumn(
                    contentPadding = PaddingValues(16.dp),
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    items(visible, key = { key(it) }) { c ->
                        val k = key(c)
                        val busy = k in pending
                        Card(modifier = Modifier.fillMaxWidth()) {
                            Column(modifier = Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                                Row(verticalAlignment = Alignment.Top) {
                                    Text(
                                        c.capability,
                                        modifier = Modifier.weight(1f),
                                        style = MaterialTheme.typography.bodyMedium,
                                        fontFamily = FontFamily.Monospace,
                                    )
                                    AssistChip(onClick = {}, label = { Text("${c.count}×") })
                                }
                                Text("→ ${c.targetHarness}", style = MaterialTheme.typography.bodySmall)
                                Text("last seen ${c.lastSeenAt}", style = MaterialTheme.typography.labelSmall)
                                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                    Button(
                                        onClick = { decide(c, true) },
                                        enabled = !busy,
                                        modifier = Modifier.weight(1f),
                                    ) { Text(if (busy) "…" else "Approve") }
                                    OutlinedButton(
                                        onClick = { decide(c, false) },
                                        enabled = !busy,
                                        modifier = Modifier.weight(1f),
                                    ) { Text("Dismiss") }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
