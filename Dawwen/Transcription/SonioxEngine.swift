import AVFoundation
import Foundation

/// Cloud transcription over the Soniox real-time WebSocket API (model stt-rt-v5).
///
/// Protocol (soniox.com/docs/stt/api-reference/websocket-api): authenticate with a Bearer header,
/// send one JSON config, stream raw PCM as binary frames, end with an empty text frame. Final
/// tokens arrive once; non-final tokens are re-sent with each response; `<end>` closes a phrase.
/// One connection accepts up to 300 minutes of audio; a 4-hour lecture is 240.
///
/// Reliability: audio sent but not yet finalized when a connection drops is sent again on the next
/// connection (replay buffer, 30 s); audio that cannot be sent at all becomes a `.gap` event.
final class SonioxEngine: LiveTranscriber, @unchecked Sendable {
    typealias KeyProvider = @Sendable () async throws -> String

    let displayName = "Soniox stt-rt-v5"
    let runsOnDevice = false
    let events: AsyncStream<TranscriptionEvent>

    private static let endpoint = URL(string: "wss://stt-rt.soniox.com/transcribe-websocket")!
    private static let model = "stt-rt-v5"
    private static let bytesPerSecond = Int(SegmentedRecorder.sampleRate) * 2
    /// Audio kept while reconnecting: 120 s of 16-bit 16 kHz mono.
    private static let maxPendingBytes = bytesPerSecond * 120
    /// Audio already sent that may still lack final text, re-sent after a reconnect.
    private static let maxReplayBytes = bytesPerSecond * 30
    /// Close a phrase that runs this long without a pause, at the next sentence end.
    private static let softPhraseLimit = 20.0
    private static let hardPhraseLimit = 40.0

    private struct Chunk {
        let frame: AVAudioFramePosition
        let data: Data
        var endFrame: AVAudioFramePosition { frame + AVAudioFramePosition(data.count / 2) }
    }

    private let continuation: AsyncStream<TranscriptionEvent>.Continuation
    private let keyProvider: KeyProvider
    private let languageHints: [String]
    private let terms: [String]
    private let session = URLSession(configuration: .default)
    private let queue = DispatchQueue(label: "dawwen.soniox")

    // Everything below is confined to `queue`.
    private var socket: URLSessionWebSocketTask?
    private var isConnected = false
    private var isConnecting = false
    private var isFinishing = false
    private var isClosed = false
    private var connectGeneration = 0
    private var streamStartFrame: AVAudioFramePosition?
    private var pending: [Chunk] = []
    private var pendingBytes = 0
    private var sent: [Chunk] = []
    private var sentBytes = 0
    /// End of the audio Soniox has returned final text for (recording frames).
    private var lastFinalFrame: AVAudioFramePosition?
    private var lastSend = Date.distantPast
    private var reconnectAttempt = 0
    private var keepAliveTimer: DispatchSourceTimer?
    private var finishContinuation: CheckedContinuation<Void, Never>?

    private var phraseText = ""
    private var phraseStart: Double?
    private var phraseEnd: Double = 0
    private var phraseSpeaker: String?

    init(keyProvider: @escaping KeyProvider, language: String, terms: [String], secondaryLanguage: String? = nil) {
        self.keyProvider = keyProvider
        var hints = [Languages.code(language)]
        if let secondary = secondaryLanguage.map(Languages.code), !hints.contains(secondary) {
            hints.append(secondary)
        }
        self.languageHints = hints
        self.terms = terms
        (events, continuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
    }

    // MARK: - LiveTranscriber

    func start() async throws {
        queue.async {
            self.connect()
            self.startKeepAlive()
        }
    }

    func append(_ buffer: AVAudioPCMBuffer, startFrame: AVAudioFramePosition) {
        guard let data = Self.pcm16(buffer) else { return }
        queue.async { self.enqueue(data, startFrame: startFrame) }
    }

    func finish() async {
        await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
            queue.async {
                guard !self.isClosed else {
                    waiter.resume()
                    return
                }
                self.isFinishing = true
                self.finishContinuation = waiter
                if let socket = self.socket, self.isConnected {
                    // An empty text frame ends the stream; the server sends the rest, then `finished`.
                    self.send(.string(""), on: socket)
                    self.queue.asyncAfter(deadline: .now() + 15) { self.close() }
                } else {
                    self.close()
                }
            }
        }
    }

    // MARK: - Connection

    private func connect() {
        guard !isClosed, !isFinishing, !isConnecting, socket == nil else { return }
        isConnecting = true
        connectGeneration += 1
        let generation = connectGeneration
        let provider = keyProvider
        Task {
            do {
                let key = try await provider()
                self.queue.async {
                    self.isConnecting = false
                    guard generation == self.connectGeneration, !self.isClosed, !self.isFinishing else { return }
                    self.openSocket(key: key)
                }
            } catch {
                self.queue.async {
                    self.isConnecting = false
                    self.scheduleReconnect(reason: "Couldn't get a Soniox key: \(error.localizedDescription)")
                }
            }
        }
    }

    private func openSocket(key: String) {
        var request = URLRequest(url: Self.endpoint)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let socket = session.webSocketTask(with: request)
        self.socket = socket
        isConnected = false
        streamStartFrame = nil
        socket.resume()

        var config: [String: Any] = [
            "model": Self.model,
            "audio_format": "pcm_s16le",
            "sample_rate": Int(SegmentedRecorder.sampleRate),
            "num_channels": 1,
            "language_hints": languageHints,
            "enable_endpoint_detection": true,
            "enable_speaker_diarization": true
        ]
        if !terms.isEmpty {
            config["context"] = ["terms": terms]
        }
        guard let body = try? JSONSerialization.data(withJSONObject: config),
              let json = String(data: body, encoding: .utf8) else { return }

        socket.send(.string(json)) { [weak self] error in
            guard let self else { return }
            self.queue.async {
                guard self.socket === socket else { return }
                if let error {
                    self.connectionLost(socket, reason: error.localizedDescription)
                    return
                }
                self.isConnected = true
                self.reconnectAttempt = 0
                self.continuation.yield(.status(""))
                self.flushPending(on: socket)
            }
        }
        receive(on: socket)
    }

    private func receive(on socket: URLSessionWebSocketTask) {
        socket.receive { [weak self] result in
            guard let self else { return }
            self.queue.async {
                guard self.socket === socket else { return }
                switch result {
                case .success(let message):
                    switch message {
                    case .string(let text):
                        self.handle(text)
                    case .data(let data):
                        self.handle(String(decoding: data, as: UTF8.self))
                    @unknown default:
                        break
                    }
                    if !self.isClosed, self.socket === socket {
                        self.receive(on: socket)
                    }
                case .failure(let error):
                    self.connectionLost(socket, reason: error.localizedDescription)
                }
            }
        }
    }

    private func enqueue(_ data: Data, startFrame: AVAudioFramePosition) {
        guard !isClosed, !isFinishing else { return }
        if lastFinalFrame == nil { lastFinalFrame = startFrame }
        let chunk = Chunk(frame: startFrame, data: data)
        if isConnected, let socket {
            if streamStartFrame == nil { streamStartFrame = startFrame }
            send(.data(data), on: socket)
            remember(chunk)
        } else {
            if pendingBytes + data.count > Self.maxPendingBytes {
                dropPending()
            }
            pending.append(chunk)
            pendingBytes += data.count
        }
    }

    private func flushPending(on socket: URLSessionWebSocketTask) {
        guard let first = pending.first else { return }
        streamStartFrame = first.frame
        for chunk in pending {
            send(.data(chunk.data), on: socket)
            remember(chunk)
        }
        pending.removeAll()
        pendingBytes = 0
    }

    private func remember(_ chunk: Chunk) {
        sent.append(chunk)
        sentBytes += chunk.data.count
        while sentBytes > Self.maxReplayBytes, let first = sent.first {
            sent.removeFirst()
            sentBytes -= first.data.count
        }
    }

    /// The backlog outgrew 120 s: give it up as a gap; the audio itself is safe in the part files.
    private func dropPending() {
        guard let first = pending.first, let last = pending.last else { return }
        emitGap(from: first.frame, to: last.endFrame)
        pending.removeAll()
        pendingBytes = 0
    }

    /// A dead connection never returns final text for audio after `lastFinalFrame`: queue it again.
    private func requeueUnfinalized() {
        let finalEnd = lastFinalFrame ?? 0
        let replay = sent.filter { $0.endFrame > finalEnd }
        if let first = replay.first, first.frame > finalEnd + AVAudioFramePosition(SegmentedRecorder.sampleRate) {
            emitGap(from: finalEnd, to: first.frame) // older than the replay buffer reaches
        }
        sent.removeAll()
        sentBytes = 0
        pending.insert(contentsOf: replay, at: 0)
        pendingBytes += replay.reduce(0) { $0 + $1.data.count }
        while pendingBytes > Self.maxPendingBytes, let first = pending.first {
            emitGap(from: first.frame, to: first.endFrame)
            pending.removeFirst()
            pendingBytes -= first.data.count
        }
    }

    private func emitGap(from start: AVAudioFramePosition, to end: AVAudioFramePosition) {
        guard end > start else { return }
        continuation.yield(.gap(
            start: Double(start) / SegmentedRecorder.sampleRate,
            end: Double(end) / SegmentedRecorder.sampleRate
        ))
    }

    private func send(_ message: URLSessionWebSocketTask.Message, on socket: URLSessionWebSocketTask) {
        lastSend = Date()
        socket.send(message) { [weak self] error in
            guard let self, let error else { return }
            self.queue.async { self.connectionLost(socket, reason: error.localizedDescription) }
        }
    }

    /// Soniox closes a connection after 20 s without audio or a keepalive (e.g. while paused).
    private func startKeepAlive() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in
            guard let self, self.isConnected, let socket = self.socket,
                  Date().timeIntervalSince(self.lastSend) > 8 else { return }
            self.send(.string(#"{"type":"keepalive"}"#), on: socket)
        }
        timer.resume()
        keepAliveTimer = timer
    }

    private func connectionLost(_ socket: URLSessionWebSocketTask, reason: String) {
        guard self.socket === socket else { return }
        self.socket = nil
        isConnected = false
        let handshakeStatus = (socket.response as? HTTPURLResponse)?.statusCode
        socket.cancel(with: .goingAway, reason: nil)
        flushPhrase()
        requeueUnfinalized()
        if isFinishing {
            close()
            return
        }
        guard !isClosed else { return }
        if let handshakeStatus, [401, 402, 403].contains(handshakeStatus) {
            // A wrong key or an empty balance won't fix itself by reconnecting.
            handleError(code: handshakeStatus, message: "Connection refused")
            return
        }
        scheduleReconnect(reason: reason)
    }

    private func scheduleReconnect(reason: String) {
        guard !isClosed, !isFinishing else { return }
        reconnectAttempt += 1
        let delay = min(30, pow(2, Double(min(reconnectAttempt, 5))))
        continuation.yield(.status("Lost the connection to Soniox (\(reason)). Retrying in \(Int(delay)) s; recording continues."))
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.isClosed, !self.isFinishing, self.socket == nil else { return }
            self.connect()
        }
    }

    private func close() {
        guard !isClosed else { return }
        isClosed = true
        connectGeneration += 1
        flushPhrase()
        // Whatever never reached Soniox has no text.
        if let first = pending.first, let last = pending.last { emitGap(from: first.frame, to: last.endFrame) }
        pending.removeAll()
        keepAliveTimer?.cancel()
        keepAliveTimer = nil
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        continuation.finish()
        finishContinuation?.resume()
        finishContinuation = nil
    }

    // MARK: - Responses

    private func handle(_ text: String) {
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return }

        if let code = object["error_code"] {
            let message = object["error_message"] as? String ?? ""
            handleError(code: (code as? Int) ?? Int("\(code)") ?? 0, message: message)
            return
        }

        var partial = ""
        let streamStart = streamStartFrame ?? 0
        let offset = Double(streamStart) / SegmentedRecorder.sampleRate
        for token in object["tokens"] as? [[String: Any]] ?? [] {
            guard let piece = token["text"] as? String else { continue }
            if token["translation_status"] as? String == "translation" { continue }
            let isFinal = token["is_final"] as? Bool ?? false
            if piece == "<end>" || piece == "<fin>" {
                if isFinal { flushPhrase() }
                continue
            }
            guard isFinal else {
                partial += piece
                continue
            }
            let start = (token["start_ms"] as? Double).map { offset + $0 / 1000 }
            let end = (token["end_ms"] as? Double).map { offset + $0 / 1000 }
            if let endMs = token["end_ms"] as? Double {
                let frame = streamStart + AVAudioFramePosition(endMs * SegmentedRecorder.sampleRate / 1000)
                lastFinalFrame = max(lastFinalFrame ?? 0, frame)
            }
            let speaker = token["speaker"].map { "\($0)" }
            if let speaker, let current = phraseSpeaker, speaker != current {
                flushPhrase()
            }
            if phraseStart == nil { phraseStart = start }
            if let end { phraseEnd = end }
            if phraseSpeaker == nil { phraseSpeaker = speaker }
            phraseText += piece
            closeLongPhraseIfNeeded()
        }
        continuation.yield(.partial((phraseText + partial).trimmingCharacters(in: .whitespacesAndNewlines)))

        if object["finished"] as? Bool == true {
            close()
        }
    }

    private func closeLongPhraseIfNeeded() {
        guard let start = phraseStart else { return }
        let length = phraseEnd - start
        let endsSentence = phraseText.trimmingCharacters(in: .whitespaces).last.map { ".?!؟،".contains($0) } ?? false
        if length >= Self.hardPhraseLimit || (length >= Self.softPhraseLimit && endsSentence) {
            flushPhrase()
        }
    }

    private func flushPhrase() {
        let text = phraseText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty, let start = phraseStart {
            continuation.yield(.final(text: text, start: start, end: max(phraseEnd, start), speaker: phraseSpeaker))
        }
        phraseText = ""
        phraseStart = nil
        phraseEnd = 0
        phraseSpeaker = nil
    }

    private func handleError(code: Int, message: String) {
        switch code {
        case 408, 413, 429, 500, 503:
            // Timeout, session limit, rate limit or server trouble: open a new connection.
            if let socket { connectionLost(socket, reason: "\(code)") }
        default:
            let hint = (code == 401 || code == 403) ? "Check the Soniox key." : (code == 402 ? "Soniox credit has run out." : "")
            continuation.yield(.failure("Soniox \(code): \(message) \(hint)"))
            close()
        }
    }

    // MARK: - Audio

    /// Float32 → signed 16-bit little-endian, the `pcm_s16le` format declared in the config.
    private static func pcm16(_ buffer: AVAudioPCMBuffer) -> Data? {
        guard let samples = buffer.floatChannelData?[0] else { return nil }
        let count = Int(buffer.frameLength)
        var data = Data(count: count * MemoryLayout<Int16>.size)
        data.withUnsafeMutableBytes { raw in
            let output = raw.bindMemory(to: Int16.self)
            for index in 0..<count {
                let clamped = max(-1, min(1, samples[index]))
                output[index] = Int16(clamped * Float(Int16.max)).littleEndian
            }
        }
        return data
    }
}
