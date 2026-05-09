// SPDX-License-Identifier: GPL-3.0-or-later
package com.papercuspai.operator.mobile

import android.os.Bundle
import android.content.Intent
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.ui.platform.LocalContext
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.clickable
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch
import uniffi.papercup.ApiException
import uniffi.papercup.Harness
import uniffi.papercup.OperatorClient
import uniffi.papercup.SyncException
import uniffi.papercup.SyncStream
import uniffi.papercup.version

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val store = CredentialStore(applicationContext)
        setContent {
            MaterialTheme {
                Surface(modifier = Modifier.fillMaxSize()) {
                    AppRoot(store)
                }
            }
        }
    }
}

@Composable
private fun AppRoot(store: CredentialStore) {
    var creds by remember { mutableStateOf(store.load()) }
    var route by remember { mutableStateOf<Route>(Route.List) }
    var liveTick by remember { mutableStateOf(0) }
    var lastInvalidate by remember { mutableStateOf<String?>(null) }

    val current = creds
    if (current == null) {
        PairScreen(onPaired = { fresh ->
            store.save(fresh)
            creds = fresh
            route = Route.List
        })
        return
    }

    // Single SSE subscription, lives for the duration of the paired
    // session — both the list and detail screens read from it via the
    // hoisted `liveTick` / `lastInvalidate` state below.
    DisposableEffect(current.deviceToken) {
        val stream = SyncStream(current.server, current.deviceToken)
        val job = kotlinx.coroutines.MainScope().launch {
            try {
                while (true) {
                    val ev = stream.nextEvent()
                    lastInvalidate = ev.name
                    if (ev.name.startsWith("harness")) {
                        liveTick += 1
                    }
                }
            } catch (_: CancellationException) {
            } catch (_: SyncException) {
            }
        }
        onDispose {
            stream.disconnect()
            stream.close()
            job.cancel()
        }
    }

    when (val r = route) {
        Route.List -> HarnessListScreen(
            creds = current,
            liveTick = liveTick,
            lastInvalidate = lastInvalidate,
            onSelect = { slug -> route = Route.Detail(slug) },
            onForget = {
                store.clear()
                creds = null
            },
        )
        is Route.Detail -> HarnessDetailScreen(
            creds = current,
            slug = r.slug,
            invalidationTick = liveTick,
            onBack = { route = Route.List },
        )
    }
}

private sealed interface Route {
    data object List : Route
    data class Detail(val slug: String) : Route
}

private sealed interface ScreenState {
    data object Loading : ScreenState
    data class Ready(val harnesses: List<Harness>) : ScreenState
    data class Failed(val message: String) : ScreenState
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun HarnessListScreen(
    creds: DeviceCredentials,
    liveTick: Int,
    lastInvalidate: String?,
    onSelect: (String) -> Unit,
    onForget: () -> Unit,
) {
    var state by remember { mutableStateOf<ScreenState>(ScreenState.Loading) }
    var menuOpen by remember { mutableStateOf(false) }

    LaunchedEffect(creds.deviceToken, liveTick) {
        state = ScreenState.Loading
        state = try {
            val client = OperatorClient(creds.server, creds.deviceToken)
            ScreenState.Ready(client.listHarnesses())
        } catch (e: ApiException) {
            ScreenState.Failed("API: ${e::class.simpleName}: ${e.message ?: "no detail"}")
        } catch (t: Throwable) {
            ScreenState.Failed("Unexpected: ${t::class.simpleName}: ${t.message ?: "no detail"}")
        }
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = {
                    Column {
                        Text("Papercup", style = MaterialTheme.typography.titleLarge)
                        Text(
                            "core ${version()} · ${creds.server}",
                            style = MaterialTheme.typography.bodySmall,
                            fontFamily = FontFamily.Monospace,
                        )
                    }
                },
                actions = {
                    Box {
                        IconButton(onClick = { menuOpen = true }) {
                            Icon(Icons.Default.MoreVert, contentDescription = "Menu")
                        }
                        DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
                            DropdownMenuItem(
                                text = { Text("Forget device") },
                                onClick = {
                                    menuOpen = false
                                    onForget()
                                },
                            )
                        }
                    }
                },
            )
        },
    ) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .padding(horizontal = 16.dp),
        ) {
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
                    Row(
                        modifier = Modifier.fillMaxWidth().padding(vertical = 8.dp),
                        horizontalArrangement = Arrangement.SpaceBetween,
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Text(
                            "${s.harnesses.size} ${if (s.harnesses.size == 1) "harness" else "harnesses"}",
                            style = MaterialTheme.typography.titleMedium,
                        )
                        Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                            creds.meshAssignedIp?.let { ip ->
                                MeshButton(creds = creds, ip = ip)
                            }
                            AssistChip(
                                onClick = {},
                                label = {
                                    Text(
                                        lastInvalidate?.let { "live · $it" } ?: "live",
                                        style = MaterialTheme.typography.labelSmall,
                                    )
                                },
                            )
                        }
                    }
                    LazyColumn(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        items(s.harnesses) { harness ->
                            HarnessRow(harness, onClick = { onSelect(harness.slug) })
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun MeshButton(creds: DeviceCredentials, ip: String) {
    val context = LocalContext.current
    var active by remember { mutableStateOf(false) }
    var pendingActivate by remember { mutableStateOf(false) }

    val launcher = rememberLauncherForActivityResult(
        ActivityResultContracts.StartActivityForResult(),
    ) { result ->
        if (pendingActivate && result.resultCode == android.app.Activity.RESULT_OK) {
            creds.wgQuickConfig?.let { MeshController.activate(context, it) }
            active = true
        }
        pendingActivate = false
    }

    AssistChip(
        onClick = {
            val cfg = creds.wgQuickConfig ?: return@AssistChip
            if (active) {
                MeshController.deactivate(context)
                active = false
            } else {
                val prepare = MeshController.prepareIntent(context)
                if (prepare != null) {
                    pendingActivate = true
                    launcher.launch(prepare)
                } else {
                    MeshController.activate(context, cfg)
                    active = true
                }
            }
        },
        label = {
            Text(
                if (active) "mesh ✓ $ip" else "mesh · $ip",
                style = MaterialTheme.typography.labelSmall,
            )
        },
    )
}

@Composable
private fun HarnessRow(harness: Harness, onClick: () -> Unit) {
    Card(modifier = Modifier.fillMaxWidth().clickable(onClick = onClick)) {
        Column(Modifier.padding(12.dp)) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(harness.slug, style = MaterialTheme.typography.titleMedium)
                harness.status?.let { status ->
                    AssistChip(onClick = {}, label = { Text(status) })
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
