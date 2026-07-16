// SPDX-License-Identifier: GPL-3.0-or-later
package com.papercuspai.operator.mobile

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.papercuspai.operator.mobile.theme.PapercupCardHeader
import com.papercuspai.operator.mobile.theme.PapercupColors
import com.papercuspai.operator.mobile.theme.PapercupMetaText
import com.papercuspai.operator.mobile.theme.PapercupPanel
import com.papercuspai.operator.mobile.theme.PapercupScreenHeader
import com.papercuspai.operator.mobile.theme.PapercupSectionLabel
import com.papercuspai.operator.mobile.theme.PapercupStatusChip
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

private enum class StreamState {
    Connecting,
    Live,
    Failed,
}

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
    var streamState by remember { mutableStateOf(StreamState.Connecting) }
    val listState = rememberLazyListState()
    val scope = rememberCoroutineScope()
    val visibleLines = remember(lines, filter) { lines.filter { matches(it, filter) } }

    DisposableEffect(slug, creds.deviceToken) {
        lines = emptyList()
        error = null
        streamState = StreamState.Connecting
        val client = OkHttpClient.Builder()
            .connectTimeout(10, TimeUnit.SECONDS)
            .readTimeout(0, TimeUnit.MILLISECONDS)
            .build()
        val req = Request.Builder()
            .url("${creds.server}/api/device/harnesses/${slug}/log/stream?tail=$MAX_LINES")
            .addHeader("Authorization", "Bearer ${creds.deviceToken}")
            .build()
        val source = EventSources.createFactory(client).newEventSource(req, object : EventSourceListener() {
            override fun onOpen(eventSource: EventSource, response: Response) {
                scope.launch { streamState = StreamState.Live }
            }

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
                        error = null
                        streamState = StreamState.Live
                    }
                } catch (_: Throwable) {
                    // Skip malformed log lines.
                }
            }

            override fun onFailure(eventSource: EventSource, t: Throwable?, response: Response?) {
                val code = response?.code
                scope.launch {
                    error = when {
                        code == 401 -> "log stream not available to mobile (cookie-auth only). Awaiting backend mobile-JWT variant."
                        code != null -> "stream failed: HTTP $code"
                        else -> HumanError.fromNetworkText(t?.message ?: "", "The log stream")
                    }
                    streamState = StreamState.Failed
                }
            }
        })
        onDispose {
            source.cancel()
            client.dispatcher.executorService.shutdown()
        }
    }

    LaunchedEffect(lines.size) {
        if (lines.isNotEmpty()) listState.animateScrollToItem(lines.size - 1)
    }

    Scaffold(
        topBar = {
            PapercupScreenHeader(
                title = stringResource(R.string.run_log_title),
                subtitle = slug,
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
                    }
                },
                actions = {
                    StreamChip(streamState)
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
                .padding(horizontal = 12.dp, vertical = 12.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            FilterTray(
                filter = filter,
                total = lines.size,
                visible = visibleLines.size,
                onSelect = { filter = it },
            )
            error?.let { ErrorBanner(it) }
            LogTerminal(
                slug = slug,
                lines = visibleLines,
                totalLines = lines.size,
                listState = listState,
                filter = filter,
            )
        }
    }
}

@Composable
private fun StreamChip(streamState: StreamState) {
    when (streamState) {
        StreamState.Connecting -> PapercupStatusChip(
            text = "connecting",
            containerColor = PapercupColors.WarningSoft,
            contentColor = PapercupColors.Warning,
        )
        StreamState.Live -> PapercupStatusChip(
            text = "live",
            containerColor = PapercupColors.SuccessSoft,
            contentColor = PapercupColors.Success,
        )
        StreamState.Failed -> PapercupStatusChip(
            text = "error",
            containerColor = PapercupColors.ErrorSoft,
            contentColor = PapercupColors.Error,
        )
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun FilterTray(
    filter: String,
    total: Int,
    visible: Int,
    onSelect: (String) -> Unit,
) {
    PapercupPanel(contentPadding = PaddingValues(12.dp)) {
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    PapercupSectionLabel("stream view")
                    Text(
                        text = "$visible shown · $total buffered",
                        style = MaterialTheme.typography.bodyMedium,
                        color = PapercupColors.Text,
                    )
                }
                PapercupMetaText("TAIL $MAX_LINES", monospace = true)
            }
            FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                listOf("all", "warn", "error").forEach { current ->
                    val selected = filter == current
                    PapercupStatusChip(
                        text = current.uppercase(),
                        containerColor = if (selected) PapercupColors.AccentSoft else PapercupColors.InkRaised,
                        contentColor = if (selected) PapercupColors.AccentStrong else PapercupColors.TextMuted,
                        borderColor = if (selected) PapercupColors.AccentStrong.copy(alpha = 0.45f) else PapercupColors.StrokeSoft,
                        onClick = { onSelect(current) },
                        modifier = Modifier.semantics {
                            contentDescription = "Filter $current${if (selected) ", selected" else ""}"
                        },
                    )
                }
            }
        }
    }
}

@Composable
private fun ErrorBanner(message: String) {
    Surface(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(18.dp),
        color = PapercupColors.ErrorSoft,
        border = androidx.compose.foundation.BorderStroke(1.dp, PapercupColors.Error.copy(alpha = 0.35f)),
    ) {
        Text(
            text = message,
            modifier = Modifier.padding(horizontal = 12.dp, vertical = 10.dp),
            style = MaterialTheme.typography.bodySmall,
            color = PapercupColors.Error,
            fontFamily = FontFamily.Monospace,
        )
    }
}

@Composable
private fun LogTerminal(
    slug: String,
    lines: List<LogLine>,
    totalLines: Int,
    listState: androidx.compose.foundation.lazy.LazyListState,
    filter: String,
) {
    PapercupPanel(
        modifier = Modifier.fillMaxSize(),
        contentPadding = PaddingValues(0.dp),
    ) {
        Column(modifier = Modifier.fillMaxSize()) {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .background(PapercupColors.SurfaceStrong.copy(alpha = 0.88f))
                    .border(1.dp, PapercupColors.StrokeSoft)
                    .padding(horizontal = 14.dp, vertical = 12.dp),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    PapercupCardHeader(title = "Terminal", meta = filter.uppercase())
                    Text(
                        text = slug,
                        style = MaterialTheme.typography.bodySmall,
                        color = PapercupColors.TextFaint,
                        fontFamily = FontFamily.Monospace,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
                PapercupMetaText("${lines.size}/$totalLines", monospace = true)
            }
            LazyColumn(
                state = listState,
                modifier = Modifier
                    .fillMaxSize()
                    .background(Color.Black)
                    .padding(horizontal = 10.dp, vertical = 12.dp),
                verticalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                if (lines.isEmpty()) {
                    item {
                        EmptyLogState(filter = filter)
                    }
                } else {
                    itemsIndexed(lines) { index, line ->
                        LineRow(line = line, lineNumber = totalLines - lines.size + index + 1)
                    }
                }
            }
        }
    }
}

@Composable
private fun EmptyLogState(filter: String) {
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .padding(top = 36.dp, bottom = 24.dp),
        contentAlignment = Alignment.Center,
    ) {
        Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Text(
                text = if (filter == "all") "WAITING FOR HARNESS OUTPUT" else "NO ${filter.uppercase()} LINES",
                style = MaterialTheme.typography.labelMedium,
                color = PapercupColors.TextFaint,
            )
            PapercupMetaText(
                text = if (filter == "all") "stream is connected; new lines append automatically" else "switch filters or wait for matching output",
                monospace = true,
            )
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
private fun LineRow(line: LogLine, lineNumber: Int) {
    val color = when (line.level) {
        "error" -> Color(0xFFFB7185)
        "warn" -> Color(0xFFF6C453)
        "decision" -> Color(0xFF67E8F9)
        "iteration" -> Color(0xFF34D399)
        "plan" -> Color(0xFFC4B5FD)
        else -> Color(0xFFD4D4D4)
    }
    val time = line.ts.takeLast(13).take(8).ifBlank { "--:--:--" }
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(10.dp),
        verticalAlignment = Alignment.Top,
    ) {
        Text(
            text = lineNumber.toString().padStart(3, '0'),
            style = MaterialTheme.typography.labelSmall,
            color = PapercupColors.TextFaint,
            fontFamily = FontFamily.Monospace,
        )
        Column(
            modifier = Modifier.weight(1f),
            verticalArrangement = Arrangement.spacedBy(2.dp),
        ) {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                Text(
                    text = time,
                    style = MaterialTheme.typography.labelSmall,
                    color = PapercupColors.TextFaint,
                    fontFamily = FontFamily.Monospace,
                )
                if (line.source.isNotBlank()) {
                    Text(
                        text = line.source.uppercase(),
                        style = MaterialTheme.typography.labelSmall,
                        color = PapercupColors.TextMuted,
                        fontFamily = FontFamily.Monospace,
                    )
                }
                Text(
                    text = line.level.uppercase(),
                    style = MaterialTheme.typography.labelSmall,
                    color = color,
                    fontFamily = FontFamily.Monospace,
                )
            }
            Text(
                text = line.msg,
                style = MaterialTheme.typography.bodySmall,
                color = color,
                fontFamily = FontFamily.Monospace,
            )
        }
    }
}
