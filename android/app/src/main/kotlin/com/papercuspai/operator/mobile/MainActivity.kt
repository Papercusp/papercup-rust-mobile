// SPDX-License-Identifier: GPL-3.0-or-later
package com.papercuspai.operator.mobile

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import uniffi.papercup.ApiException
import uniffi.papercup.Harness
import uniffi.papercup.OperatorClient
import uniffi.papercup.version

// Phase 1: hardcoded base URL + device JWT until Phase 2 ships the pair flow.
// Override these via local edits while iterating; never commit a real JWT.
//
// To get a JWT for testing right now:
//   1. open the desktop operator at http://localhost:3070/settings/mobile
//   2. mint a pair token, then redeem it with curl:
//        curl -X POST https://api.papercupai.com/api/mobile/pair \
//          -H 'content-type: application/json' \
//          -d '{"pairToken":"<TOKEN>"}'
//   3. paste the returned `deviceToken` value into PHASE1_TOKEN below.
private const val PHASE1_BASE_URL = "https://api.papercupai.com"
private const val PHASE1_TOKEN: String = ""

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent {
            MaterialTheme {
                Surface(modifier = Modifier.fillMaxSize()) {
                    HarnessListScreen()
                }
            }
        }
    }
}

private sealed interface ScreenState {
    data object Loading : ScreenState
    data class Ready(val harnesses: List<Harness>) : ScreenState
    data class Failed(val message: String) : ScreenState
}

@Composable
fun HarnessListScreen() {
    var state by remember { mutableStateOf<ScreenState>(ScreenState.Loading) }

    LaunchedEffect(Unit) {
        if (PHASE1_TOKEN.isBlank()) {
            state = ScreenState.Failed(
                "Phase 1 needs a JWT in PHASE1_TOKEN. " +
                    "See the comment in MainActivity.kt for how to mint one.",
            )
            return@LaunchedEffect
        }
        state = try {
            val client = OperatorClient(PHASE1_BASE_URL, PHASE1_TOKEN)
            ScreenState.Ready(client.listHarnesses())
        } catch (e: ApiException) {
            ScreenState.Failed("API: ${e::class.simpleName}: ${e.message ?: "no detail"}")
        } catch (t: Throwable) {
            ScreenState.Failed("Unexpected: ${t::class.simpleName}: ${t.message ?: "no detail"}")
        }
    }

    Column(modifier = Modifier.fillMaxSize().padding(16.dp)) {
        Text(
            text = "Papercup",
            style = MaterialTheme.typography.displaySmall,
        )
        Text(
            text = "core ${version()} · phase 1 · $PHASE1_BASE_URL",
            style = MaterialTheme.typography.bodySmall,
            fontFamily = FontFamily.Monospace,
        )
        Spacer(Modifier.height(16.dp))
        when (val s = state) {
            ScreenState.Loading -> {
                Row(
                    Modifier.fillMaxWidth().padding(top = 32.dp),
                    horizontalArrangement = Arrangement.Center,
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    CircularProgressIndicator(strokeWidth = 2.dp)
                    Spacer(Modifier.width(12.dp))
                    Text("Loading harnesses…")
                }
            }
            is ScreenState.Failed -> {
                Card(
                    colors = CardDefaults.cardColors(
                        containerColor = MaterialTheme.colorScheme.errorContainer,
                    ),
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Column(Modifier.padding(16.dp)) {
                        Text(
                            "Couldn't load harnesses",
                            style = MaterialTheme.typography.titleMedium,
                            color = MaterialTheme.colorScheme.onErrorContainer,
                        )
                        Spacer(Modifier.height(4.dp))
                        Text(
                            s.message,
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onErrorContainer,
                            fontFamily = FontFamily.Monospace,
                        )
                    }
                }
            }
            is ScreenState.Ready -> {
                Text(
                    "${s.harnesses.size} ${if (s.harnesses.size == 1) "harness" else "harnesses"}",
                    style = MaterialTheme.typography.titleMedium,
                )
                Spacer(Modifier.height(8.dp))
                LazyColumn(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    items(s.harnesses) { harness ->
                        HarnessRow(harness)
                    }
                }
            }
        }
    }
}

@Composable
private fun HarnessRow(harness: Harness) {
    Card(modifier = Modifier.fillMaxWidth()) {
        Column(Modifier.padding(12.dp)) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    harness.slug,
                    style = MaterialTheme.typography.titleMedium,
                )
                harness.status?.let { status ->
                    AssistChip(
                        onClick = {},
                        label = { Text(status) },
                    )
                }
            }
            harness.path.takeIf { it.isNotBlank() }?.let {
                Text(
                    it,
                    style = MaterialTheme.typography.bodySmall,
                    fontFamily = FontFamily.Monospace,
                )
            }
            val meta = buildList {
                harness.harnessKind?.let { add("kind=$it") }
                harness.iteration?.let { add("iter=$it") }
                if (!harness.hasState) add("no-state")
            }.joinToString(" · ")
            if (meta.isNotEmpty()) {
                Text(meta, style = MaterialTheme.typography.labelSmall)
            }
        }
    }
}
