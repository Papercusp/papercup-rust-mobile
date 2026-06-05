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
import uniffi.papercup.ConverseDelta

/**
 * The Operator tab — a real chat thread on the SHARED operator conversation
 * (the same thread the desktop + TUI use). Reads history via the core
 * client's `operatorConversation()` and streams the operator's reply via
 * `operatorConverseStream()` (the Rust core drains the converse SSE and
 * hands back delta fragments through the ConverseDelta callback). Both go
 * through the SAME `OperatorClient` every other screen uses — mesh-aware
 * URL + fallback, one auth path, one error envelope — instead of a
 * bespoke OkHttp SSE wire (mobile-apps-revival-redesign D-002/D-003; the
 * core-converse fold). The voice FAB (hoisted in the shell) feeds the
 * SAME thread via the EL voice path.
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

    // Load the shared thread's recent turns through the core client. Re-runs
    // on liveTick (a push or a desktop turn invalidates) and after we send.
    LaunchedEffect(creds.deviceToken, liveTick, reloadTick) {
        // Don't clobber an in-progress streamed reply.
        if (sending) return@LaunchedEffect
        try {
            val read = withContext(Dispatchers.IO) { creds.client().operatorConversation(50u) }
            conversationId = read.conversationId
            turns = read.turns.map { t ->
                ChatTurn(seq = t.seq, role = t.role, text = displayText(t.text))
            }
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

        // The Rust core drains the converse SSE and pushes each delta back
        // through this callback (it may arrive off the main thread, so hop
        // to the compose scope before touching state).
        val sb = StringBuilder()
        val listener = object : ConverseDelta {
            override fun onDelta(text: String) {
                sb.append(text)
                val shown = displayText(sb.toString())
                scope.launch {
                    turns = turns.dropLast(1) +
                        ChatTurn(userSeq + 1, "assistant", shown, streaming = true)
                }
            }
        }

        scope.launch {
            try {
                withContext(Dispatchers.IO) {
                    creds.client().operatorConverseStream(text, listener)
                }
                val finalText = displayText(sb.toString())
                turns = turns.dropLast(1) +
                    ChatTurn(userSeq + 1, "assistant", finalText.ifBlank { "…" })
                reloadTick += 1 // reconcile against the persisted thread
            } catch (t: Throwable) {
                // If we streamed anything, keep it; otherwise drop the empty bubble.
                val streamed = displayText(sb.toString())
                turns = if (streamed.isBlank()) {
                    turns.dropLast(1)
                } else {
                    turns.dropLast(1) + ChatTurn(userSeq + 1, "assistant", streamed)
                }
                error = t.message ?: t::class.simpleName ?: "stream failed"
            } finally {
                sending = false
            }
        }
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
                // End padding clears the shell's floating voice FAB, which sits
                // bottom-right ABOVE this composer — without it the Send button
                // is rendered underneath the FAB and untappable (found by the
                // on-device E2E pass).
                .padding(start = 12.dp, end = 104.dp, top = 10.dp, bottom = 10.dp),
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
