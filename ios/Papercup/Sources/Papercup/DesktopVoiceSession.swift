// SPDX-License-Identifier: GPL-3.0-or-later
//
// Desktop-local voice session (on-desktop-direct-lan-voice-2026-07-14
// P-006/P-008) — the EL-free push-to-talk pipeline. The phone is a thin
// audio client and the DESKTOP does STT (local whisper) + brain
// (papercup persona) + TTS (kokoro), all free:
//
//   1. capture PCM via AVAudioEngine, converted to 16kHz mono Int16
//   2. tap again → POST one WAV to `${base}/api/device/voice/turn`
//   3. consume the SSE reply: `transcript` → `delta` (live text) →
//      per-sentence `audio` WAV chunks → `done`
//   4. chunks play sequentially (AVAudioPlayer) starting on the FIRST one
//
// Transport (P-006): probes the voice-session-init `baseUrls` advertise
// list (mesh → lan → tunnel) in parallel while the user is still talking
// and streams the turn over the best reachable path, falling back to the
// paired `creds.server`. ElevenLabs stays fully supported BESIDE this
// (D-010) — VoiceManager dispatches on the session-init `mode`.

import AVFoundation
import Foundation

/// Active desktop transport route ("mesh · http://10.10.0.2:3070") chosen
/// by the desktop-local probe — rendered by VoiceSettingsView (P-006).
final class DesktopRouteStatus: ObservableObject {
    static let shared = DesktopRouteStatus()
    @Published var route: String? = nil
}

final class DesktopVoiceSession: NSObject {
    /// Parsed voice-session-init `mode:'desktop-local'` payload.
    struct InitPayload {
        let turnPath: String
        let warmupPath: String
        let routes: [Route]

        static func from(json: [String: Any]) -> InitPayload {
            var routes: [Route] = []
            if let arr = json["baseUrls"] as? [[String: Any]] {
                for r in arr {
                    var url = (r["url"] as? String) ?? ""
                    while url.hasSuffix("/") { url.removeLast() }
                    if !url.isEmpty {
                        routes.append(Route(kind: (r["kind"] as? String) ?? "lan", url: url))
                    }
                }
            }
            return InitPayload(
                turnPath: json["turnPath"] as? String ?? "/api/device/voice/turn",
                warmupPath: json["warmupPath"] as? String ?? "/api/device/voice/warmup",
                routes: routes
            )
        }
    }

    /// One advertised desktop route: kind is mesh | lan | tunnel.
    struct Route {
        let kind: String
        let url: String
    }

    /// All callbacks are delivered ON THE MAIN QUEUE.
    struct Callbacks {
        let onState: (VoiceManager.State) -> Void
        let onMicLevel: (Float) -> Void
        /// First streamed reply content — feeds the latency HUD.
        let onFirstWord: () -> Void
        let onActiveRoute: (String?) -> Void
        /// Terminal — the turn played out, came back empty, or failed.
        /// The owner clears the session; the next FAB tap starts fresh.
        let onFinished: () -> Void
    }

    private let creds: DeviceCredentials
    private let payload: InitPayload
    private let cb: Callbacks

    private let lock = NSLock()
    private var pcmData = Data()
    private var cancelledFlag = false
    private var cancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelledFlag
    }

    // capture
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var outFormat: AVAudioFormat?
    private var capturing = false
    private var captureStartedAt = Date.distantFuture
    private var capSent = false

    // send
    private var sendTask: Task<Void, Never>?
    private var probeTask: Task<String?, Never>?

    // playback (main queue only)
    private var player: AVAudioPlayer?
    private var playQueue: [Data] = []
    private var playing = false
    private var streamEnded = false
    private var endState: VoiceManager.State?
    private var finished = false

    // ── UITEST voice-parity injection (PAPERCUP_UITEST_VOICE_PCM_DIR) ──
    // Mirrors the Android gRPC-inject soak: the Mac-VM simulator has no
    // input device, so when the env var is set beginCapture() loads the
    // next raw 16kHz mono PCM16 fixture (<dir>/turn-*.pcm, sorted,
    // cycling) instead of tapping the mic. Everything downstream — WAV
    // framing, streamTurn SSE, delta/audio handling, playback, state
    // machine — runs the REAL path, and maybeFinish() writes a per-turn
    // result JSON to <dir>/results/ for the host-side grader.
    private static var injectIndex = 0
    private var injectDir: String? = nil
    private var injectName: String? = nil
    private var sentAt: Date? = nil
    private var lastSpoken = ""
    private var audioChunkCount = 0

    private static func nextInjectedPcm(dir: String) -> (name: String, pcm: Data)? {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir)
            .filter({ $0.hasSuffix(".pcm") }).sorted(), !names.isEmpty else { return nil }
        let name = names[injectIndex % names.count]
        injectIndex += 1
        guard let pcm = fm.contents(atPath: dir + "/" + name) else { return nil }
        return (name, pcm)
    }

    private func writeInjectResult() {
        guard let dir = injectDir else { return }
        let resultsDir = dir + "/results"
        try? FileManager.default.createDirectory(
            atPath: resultsDir, withIntermediateDirectories: true)
        let stateStr: String
        switch endState {
        case .some(.failed(message: let msg, kind: _, retryAfterSec: _)):
            stateStr = "failed: \(msg)"
        default:
            stateStr = "ok"
        }
        let turnMs: Int
        if let sent = sentAt {
            turnMs = Int(Date().timeIntervalSince(sent) * 1000)
        } else {
            turnMs = -1
        }
        let obj: [String: Any] = [
            "fixture": injectName ?? "?",
            "state": stateStr,
            "spoken": lastSpoken,
            "audioChunks": audioChunkCount,
            "turnMs": turnMs,
        ]
        let name = (injectName ?? "turn").replacingOccurrences(of: ".pcm", with: "")
        if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: resultsDir + "/\(name).result.json"))
        }
    }

    init(creds: DeviceCredentials, payload: InitPayload, callbacks: Callbacks) {
        self.creds = creds
        self.payload = payload
        self.cb = callbacks
        super.init()
    }

    // ── lifecycle ────────────────────────────────────────────────────

    /// Start capturing the utterance. Also warms the desktop pipeline
    /// (whisper cold-start is multi-second) and probes the advertised
    /// routes — both while the user is still talking, so neither adds
    /// perceived latency.
    func beginCapture() {
        onMain { self.cb.onState(.listening) }
        let creds = self.creds
        let payload = self.payload
        Task.detached(priority: .utility) {
            await Self.fireWarmup(creds: creds, warmupPath: payload.warmupPath)
        }
        probeTask = Task.detached(priority: .userInitiated) { [weak self] in
            let best = await Self.probeRoutes(creds: creds, routes: payload.routes)
            self?.onMain { self?.cb.onActiveRoute(best.map { "\($0.kind) · \($0.url)" }) }
            return best?.url
        }
        // UITEST injection: bypass the mic entirely (see the block above).
        if let dir = ProcessInfo.processInfo.environment["PAPERCUP_UITEST_VOICE_PCM_DIR"] {
            if let next = Self.nextInjectedPcm(dir: dir) {
                injectDir = dir
                injectName = next.name
                lock.lock()
                pcmData = next.pcm
                lock.unlock()
            } else {
                onMain {
                    self.cb.onState(.failed(
                        message: "UITEST inject: no turn-*.pcm fixtures in \(dir)",
                        kind: .unknown))
                    self.cb.onFinished()
                }
            }
            return
        }
        switch AVAudioSession.sharedInstance().recordPermission {
        case .granted:
            startEngineOrFail()
        case .denied:
            failMic()
        case .undetermined:
            AVAudioSession.sharedInstance().requestRecordPermission { [weak self] granted in
                DispatchQueue.main.async {
                    if granted { self?.startEngineOrFail() } else { self?.failMic() }
                }
            }
        @unknown default:
            failMic()
        }
    }

    /// Second FAB tap: stop recording and send the turn.
    func endUtteranceAndSend() {
        guard sendTask == nil, !cancelled else { return }
        stopEngine()
        let pcm: Data = {
            lock.lock(); defer { lock.unlock() }
            return pcmData
        }()
        // ~0.4s @ 16kHz mono PCM16 — anything shorter is a stray tap.
        guard pcm.count >= 12_800 else {
            onMain {
                self.cb.onState(.failed(message: "Didn't catch that — tap to try again.", kind: .unknown))
                self.cb.onFinished()
            }
            return
        }
        onMain { self.cb.onState(.connecting) }
        sentAt = Date()
        let wav = Self.wavFromPcm16(pcm)
        sendTask = Task { [weak self] in
            guard let self else { return }
            // Probe requests carry short timeouts, so this await is bounded.
            let probed = await self.probeTask?.value
            var base = self.creds.server
            while base.hasSuffix("/") { base.removeLast() }
            do {
                try await self.streamTurn(base: (probed ?? base), wav: wav)
            } catch {
                if !self.cancelled {
                    self.onMain {
                        self.cb.onState(.failed(
                            message: "Voice turn failed — \(error.localizedDescription). Tap to retry.",
                            kind: .networkUnreachable
                        ))
                        self.cb.onFinished()
                    }
                }
            }
        }
    }

    /// Hard cancel: releases the mic, aborts the in-flight HTTP call,
    /// and silences playback. Idempotent.
    func cancel() {
        lock.lock()
        cancelledFlag = true
        lock.unlock()
        stopEngine()
        sendTask?.cancel()
        probeTask?.cancel()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.player?.stop()
            self.player = nil
            self.playQueue.removeAll()
            self.playing = false
        }
    }

    private func failMic() {
        onMain {
            self.cb.onState(.failed(
                message: "Mic unavailable — allow microphone access in Settings.",
                kind: .micPermission
            ))
            self.cb.onFinished()
        }
    }

    // ── capture ──────────────────────────────────────────────────────

    private func startEngineOrFail() {
        do {
            try startEngine()
        } catch {
            onMain {
                self.cb.onState(.failed(
                    message: "Mic setup failed — \(error.localizedDescription)",
                    kind: .micPermission
                ))
                self.cb.onFinished()
            }
        }
    }

    private func startEngine() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .spokenAudio,
                                options: [.defaultToSpeaker, .allowBluetooth])
        try session.setActive(true)
        let input = engine.inputNode
        let hwFormat = input.outputFormat(forBus: 0)
        guard hwFormat.sampleRate > 0,
              let out = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000,
                                      channels: 1, interleaved: true),
              let conv = AVAudioConverter(from: hwFormat, to: out) else {
            throw NSError(domain: "DesktopVoice", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "audio format unavailable"])
        }
        converter = conv
        outFormat = out
        capturing = true
        captureStartedAt = Date()
        capSent = false
        input.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) { [weak self] buffer, _ in
            self?.handleTap(buffer)
        }
        engine.prepare()
        try engine.start()
    }

    /// Runs on the audio tap thread — main-queue hops for every callback.
    private func handleTap(_ buffer: AVAudioPCMBuffer) {
        guard capturing, !cancelled, let conv = converter, let out = outFormat else { return }
        let ratio = out.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let converted = AVAudioPCMBuffer(pcmFormat: out, frameCapacity: capacity) else { return }
        var err: NSError?
        var fed = false
        conv.convert(to: converted, error: &err) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard err == nil else { return }
        let frames = Int(converted.frameLength)
        guard frames > 0, let ch = converted.int16ChannelData else { return }
        let data = Data(bytes: ch[0], count: frames * 2)
        lock.lock()
        pcmData.append(data)
        lock.unlock()

        // Mic level halo (rms of this buffer, normalized).
        var sum = 0.0
        let ptr = ch[0]
        for i in 0..<frames {
            let v = Double(ptr[i])
            sum += v * v
        }
        let rms = (sum / Double(max(1, frames))).squareRoot()
        let level = Float(min(1.0, rms / 6000.0))
        onMain { self.cb.onMicLevel(level) }

        // 60s utterance cap → auto-send.
        if !capSent, Date().timeIntervalSince(captureStartedAt) > 60 {
            capSent = true
            DispatchQueue.main.async { [weak self] in self?.endUtteranceAndSend() }
        }
    }

    private func stopEngine() {
        guard capturing else { return }
        capturing = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        onMain { self.cb.onMicLevel(0) }
    }

    // ── transport ────────────────────────────────────────────────────

    /// Probe every advertised route in parallel (mesh → lan → tunnel
    /// preference); first reachable by preference order wins.
    private static func probeRoutes(creds: DeviceCredentials, routes: [Route]) async -> Route? {
        guard !routes.isEmpty else { return nil }
        var server = creds.server
        while server.hasSuffix("/") { server.removeLast() }
        let results: [(route: Route, ok: Bool)] = await withTaskGroup(
            of: (Int, Bool).self,
            returning: [(Route, Bool)].self
        ) { group in
            for (i, route) in routes.enumerated() {
                group.addTask {
                    if route.url == server { return (i, true) }
                    guard let url = URL(string: "\(route.url)/api/device/runtime-config") else {
                        return (i, false)
                    }
                    var req = URLRequest(url: url)
                    req.setValue("Bearer \(creds.deviceToken)", forHTTPHeaderField: "Authorization")
                    req.timeoutInterval = 2.5
                    do {
                        let (_, resp) = try await URLSession.shared.data(for: req)
                        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                        return (i, (200..<300).contains(code))
                    } catch {
                        return (i, false)
                    }
                }
            }
            var flags = [Bool](repeating: false, count: routes.count)
            for await (i, ok) in group { flags[i] = ok }
            return routes.enumerated().map { ($0.element, flags[$0.offset]) }
        }
        return results.first(where: { $0.ok })?.route
    }

    private static func fireWarmup(creds: DeviceCredentials, warmupPath: String) async {
        var base = creds.server
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + warmupPath) else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(creds.deviceToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = Data("{}".utf8)
        req.timeoutInterval = 20
        _ = try? await URLSession.shared.data(for: req)
    }

    private func streamTurn(base: String, wav: Data) async throws {
        guard let url = URL(string: base + payload.turnPath) else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(creds.deviceToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        // Idle timeout between SSE bytes. A server killed mid-stream can
        // leave the socket open with no reset (NAT'd networks), so this is
        // the only thing that unwedges the turn — keep it above the worst
        // observed silent gap (~70s brain-first-token under pressure) but
        // well under "user gave up".
        req.timeoutInterval = 90
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "audioBase64": wav.base64EncodedString(),
            "format": "wav",
        ])
        let (bytes, resp) = try await URLSession.shared.bytes(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            throw NSError(domain: "VoiceTurn", code: code,
                          userInfo: [NSLocalizedDescriptionKey: "voice-turn HTTP \(code)"])
        }

        // SSE parse. NOTE: AsyncBytes.lines swallows the empty delimiter
        // lines SSE dispatches on, so parse raw bytes ourselves.
        var event = "message"
        var data = ""
        var spoken = ""
        var sawFirst = false
        var failedState: VoiceManager.State?
        var lineBuf = [UInt8]()

        func dispatchFrame() {
            defer {
                event = "message"
                data = ""
            }
            guard !data.isEmpty else { return }
            let payloadStr = data
            switch event {
            case "delta":
                if let obj = Self.json(payloadStr), let text = obj["text"] as? String, !text.isEmpty {
                    if !sawFirst {
                        sawFirst = true
                        onMain { self.cb.onFirstWord() }
                    }
                    spoken += text
                    let display = String(spoken.suffix(400))
                    let full = spoken
                    onMain {
                        self.lastSpoken = full
                        self.cb.onState(.speaking(text: display, source: "agent"))
                    }
                }
            case "audio":
                if let obj = Self.json(payloadStr), let b64 = obj["audioBase64"] as? String,
                   let wavChunk = Data(base64Encoded: b64) {
                    enqueueAudio(wavChunk)
                }
            case "error":
                let obj = Self.json(payloadStr)
                let stage = (obj?["stage"] as? String) ?? "server"
                let message = ((obj?["message"] as? String) ?? payloadStr).prefix(120)
                failedState = .failed(
                    message: "Voice \(stage) error — \(message). Tap to retry.",
                    kind: .unknown
                )
            case "done":
                if let obj = Self.json(payloadStr), (obj["emptyTranscript"] as? Bool) == true {
                    failedState = .failed(message: "Didn't catch that — tap to try again.", kind: .unknown)
                }
            default:
                break // transcript (logged server-side), tts_state, heartbeat, forwarded brain events
            }
        }

        func handleLine(_ line: String) {
            if line.isEmpty {
                dispatchFrame()
            } else if line.hasPrefix(":") {
                // comment
            } else if line.hasPrefix("event:") {
                event = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("data:") {
                var chunk = String(line.dropFirst(5))
                if chunk.hasPrefix(" ") { chunk.removeFirst() }
                data = data.isEmpty ? chunk : data + "\n" + chunk
            } // id: / retry: → ignore
        }

        for try await byte in bytes {
            if cancelled { break }
            if byte == 0x0A {
                if lineBuf.last == 0x0D { lineBuf.removeLast() }
                let line = String(decoding: lineBuf, as: UTF8.self)
                lineBuf.removeAll(keepingCapacity: true)
                handleLine(line)
            } else {
                lineBuf.append(byte)
            }
        }

        let final = failedState
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.streamEnded = true
            self.endState = final
            self.maybeFinish()
        }
    }

    // ── playback (main queue) ────────────────────────────────────────

    private func enqueueAudio(_ wavData: Data) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.cancelled else { return }
            self.audioChunkCount += 1
            // UITEST injection: a headless simulator has no audio output
            // device, so AVAudioPlayer completion never fires — count the
            // chunk (the graded signal) and skip actual playback.
            if self.injectDir != nil { return }
            self.playQueue.append(wavData)
            self.playNextIfIdle()
        }
    }

    private func playNextIfIdle() {
        guard !playing, !cancelled else { return }
        guard !playQueue.isEmpty else {
            maybeFinish()
            return
        }
        let next = playQueue.removeFirst()
        guard let p = try? AVAudioPlayer(data: next) else {
            playNextIfIdle()
            return
        }
        playing = true
        player = p
        p.delegate = self
        if !p.play() {
            // A dead audio route never calls the delegate — don't let it
            // wedge the turn; skip to the next chunk (or finish).
            playing = false
            player = nil
            playNextIfIdle()
        }
    }

    private func maybeFinish() {
        guard streamEnded, !playing, playQueue.isEmpty, !finished else { return }
        finished = true
        if injectDir != nil { writeInjectResult() }
        if !cancelled {
            cb.onState(endState ?? .idle)
        }
        cb.onFinished()
    }

    // ── helpers ──────────────────────────────────────────────────────

    private func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }

    private static func json(_ s: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any]
    }

    /// 44-byte canonical header for 16kHz mono PCM16.
    private static func wavFromPcm16(_ pcm: Data) -> Data {
        var out = Data(capacity: 44 + pcm.count)
        func w32(_ v: UInt32) {
            withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) }
        }
        func w16(_ v: UInt16) {
            withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) }
        }
        out.append(contentsOf: Array("RIFF".utf8)); w32(UInt32(36 + pcm.count))
        out.append(contentsOf: Array("WAVE".utf8))
        out.append(contentsOf: Array("fmt ".utf8)); w32(16)
        w16(1) // PCM
        w16(1) // mono
        w32(16_000)
        w32(32_000) // byte rate
        w16(2) // block align
        w16(16) // bits
        out.append(contentsOf: Array("data".utf8)); w32(UInt32(pcm.count))
        out.append(pcm)
        return out
    }
}

extension DesktopVoiceSession: AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.playing = false
            self.player = nil
            self.playNextIfIdle()
        }
    }
}
