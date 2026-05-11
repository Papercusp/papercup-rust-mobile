// SPDX-License-Identifier: GPL-3.0-or-later
package com.papercuspai.operator.mobile

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material.icons.Icons
import androidx.compose.ui.res.stringResource
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.ui.res.stringResource
import androidx.compose.material3.*
import androidx.compose.ui.res.stringResource
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.sse.EventSource
import okhttp3.sse.EventSourceListener
import okhttp3.sse.EventSources
import org.json.JSONObject
import java.util.concurrent.TimeUnit

private const val MAX_LINES = 500

data class LogLine(
    val ts: String,
    val source: String,
    val level: String,
    val msg: String,
)

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun RunLogScreen(
    creds: DeviceCredentials,
    slug: String,
    onBack: () -> Unit,
) {
    var lines by remember { mutableStateOf<List<LogLine>>(emptyList()) }
    var error by remember { mutableStateOf<String?>(null) }
    var filter by remember { mutableStateOf("all") }
    val listState = rememberLazyListState()
    val scope = rememberCoroutineScope()

    DisposableEffect(slug, creds.deviceToken) {
        val client = OkHttpClient.Builder()
            .connectTimeout(10, TimeUnit.SECONDS)
            .readTimeout(0, TimeUnit.MILLISECONDS)
            .build()
        val req = Request.Builder()
            .url("${creds.server}/api/harness/${slug}/log/stream?tail=$MAX_LINES")
            .addHeader("Authorization", "Bearer ${creds.deviceToken}")
            .build()
        val source = EventSources.createFactory(client).newEventSource(req, object : EventSourceListener() {
            override fun onEvent(eventSource: EventSource, id: String?, type: String?, data: String) {
                if (type != "log") return
                try {
                    val o = JSONObject(data)
                    val l = LogLine(
                        ts = o.optString("ts", ""),
                        source = o.optString("source", ""),
                        level = o.optString("level", "info"),
                        msg = o.optString("msg", data),
                    )
                    scope.launch {
                        lines = (lines + l).let { if (it.size > MAX_LINES) it.takeLast(MAX_LINES) else it }
                    }
                } catch (_: Throwable) { /* skip malformed */ }
            }
            override fun onFailure(eventSource: EventSource, t: Throwable?, response: Response?) {
                val code = response?.code
                scope.launch {
                    error = when {
                        code == 401 -> "log stream not available to mobile (cookie-auth only). Awaiting backend mobile-JWT variant."
                        code != null -> "stream failed: HTTP $code"
                        else -> "stream failed: ${t?.message ?: "unknown"}"
                    }
                }
            }
        })
        onDispose { source.cancel() }
    }

    LaunchedEffect(lines.size) {
        if (lines.isNotEmpty()) listState.animateScrollToItem(lines.size - 1)
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = {
                    Column {
                        Text(stringResource(R.string.run_log_title), style = MaterialTheme.typography.titleMedium)
                        Text(slug, style = MaterialTheme.typography.bodySmall, fontFamily = FontFamily.Monospace)
                    }
                },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
                    }
                },
            )
        },
    ) { padding ->
        Column(modifier = Modifier.fillMaxSize().padding(padding)) {
            Row(modifier = Modifier.padding(horizontal = 12.dp, vertical = 6.dp), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                listOf("all", "warn", "error").forEach { f ->
                    FilterChip(
                        selected = filter == f,
                        onClick = { filter = f },
                        label = { Text(f) },
                    )
                }
                Spacer(Modifier.weight(1f))
                Text("${visibleCount(lines, filter)}/${lines.size}", style = MaterialTheme.typography.labelSmall)
            }
            error?.let {
                Card(
                    modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 4.dp),
                    colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.errorContainer),
                ) { Text(it, modifier = Modifier.padding(10.dp), style = MaterialTheme.typography.bodySmall) }
            }
            LazyColumn(
                state = listState,
                modifier = Modifier.fillMaxSize().background(Color.Black).padding(horizontal = 6.dp),
            ) {
                items(lines.filter { matches(it, filter) }) { line ->
                    LineRow(line)
                }
            }
        }
    }
}

private fun visibleCount(lines: List<LogLine>, filter: String): Int =
    lines.count { matches(it, filter) }

private fun matches(line: LogLine, filter: String): Boolean = when (filter) {
    "all" -> true
    "warn" -> line.level == "warn" || line.level == "error"
    "error" -> line.level == "error"
    else -> true
}

@Composable
private fun LineRow(line: LogLine) {
    val color = when (line.level) {
        "error" -> Color(0xFFEF4444)
        "warn" -> Color(0xFFF59E0B)
        "decision" -> Color(0xFF22D3EE)
        "iteration" -> Color(0xFF34D399)
        "plan" -> Color(0xFFA78BFA)
        else -> Color(0xFFD4D4D4)
    }
    val time = line.ts.takeLast(13).take(8)
    Text(
        "$time ${line.source} ${line.msg}",
        color = color,
        fontFamily = FontFamily.Monospace,
        style = MaterialTheme.typography.bodySmall,
    )
}
