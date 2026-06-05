// SPDX-License-Identifier: GPL-3.0-or-later
package com.papercuspai.operator.mobile

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import com.papercuspai.operator.mobile.theme.PapercupColors
import com.papercuspai.operator.mobile.theme.PapercupScreenHeader
import com.papercuspai.operator.mobile.theme.PapercupStatusChip
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import okhttp3.sse.EventSource
import okhttp3.sse.EventSourceListener
import okhttp3.sse.EventSources
import org.json.JSONObject
import java.util.concurrent.TimeUnit

/**
 * The Operator tab — a real chat thread on the SHARED operator conversation
 * (the same thread the desktop + TUI use). Reads history from
 * `GET /api/device/operator/conversation` and streams the operator's reply
 * from `POST /api/device/operator/converse` (SSE). Both are device-JWT
 * routes (mobile-apps-revival-redesign D-002/D-003).
 *
 * Wire path is OkHttp-direct (the same pattern RunLogScreen uses for the
 * harness log SSE) — the conversation read/converse are simple device
 * routes the Android core doesn't need a bespoke binding for. The voice FAB
 * (hoisted in the shell) feeds the SAME thread via the EL voice path.
 */
private data class ChatTurn(
    val seq: Long,
    val role: String, // "user" | "assistant" | "system"
    val text: String,
    val streaming: Boolean = false,
)

/** Strip the operator's voice `<say>…</say>` wrapper for text display. */
private fun displayText(raw: String): String {
    val say = Regex("(?s)<say>(.*?)</say>").findAll(raw).joinToString("\n") { it.groupValues[1].trim() }
    val stripped = if (say.isNotBlank()) say else raw.replace(Regex("(?s)</?say>"), "")
    return stripped.trim().ifBlank { raw.trim() }
}

private val JSON = "application/json; charset=utf-8".toMediaType()

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun OperatorChatScreen(
    creds: DeviceCredentials,
    liveTick: Int,
) {
    var turns by remember { mutableStateOf<List<ChatTurn>>(emptyList()) }
    var input by remember { mutableStateOf("") }
    var sending by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var conversationId by remember { mutableStateOf<String?>(null) }
    var reloadTick by remember { mutableStateOf(0) }
    val listState = rememberLazyListState()
    val scope = rememberCoroutineScope()

    val http = remember {
        OkHttpClient.Builder()
            .connectTimeout(10, TimeUnit.SECONDS)
            .readTimeout(0, TimeUnit.MILLISECONDS)
            .build()
    }

    // Load the shared thread's recent turns. Re-runs on liveTick (a push or
    // a desktop turn invalidates) and after we send.
    LaunchedEffect(creds.deviceToken, liveTick, reloadTick) {
        // Don't clobber an in-progress streamed reply.
        if (sending) return@LaunchedEffect
        try {
            val body = withContext(Dispatchers.IO) {
                val req = Request.Builder()
                    .url("${creds.server}/api/device/operator/conversation?limit=50")
                    .addHeader("Authorization", "Bearer ${creds.deviceToken}")
                    .build()
                http.newCall(req).execute().use { resp ->
                    if (!resp.isSuccessful) throw RuntimeException("HTTP ${resp.code}")
                    resp.body?.string() ?: "{}"
                }
            }
            val o = JSONObject(body)
            conversationId = o.optJSONObject("conversation")?.optString("id")
            val arr = o.optJSONArray("turns")
            val loaded = buildList {
                if (arr != null) for (i in 0 until arr.length()) {
                    val t = arr.getJSONObject(i)
                    add(
                        ChatTurn(
                            seq = t.optLong("seq", i.toLong()),
                            role = t.optString("role", "assistant"),
                            text = displayText(t.optString("text", "")),
                        ),
                    )
                }
            }
            turns = loaded
            error = null
        } catch (t: Throwable) {
            error = t.message ?: t::class.simpleName ?: "Failed to load conversation"
        }
    }

    LaunchedEffect(turns.size) {
        if (turns.isNotEmpty()) listState.animateScrollToItem(turns.size - 1)
    }

    fun send() {
        val text = input.trim()
        if (text.isBlank() || sending) return
        input = ""
        error = null
        sending = true
        // Optimistic user bubble + a streaming assistant bubble.
        val userSeq = (turns.maxOfOrNull { it.seq } ?: -1L) + 1
        turns = turns + ChatTurn(userSeq, "user", text) +
            ChatTurn(userSeq + 1, "assistant", "", streaming = true)

        val payload = JSONObject().put("text", text).put("modality", "text").toString()
        val req = Request.Builder()
            .url("${creds.server}/api/device/operator/converse")
            .addHeader("Authorization", "Bearer ${creds.deviceToken}")
            .post(payload.toRequestBody(JSON))
            .build()

        val sb = StringBuilder()
        EventSources.createFactory(http).newEventSource(
            req,
            object : EventSourceListener() {
                override fun onEvent(es: EventSource, id: String?, type: String?, data: String) {
                    when (type) {
                        "delta" -> {
                            val piece = runCatching { JSONObject(data).optString("text", "") }.getOrDefault("")
                            if (piece.isNotEmpty()) {
                                sb.append(piece)
                                val shown = displayText(sb.toString())
                                scope.launch {
                                    turns = turns.dropLast(1) +
                                        ChatTurn(userSeq + 1, "assistant", shown, streaming = true)
                                }
                            }
                        }
                        "error" -> {
                            val msg = runCatching { JSONObject(data).optString("message", data) }.getOrDefault(data)
                            scope.launch { error = msg }
                        }
                    }
                }

                override fun onClosed(es: EventSource) {
                    scope.launch {
                        val finalText = displayText(sb.toString())
                        turns = turns.dropLast(1) +
                            ChatTurn(userSeq + 1, "assistant", finalText.ifBlank { "…" })
                        sending = false
                        reloadTick += 1 // reconcile against the persisted thread
                    }
                }

                override fun onFailure(es: EventSource, t: Throwable?, response: Response?) {
                    scope.launch {
                        // If we streamed anything, keep it; otherwise drop the empty bubble.
                        val streamed = displayText(sb.toString())
                        turns = if (streamed.isBlank()) {
                            turns.dropLast(1)
                        } else {
                            turns.dropLast(1) + ChatTurn(userSeq + 1, "assistant", streamed)
                        }
                        error = response?.let { "stream failed: HTTP ${it.code}" }
                            ?: ("stream failed: " + (t?.message ?: "unknown"))
                        sending = false
                    }
                }
            },
        )
    }

    Scaffold(
        topBar = {
            PapercupScreenHeader(
                title = "Operator",
                subtitle = if (sending) "thinking…" else "shared thread",
            )
        },
        containerColor = PapercupColors.Ink,
    ) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .background(PapercupColors.ScreenGradient)
                .padding(padding),
        ) {
            error?.let {
                Surface(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 12.dp, vertical = 6.dp),
                    shape = RoundedCornerShape(14.dp),
                    color = PapercupColors.ErrorSoft,
                ) {
                    Text(
                        text = it,
                        modifier = Modifier.padding(horizontal = 12.dp, vertical = 8.dp),
                        style = MaterialTheme.typography.bodySmall,
                        color = PapercupColors.Error,
                        fontFamily = FontFamily.Monospace,
                    )
                }
            }
            LazyColumn(
                state = listState,
                modifier = Modifier
                    .weight(1f)
                    .fillMaxWidth()
                    .padding(horizontal = 12.dp),
                contentPadding = PaddingValues(top = 8.dp, bottom = 12.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                if (turns.isEmpty()) {
                    item {
                        Box(
                            Modifier.fillMaxWidth().padding(top = 48.dp),
                            contentAlignment = Alignment.Center,
                        ) {
                            Text(
                                "Ask the operator anything.",
                                style = MaterialTheme.typography.bodyMedium,
                                color = PapercupColors.TextMuted,
                            )
                        }
                    }
                }
                items(turns) { turn -> ChatBubble(turn) }
            }
            ChatComposer(
                value = input,
                enabled = !sending,
                onValueChange = { input = it },
                onSend = { send() },
            )
        }
    }
}

@Composable
private fun ChatBubble(turn: ChatTurn) {
    val isUser = turn.role == "user"
    val isSystem = turn.role == "system"
    val bubbleColor = when {
        isUser -> PapercupColors.AccentSoft
        isSystem -> PapercupColors.WarningSoft
        else -> PapercupColors.InkRaised
    }
    val textColor = when {
        isUser -> PapercupColors.AccentStrong
        isSystem -> PapercupColors.Warning
        else -> PapercupColors.Text
    }
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = if (isUser) Arrangement.End else Arrangement.Start,
    ) {
        Surface(
            modifier = Modifier
                .widthIn(max = 320.dp)
                .clip(RoundedCornerShape(16.dp))
                .border(1.dp, textColor.copy(alpha = 0.22f), RoundedCornerShape(16.dp)),
            color = bubbleColor,
            shape = RoundedCornerShape(16.dp),
        ) {
            Column(
                modifier = Modifier.padding(horizontal = 12.dp, vertical = 9.dp),
                verticalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                if (!isUser) {
                    PapercupStatusChip(
                        text = if (isSystem) "system" else "operator",
                        containerColor = bubbleColor,
                        contentColor = textColor.copy(alpha = 0.8f),
                    )
                }
                Text(
                    text = turn.text.ifBlank { if (turn.streaming) "…" else "" },
                    style = MaterialTheme.typography.bodyMedium,
                    color = textColor,
                )
            }
        }
    }
}

@Composable
private fun ChatComposer(
    value: String,
    enabled: Boolean,
    onValueChange: (String) -> Unit,
    onSend: () -> Unit,
) {
    Surface(
        color = PapercupColors.InkRaised,
        modifier = Modifier.fillMaxWidth(),
        tonalElevation = 3.dp,
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .windowInsetsPadding(WindowInsets.systemBars.only(WindowInsetsSides.Bottom))
                .padding(horizontal = 12.dp, vertical = 10.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            OutlinedTextField(
                value = value,
                onValueChange = onValueChange,
                modifier = Modifier.weight(1f),
                placeholder = { Text("Message the operator…") },
                enabled = enabled,
                maxLines = 4,
            )
            Button(
                onClick = onSend,
                enabled = enabled && value.isNotBlank(),
                colors = ButtonDefaults.buttonColors(
                    containerColor = PapercupColors.AccentStrong,
                    contentColor = PapercupColors.ButtonInk,
                    disabledContainerColor = PapercupColors.AccentStrong.copy(alpha = 0.36f),
                    disabledContentColor = PapercupColors.ButtonInk.copy(alpha = 0.7f),
                ),
            ) {
                Text(if (enabled) "Send" else "…")
            }
        }
    }
}
