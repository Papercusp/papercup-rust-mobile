// SPDX-License-Identifier: GPL-3.0-or-later
//
// SwiftUI mirror of Android's VoiceManager:
//   - claims the operator voice lease
//   - opens VoiceClient WebSocket via UniFFI
//   - drives SFSpeechRecognizer (continuous STT) + AVSpeechSynthesizer (TTS)
//   - publishes State + micLevel for the UI to render the FAB halo
//
// All Apple-only — no entitlement gates beyond the two Info.plist
// usage strings (NSMicrophoneUsageDescription, NSSpeechRecognitionUsageDescription).

import Foundation
import AVFoundation
import Speech

@MainActor
final class VoiceManager: ObservableObject {
    enum State: Equatable {
        case idle
        case connecting
        case listening
        case speaking(text: String, source: String)
        case failed(message: String)
    }

    @Published private(set) var state: State = .idle
    /// 0…1 normalized RMS of the mic input, polled by the UI for the halo.
    @Published private(set) var micLevel: Float = 0

    /// Phase 4 — local intents dispatched from voice WS Speak frames.
    /// UI subscribes via the published value (single-shot — set then
    /// nil so multiple Navigates each fire onChange).
    @Published var pendingIntent: LocalIntent? = nil

    enum LocalIntent: Equatable {
        case navigate(slug: String)
        case pause
        case resume
        case claimVoice
    }

    private let creds: DeviceCredentials
    private var client: VoiceClient? = nil
    private var pumpTask: Task<Void, Never>? = nil
    private var leaseHeartbeatTask: Task<Void, Never>? = nil

    private let audioEngine = AVAudioEngine()
    private let synth = AVSpeechSynthesizer()
    private var recognizer: SFSpeechRecognizer? = SFSpeechRecognizer()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    init(creds: DeviceCredentials) { self.creds = creds }

    // MARK: - Lifecycle

    func start() {
        guard state == .idle else { return }
        state = .connecting
        Task {
            do {
                try await creds.client().voiceLeaseClaim()
            } catch {
                state = .failed(message: "lease claim failed: \(error)")
                return
            }
            startLeaseHeartbeat()
            await openSocket()
        }
    }

    func stop() {
        pumpTask?.cancel(); pumpTask = nil
        leaseHeartbeatTask?.cancel(); leaseHeartbeatTask = nil
        client?.disconnect(); client = nil
        stopStt()
        synth.stopSpeaking(at: .immediate)
        state = .idle
        Task {
            try? await creds.client().voiceLeaseRelease()
        }
    }

    // MARK: - WebSocket pump

    private func openSocket() async {
        let prefs = VoicePrefsStore.load()
        let c = VoiceClient(baseUrl: creds.server, deviceToken: creds.deviceToken, wakeWord: prefs.wakeWord)
        client = c
        await c.sendHello(wakeWord: prefs.wakeWord)
        await requestSttPermissionAndStart()
        pumpTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled, let c = self.client {
                do {
                    let ev = try await c.nextEvent()
                    await self.handle(ev)
                } catch {
                    self.state = .failed(message: "voice ws: \(error)")
                    break
                }
            }
        }
    }

    private func handle(_ ev: VoiceEvent) async {
        switch ev {
        case .connected:
            state = .listening
        case .speak(let text, let source, _, _):
            // Phase 4: parse any inline directive. Speak the remainder;
            // emit Navigate/Pause/Resume to pendingIntent for the UI.
            let parsed = parseIntent(text: text)
            let toSpeak: String
            switch parsed {
            case .navigate(let slug, let speak):
                pendingIntent = .navigate(slug: slug)
                toSpeak = speak
            case .pause(let speak):
                pendingIntent = .pause
                toSpeak = speak
            case .resume(let speak):
                pendingIntent = .resume
                toSpeak = speak
            case .claimVoice(let speak):
                pendingIntent = .claimVoice
                toSpeak = speak
            case .speak(let t):
                toSpeak = t
            }
            state = .speaking(text: toSpeak, source: source)
            if !toSpeak.isEmpty { speak(toSpeak) }
        case .closed(let code, let reason):
            state = .failed(message: "voice ws closed code=\(code) \(reason)")
        }
    }

    private func startLeaseHeartbeat() {
        leaseHeartbeatTask?.cancel()
        leaseHeartbeatTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 25_000_000_000)
                try? await OperatorClient(baseUrl: self.creds.server, deviceToken: self.creds.deviceToken).voiceLeaseHeartbeat()
            }
        }
    }

    // MARK: - STT

    private func requestSttPermissionAndStart() async {
        let granted = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status == .authorized)
            }
        }
        guard granted, recognizer?.isAvailable == true else {
            state = .failed(message: "speech recognition not authorized")
            return
        }
        AVAudioApplication.requestRecordPermission { _ in }
        startStt()
    }

    private func startStt() {
        stopStt()
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers, .defaultToSpeaker])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            state = .failed(message: "audio session: \(error)")
            return
        }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = false
        request = req

        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buf, _ in
            guard let self else { return }
            req.append(buf)
            let level = Self.rms(buf)
            Task { @MainActor in self.micLevel = level }
        }
        audioEngine.prepare()
        do { try audioEngine.start() } catch {
            state = .failed(message: "audio engine: \(error)")
            return
        }
        recognitionTask = recognizer?.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }
            if let r = result, r.isFinal {
                let text = r.bestTranscription.formattedString
                Task { await self.client?.sendTranscript(text: text) }
            }
            if error != nil {
                Task { @MainActor in self.startStt() }
            }
        }
    }

    private func stopStt() {
        recognitionTask?.cancel(); recognitionTask = nil
        request?.endAudio(); request = nil
        if audioEngine.isRunning { audioEngine.stop() }
        audioEngine.inputNode.removeTap(onBus: 0)
        micLevel = 0
    }

    private static func rms(_ buf: AVAudioPCMBuffer) -> Float {
        guard let ch = buf.floatChannelData?[0] else { return 0 }
        let n = Int(buf.frameLength)
        guard n > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<n { let s = ch[i]; sum += s * s }
        let rms = (sum / Float(n)).squareRoot()
        // Compress to a 0…1 halo range; -50 dB ≈ silent, -10 dB ≈ loud.
        let db = 20 * log10(max(rms, 1e-7))
        return min(max((db + 50) / 40, 0), 1)
    }

    // MARK: - TTS

    private func speak(_ text: String) {
        let prefs = VoicePrefsStore.load()
        synth.stopSpeaking(at: .immediate)
        let utt = AVSpeechUtterance(string: text)
        utt.rate = prefs.rate * AVSpeechUtteranceDefaultSpeechRate
        utt.pitchMultiplier = prefs.pitch
        if let id = prefs.voiceIdentifier, let v = AVSpeechSynthesisVoice(identifier: id) {
            utt.voice = v
        }
        synth.speak(utt)
    }
}
