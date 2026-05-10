// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import AVFoundation

struct VoiceSettingsView: View {
    @State private var prefs: VoicePrefs = VoicePrefsStore.load()
    @State private var voices: [AVSpeechSynthesisVoice] = []
    @State private var synth = AVSpeechSynthesizer()

    var body: some View {
        Form {
            Section("Wake word") {
                TextField("hey papercup", text: $prefs.wakeWord)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                Text("Picovoice Porcupine accepts only its trained keyword set; this field is the wake-phrase shown to the voice WS server. Hot-reload requires app restart.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Section("Speech rate: \(String(format: "%.2f", prefs.rate))") {
                Slider(value: $prefs.rate, in: 0.5...2.0)
            }
            Section("Pitch: \(String(format: "%.2f", prefs.pitch))") {
                Slider(value: $prefs.pitch, in: 0.5...2.0)
            }

            Section("Voice") {
                if voices.isEmpty {
                    Text("No system voices loaded.").foregroundStyle(.secondary)
                } else {
                    Picker("Voice", selection: Binding(
                        get: { prefs.voiceIdentifier ?? "" },
                        set: { prefs.voiceIdentifier = $0.isEmpty ? nil : $0 }
                    )) {
                        Text("System default").tag("")
                        ForEach(voices, id: \.identifier) { v in
                            Text("\(v.name) (\(v.language))").tag(v.identifier)
                        }
                    }
                }
            }

            Section {
                HStack {
                    Button("Test") { test() }
                        .buttonStyle(.borderedProminent)
                        .frame(maxWidth: .infinity)
                    Button("Reset") { prefs = VoicePrefs() }
                        .buttonStyle(.bordered)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .navigationTitle("Voice")
        .onAppear {
            voices = AVSpeechSynthesisVoice.speechVoices().filter {
                $0.language.hasPrefix(Locale.current.language.languageCode?.identifier ?? "en")
            }
        }
        .onChange(of: prefs) { _, new in VoicePrefsStore.save(new) }
    }

    private func test() {
        let utt = AVSpeechUtterance(string: "Operator mobile voice test, one two three.")
        utt.rate = prefs.rate * AVSpeechUtteranceDefaultSpeechRate
        utt.pitchMultiplier = prefs.pitch
        if let id = prefs.voiceIdentifier, let v = voices.first(where: { $0.identifier == id }) {
            utt.voice = v
        }
        synth.stopSpeaking(at: .immediate)
        synth.speak(utt)
    }
}
