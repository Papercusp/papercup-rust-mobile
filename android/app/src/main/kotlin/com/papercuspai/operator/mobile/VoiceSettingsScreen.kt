// SPDX-License-Identifier: GPL-3.0-or-later
package com.papercuspai.operator.mobile

import android.speech.tts.TextToSpeech
import android.speech.tts.Voice
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import java.util.Locale

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun VoiceSettingsScreen(onBack: () -> Unit) {
    val ctx = LocalContext.current
    val store = remember { VoicePrefsStore(ctx) }
    var prefs by remember { mutableStateOf(store.load()) }

    var ttsReady by remember { mutableStateOf(false) }
    var voices by remember { mutableStateOf<List<Voice>>(emptyList()) }
    val tts = remember {
        TextToSpeech(ctx) {}
    }
    DisposableEffect(Unit) {
        tts.setOnUtteranceProgressListener(null)
        tts.language = Locale.getDefault()
        ttsReady = true
        voices = tts.voices?.toList()?.filter { it.locale.language == Locale.getDefault().language }
            ?: emptyList()
        onDispose { tts.stop(); tts.shutdown() }
    }

    fun update(p: VoicePrefs) {
        prefs = p
        store.save(p)
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Voice") },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
                    }
                },
            )
        },
    ) { padding ->
        Column(
            modifier = Modifier.fillMaxSize().padding(padding).padding(16.dp).verticalScroll(rememberScrollState()),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            Card(modifier = Modifier.fillMaxWidth()) {
                Column(modifier = Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text("Wake word", style = MaterialTheme.typography.labelMedium)
                    OutlinedTextField(
                        value = prefs.wakeWord,
                        onValueChange = { update(prefs.copy(wakeWord = it)) },
                        modifier = Modifier.fillMaxWidth(),
                        singleLine = true,
                    )
                    Text(
                        "Picovoice Porcupine accepts only its trained keyword set; this field is " +
                            "the wake-phrase shown to the voice WS server. Hot-reload requires app restart.",
                        style = MaterialTheme.typography.bodySmall,
                    )
                }
            }
            Card(modifier = Modifier.fillMaxWidth()) {
                Column(modifier = Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text("Speech rate: ${"%.2f".format(prefs.rate)}", style = MaterialTheme.typography.labelMedium)
                    Slider(
                        value = prefs.rate,
                        onValueChange = { update(prefs.copy(rate = it)) },
                        valueRange = 0.5f..2.0f,
                    )
                    Text("Pitch: ${"%.2f".format(prefs.pitch)}", style = MaterialTheme.typography.labelMedium)
                    Slider(
                        value = prefs.pitch,
                        onValueChange = { update(prefs.copy(pitch = it)) },
                        valueRange = 0.5f..2.0f,
                    )
                }
            }
            Card(modifier = Modifier.fillMaxWidth()) {
                Column(modifier = Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text("Voice", style = MaterialTheme.typography.labelMedium)
                    if (!ttsReady) {
                        Text("Loading…", style = MaterialTheme.typography.bodySmall)
                    } else if (voices.isEmpty()) {
                        Text("No system voices available.", style = MaterialTheme.typography.bodySmall)
                    } else {
                        var open by remember { mutableStateOf(false) }
                        ExposedDropdownMenuBox(expanded = open, onExpandedChange = { open = !open }) {
                            OutlinedTextField(
                                value = prefs.voiceName ?: "System default",
                                onValueChange = {},
                                readOnly = true,
                                modifier = Modifier.menuAnchor().fillMaxWidth(),
                                trailingIcon = { ExposedDropdownMenuDefaults.TrailingIcon(expanded = open) },
                            )
                            ExposedDropdownMenu(expanded = open, onDismissRequest = { open = false }) {
                                DropdownMenuItem(
                                    text = { Text("System default") },
                                    onClick = { update(prefs.copy(voiceName = null)); open = false },
                                )
                                voices.forEach { v ->
                                    DropdownMenuItem(
                                        text = { Text("${v.name} (${v.locale})") },
                                        onClick = { update(prefs.copy(voiceName = v.name)); open = false },
                                    )
                                }
                            }
                        }
                    }
                }
            }
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Button(
                    onClick = {
                        tts.setSpeechRate(prefs.rate)
                        tts.setPitch(prefs.pitch)
                        prefs.voiceName?.let { name -> voices.firstOrNull { it.name == name }?.let { tts.voice = it } }
                        tts.speak("Operator mobile voice test, one two three.", TextToSpeech.QUEUE_FLUSH, null, "test")
                    },
                    modifier = Modifier.weight(1f),
                    enabled = ttsReady,
                ) { Text("Test") }
                OutlinedButton(
                    onClick = { update(VoicePrefs()) },
                    modifier = Modifier.weight(1f),
                ) { Text("Reset") }
            }
        }
    }
}
