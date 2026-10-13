// SPDX-License-Identifier: GPL-3.0-or-later
package com.papercuspai.operator.mobile

import android.speech.tts.TextToSpeech
import android.speech.tts.Voice
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
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
import java.util.Locale
import kotlinx.coroutines.launch
import okhttp3.MediaType.Companion.toMediaTypeOrNull
import okhttp3.RequestBody.Companion.toRequestBody

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun VoiceSettingsScreen(onBack: () -> Unit) {
    val ctx = androidx.compose.ui.platform.LocalContext.current
    val store = remember { VoicePrefsStore(ctx) }
    var prefs by remember { mutableStateOf(store.load()) }
    var ttsReady by remember { mutableStateOf(false) }
    var voices by remember { mutableStateOf<List<Voice>>(emptyList()) }

    val tts = remember { TextToSpeech(ctx) {} }
    DisposableEffect(Unit) {
        tts.setOnUtteranceProgressListener(null)
        tts.language = Locale.getDefault()
        ttsReady = true
        voices = tts.voices?.toList()?.filter { it.locale.language == Locale.getDefault().language } ?: emptyList()
        onDispose {
            tts.stop()
            tts.shutdown()
        }
    }

    fun update(next: VoicePrefs) {
        prefs = next
        store.save(next)
    }

    Scaffold(
        topBar = {
            PapercupScreenHeader(
                title = stringResource(R.string.voice_settings_title),
                subtitle = prefs.voiceName ?: stringResource(R.string.voice_settings_system_default),
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

            // Performance HUD — refreshed when the screen comes into
            // composition. Stats survive app restarts (SharedPreferences).
            PerformanceHud(ctx)

            // Diagnostic — runs a no-mint probe against heartbeat +
            // session-init so a user hitting "voice unavailable" can
            // tell whether it's the pair, the server, or EL.
            VoicePathDiagnostic(ctx)

            // Desktop transport route (desktop-local voice, P-006) — which
            // path (mesh / lan / tunnel) the voice turns stream over.
            DesktopRouteRow()

            SectionShell(title = "Conversation mode") {
                VoiceModeRow(prefs.voiceMode) { mode -> update(prefs.copy(voiceMode = mode)) }
                HorizontalDivider(color = PapercupColors.StrokeSoft.copy(alpha = 0.55f))
                PapercupMetaText(
                    text = when (prefs.voiceMode) {
                        VoiceMode.Continuous -> "Hands-free conversation, ChatGPT-style. Session stays open until you tap to end or it idles out."
                        VoiceMode.Hybrid -> "Continuous, but the agent hangs up after definitive answers (\"marked done\"). Best of both."
                        VoiceMode.SingleUtterance -> "One question, one answer, then disconnect. Cheapest. Best on cellular."
                    },
                    modifier = Modifier.padding(horizontal = 16.dp, vertical = 12.dp),
                )
            }

            SectionShell(title = "Timers") {
                IntInputRow(
                    label = "Auto-disconnect (min)",
                    helper = "User-silence cap. 0 uses workspace default.",
                    value = prefs.idleTimeoutMin,
                    onChange = { update(prefs.copy(idleTimeoutMin = it)) },
                )
                HorizontalDivider(color = PapercupColors.StrokeSoft.copy(alpha = 0.55f))
                IntInputRow(
                    label = "Session max (min)",
                    helper = "Hard ceiling regardless of activity. 0 uses workspace default.",
                    value = prefs.sessionMaxMin,
                    onChange = { update(prefs.copy(sessionMaxMin = it)) },
                )
            }

            SectionShell(title = "Wake word") {
                val keyword = remember(ctx) { WakeWordEngine.configuredKeyword(ctx) }
                PapercupMetaText(
                    text = if (keyword == null) "Wake-word listening is unavailable. Tap Listen to start voice."
                    else "Say \"$keyword\" to start voice.",
                    modifier = Modifier.padding(horizontal = 16.dp, vertical = 12.dp),
                )
            }

            SectionShell(title = "Speech rate") {
                SliderRow(
                    value = prefs.rate,
                    valueLabel = String.format(Locale.US, "%.2f", prefs.rate),
                    onValueChange = { update(prefs.copy(rate = it)) },
                    valueRange = 0.5f..2.0f,
                )
            }

            SectionShell(title = "Pitch") {
                SliderRow(
                    value = prefs.pitch,
                    valueLabel = String.format(Locale.US, "%.2f", prefs.pitch),
                    onValueChange = { update(prefs.copy(pitch = it)) },
                    valueRange = 0.5f..2.0f,
                )
            }

            SectionShell(title = "Voice") {
                if (!ttsReady) {
                    PapercupMetaText(
                        text = stringResource(R.string.loading),
                        modifier = Modifier.padding(horizontal = 16.dp, vertical = 12.dp),
                    )
                } else if (voices.isEmpty()) {
                    PapercupMetaText(
                        text = stringResource(R.string.voice_settings_no_voices),
                        modifier = Modifier.padding(horizontal = 16.dp, vertical = 12.dp),
                    )
                } else {
                    var open by remember { mutableStateOf(false) }
                    ExposedDropdownMenuBox(
                        expanded = open,
                        onExpandedChange = { open = !open },
                        modifier = Modifier.padding(horizontal = 12.dp, vertical = 12.dp),
                    ) {
                        OutlinedTextField(
                            value = prefs.voiceName ?: stringResource(R.string.voice_settings_system_default),
                            onValueChange = {},
                            readOnly = true,
                            modifier = Modifier
                                .menuAnchor(type = MenuAnchorType.PrimaryNotEditable, enabled = true)
                                .fillMaxWidth(),
                            trailingIcon = { ExposedDropdownMenuDefaults.TrailingIcon(expanded = open) },
                            colors = outlinedFieldColors(),
                        )
                        ExposedDropdownMenu(expanded = open, onDismissRequest = { open = false }) {
                            DropdownMenuItem(
                                text = { Text(stringResource(R.string.voice_settings_system_default)) },
                                onClick = {
                                    update(prefs.copy(voiceName = null))
                                    open = false
                                },
                            )
                            voices.forEach { voice ->
                                DropdownMenuItem(
                                    text = { Text("${voice.name} (${voice.locale})") },
                                    onClick = {
                                        update(prefs.copy(voiceName = voice.name))
                                        open = false
                                    },
                                )
                            }
                        }
                    }
                }
            }

            PapercupCard(
                modifier = Modifier.fillMaxWidth(),
                contentPadding = PaddingValues(12.dp),
            ) {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    Button(
                        onClick = {
                            tts.setSpeechRate(prefs.rate)
                            tts.setPitch(prefs.pitch)
                            prefs.voiceName?.let { name -> voices.firstOrNull { it.name == name }?.let { tts.voice = it } }
                            tts.speak("Operator mobile voice test, one two three.", TextToSpeech.QUEUE_FLUSH, null, "test")
                        },
                        modifier = Modifier.weight(1f),
                        enabled = ttsReady,
                        colors = ButtonDefaults.buttonColors(
                            containerColor = PapercupColors.AccentStrong,
                            contentColor = PapercupColors.ButtonInk,
                        ),
                    ) {
                        Text(stringResource(R.string.voice_settings_test_button))
                    }
                    OutlinedButton(
                        onClick = { update(VoicePrefs()) },
                        modifier = Modifier.weight(1f),
                        colors = ButtonDefaults.outlinedButtonColors(contentColor = PapercupColors.Text),
                        border = androidx.compose.foundation.BorderStroke(1.dp, PapercupColors.StrokeSoft),
                    ) {
                        Text(stringResource(R.string.voice_settings_reset_button))
                    }
                }
            }
            Spacer(Modifier.height(12.dp))
        }
    }
}

@Composable
private fun SectionShell(
    title: String,
    content: @Composable ColumnScope.() -> Unit,
) {
    PapercupCard(
        modifier = Modifier.fillMaxWidth(),
        contentPadding = PaddingValues(0.dp),
    ) {
        Column {
            Text(
                text = title.uppercase(),
                modifier = Modifier.padding(horizontal = 16.dp, vertical = 12.dp),
                style = MaterialTheme.typography.labelSmall,
                color = PapercupColors.TextMuted,
            )
            HorizontalDivider(color = PapercupColors.StrokeSoft)
            Column(content = content)
        }
    }
}

@Composable
private fun SliderRow(
    value: Float,
    valueLabel: String,
    onValueChange: (Float) -> Unit,
    valueRange: ClosedFloatingPointRange<Float>,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Slider(
            value = value,
            onValueChange = onValueChange,
            valueRange = valueRange,
            modifier = Modifier.weight(1f),
            colors = SliderDefaults.colors(
                thumbColor = PapercupColors.AccentStrong,
                activeTrackColor = PapercupColors.AccentStrong,
                inactiveTrackColor = PapercupColors.StrokeSoft,
            ),
        )
        Text(
            text = valueLabel,
            style = MaterialTheme.typography.bodySmall,
            color = PapercupColors.Text,
            fontFamily = FontFamily.Monospace,
        )
    }
}

@Composable
private fun VoiceModeRow(current: VoiceMode, onPick: (VoiceMode) -> Unit) {
    Column(modifier = Modifier.padding(horizontal = 12.dp, vertical = 12.dp)) {
        VoiceMode.values().forEach { mode ->
            val label = when (mode) {
                VoiceMode.Continuous -> "Continuous"
                VoiceMode.Hybrid -> "Hybrid"
                VoiceMode.SingleUtterance -> "Single utterance"
            }
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(vertical = 4.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                RadioButton(
                    selected = current == mode,
                    onClick = { onPick(mode) },
                    colors = RadioButtonDefaults.colors(
                        selectedColor = PapercupColors.AccentStrong,
                        unselectedColor = PapercupColors.StrokeSoft,
                    ),
                )
                Spacer(Modifier.width(4.dp))
                Text(label, color = PapercupColors.Text, style = MaterialTheme.typography.bodyMedium)
            }
        }
    }
}

@Composable
private fun IntInputRow(label: String, helper: String, value: Int, onChange: (Int) -> Unit) {
    Column(modifier = Modifier.padding(horizontal = 12.dp, vertical = 12.dp)) {
        Text(label, color = PapercupColors.Text, style = MaterialTheme.typography.labelMedium)
        OutlinedTextField(
            value = if (value == 0) "" else value.toString(),
            onValueChange = { s ->
                val v = s.toIntOrNull()?.coerceIn(0, 240) ?: 0
                onChange(v)
            },
            placeholder = { Text("default") },
            singleLine = true,
            modifier = Modifier.fillMaxWidth(),
            colors = outlinedFieldColors(),
        )
        PapercupMetaText(text = helper, modifier = Modifier.padding(top = 4.dp))
    }
}

@Composable
private fun PerformanceHud(ctx: android.content.Context) {
    // Recomputed each composition; cheap (max 50 samples).
    val firstWord = remember { VoiceMetrics.firstWordStats(ctx) }
    val sessionLen = remember { VoiceMetrics.sessionLenStats(ctx) }
    SectionShell(title = "Performance") {
        Column(modifier = Modifier.padding(horizontal = 16.dp, vertical = 12.dp)) {
            if (firstWord.count == 0 && sessionLen.count == 0) {
                Text(
                    "No samples yet. Use voice once and come back.",
                    style = MaterialTheme.typography.bodySmall,
                    color = PapercupColors.TextMuted,
                )
            } else {
                StatRow("First word", firstWord, formatMs = true)
                Spacer(Modifier.height(8.dp))
                StatRow("Session", sessionLen, formatMs = false)
            }
            Spacer(Modifier.height(8.dp))
            TextButton(
                onClick = { VoiceMetrics.reset(ctx) },
                colors = ButtonDefaults.textButtonColors(contentColor = PapercupColors.TextMuted),
            ) {
                Text("Reset samples")
            }
        }
    }
}

@Composable
private fun StatRow(label: String, stats: VoiceMetrics.Stats, formatMs: Boolean) {
    Row(modifier = Modifier.fillMaxWidth()) {
        Text(
            label,
            modifier = Modifier.weight(1f),
            style = MaterialTheme.typography.bodyMedium,
            color = PapercupColors.Text,
        )
        Text(
            text = if (stats.count == 0) "—"
            else if (formatMs) "p50 ${stats.p50}ms · p95 ${stats.p95}ms · n=${stats.count}"
            else "p50 ${stats.p50 / 1000}s · p95 ${stats.p95 / 1000}s · n=${stats.count}",
            style = MaterialTheme.typography.bodySmall,
            color = PapercupColors.TextMuted,
            fontFamily = FontFamily.Monospace,
        )
    }
}

@Composable
private fun outlinedFieldColors() = OutlinedTextFieldDefaults.colors(
    focusedBorderColor = PapercupColors.AccentStrong,
    unfocusedBorderColor = PapercupColors.StrokeSoft,
    focusedTextColor = PapercupColors.Text,
    unfocusedTextColor = PapercupColors.Text,
    cursorColor = PapercupColors.AccentStrong,
    focusedContainerColor = PapercupColors.InkRaised,
    unfocusedContainerColor = PapercupColors.InkRaised,
)

private sealed interface ProbeResult {
    data object Idle : ProbeResult
    data object Running : ProbeResult
    data class Success(
        val heartbeatMs: Long,
        val sessionInitMs: Long,
    ) : ProbeResult
    data class Failure(val stage: String, val detail: String) : ProbeResult
}

/// End-to-end probe that hits heartbeat + voice-session-init and
/// reports per-stage latency. Helps a user distinguish "pair broken"
/// from "server slow" from "EL down" without burning a voice session.
@Composable
private fun VoicePathDiagnostic(ctx: android.content.Context) {
    var result by remember { mutableStateOf<ProbeResult>(ProbeResult.Idle) }
    val scope = rememberCoroutineScope()

    SectionShell(title = "Voice path diagnostic") {
        Column(modifier = Modifier.padding(horizontal = 16.dp, vertical = 12.dp)) {
            when (val r = result) {
                ProbeResult.Idle -> {
                    Text(
                        "Runs a no-mint probe against heartbeat + session-init. Doesn't burn EL minutes.",
                        style = MaterialTheme.typography.bodySmall,
                        color = PapercupColors.TextMuted,
                    )
                }
                ProbeResult.Running -> {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        CircularProgressIndicator(strokeWidth = 2.dp, modifier = Modifier.size(16.dp))
                        Spacer(Modifier.width(8.dp))
                        Text("Probing…", style = MaterialTheme.typography.bodySmall)
                    }
                }
                is ProbeResult.Success -> {
                    Text(
                        "✓ all good",
                        style = MaterialTheme.typography.bodyMedium,
                        color = PapercupColors.Success,
                    )
                    Spacer(Modifier.height(4.dp))
                    Text(
                        "heartbeat ${r.heartbeatMs}ms · session-init ${r.sessionInitMs}ms",
                        style = MaterialTheme.typography.bodySmall,
                        color = PapercupColors.TextMuted,
                        fontFamily = FontFamily.Monospace,
                    )
                }
                is ProbeResult.Failure -> {
                    Text(
                        "✗ ${r.stage}",
                        style = MaterialTheme.typography.bodyMedium,
                        color = PapercupColors.Error,
                    )
                    Spacer(Modifier.height(4.dp))
                    Text(
                        r.detail,
                        style = MaterialTheme.typography.bodySmall,
                        color = PapercupColors.Error.copy(alpha = 0.85f),
                        fontFamily = FontFamily.Monospace,
                    )
                }
            }
            Spacer(Modifier.height(8.dp))
            val enabled = result != ProbeResult.Running
            TextButton(
                onClick = {
                    result = ProbeResult.Running
                    scope.launch(kotlinx.coroutines.Dispatchers.IO) {
                        result = runVoicePathProbe(ctx)
                    }
                },
                enabled = enabled,
            ) {
                Text(if (result is ProbeResult.Idle) "Run probe" else "Run again")
            }
        }
    }
}

private suspend fun runVoicePathProbe(ctx: android.content.Context): ProbeResult {
    val store = CredentialStore(ctx)
    val creds = store.load() ?: return ProbeResult.Failure(
        "not paired",
        "Pair this device first via the operator desktop.",
    )

    val http = okhttp3.OkHttpClient.Builder()
        .callTimeout(15, java.util.concurrent.TimeUnit.SECONDS)
        .build()

    val heartbeatT0 = System.currentTimeMillis()
    try {
        val req = okhttp3.Request.Builder()
            .url("${creds.server}/api/device/heartbeat")
            .header("Authorization", "Bearer ${creds.deviceToken}")
            .header("content-type", "application/json")
            .post("{}".toRequestBody("application/json".toMediaTypeOrNull()))
            .build()
        http.newCall(req).execute().use { resp ->
            if (!resp.isSuccessful) {
                val body = resp.body?.string()?.take(120) ?: ""
                return ProbeResult.Failure(
                    "heartbeat ${resp.code}",
                    if (resp.code == 401) "Token rejected — re-pair the device."
                    else "Server returned ${resp.code}. $body",
                )
            }
        }
    } catch (t: Throwable) {
        return ProbeResult.Failure(
            "heartbeat unreachable",
            "Couldn't reach ${creds.server}. Check Wi-Fi, Cloudflare tunnel, and that the operator desktop is running. (${t.javaClass.simpleName})",
        )
    }
    val heartbeatMs = System.currentTimeMillis() - heartbeatT0

    val initT0 = System.currentTimeMillis()
    try {
        val req = okhttp3.Request.Builder()
            .url("${creds.server}/api/device/voice-session-init?surface=mobile-android&mode=continuous&probe=1")
            .header("Authorization", "Bearer ${creds.deviceToken}")
            .build()
        http.newCall(req).execute().use { resp ->
            val body = resp.body?.string().orEmpty()
            when {
                resp.isSuccessful -> { /* ok */ }
                resp.code == 429 ->
                    return ProbeResult.Failure(
                        "cooldown",
                        "EL mint cooldown — wait a few seconds and rerun.",
                    )
                resp.code == 503 && body.contains("concurrent_limit") ->
                    return ProbeResult.Failure(
                        "another device has voice",
                        "Close other voice sessions or pre-empt from the FAB.",
                    )
                resp.code == 404 ->
                    return ProbeResult.Failure(
                        "EL not configured",
                        "Open /settings/voice on the desktop and set the agent + API key.",
                    )
                resp.code >= 500 ->
                    return ProbeResult.Failure(
                        "operator brain offline",
                        "${creds.server} returned ${resp.code}. Launch Papercusp on your computer.",
                    )
                else ->
                    return ProbeResult.Failure(
                        "session-init ${resp.code}",
                        body.take(120),
                    )
            }
        }
    } catch (t: Throwable) {
        return ProbeResult.Failure(
            "session-init unreachable",
            "${t.javaClass.simpleName}: ${t.message?.take(120)}",
        )
    }
    val initMs = System.currentTimeMillis() - initT0

    return ProbeResult.Success(heartbeatMs = heartbeatMs, sessionInitMs = initMs)
}

@Composable
private fun DesktopRouteRow() {
    val route by VoiceManager.activeRouteFlow.collectAsState()
    SectionShell(title = "Desktop route") {
        PapercupMetaText(
            text = route
                ?: "Not connected yet — set with the first voice turn (desktop-local mode). Preference: mesh → lan → tunnel.",
        )
    }
}
