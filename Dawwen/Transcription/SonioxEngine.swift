import AVFoundation
import Foundation

/// Cloud transcription over the Soniox real-time WebSocket API (model stt-rt-v5).
///
/// Protocol (soniox.com/docs/stt/api-reference/websocket-api): authenticate with a Bearer header,
/// send one JSON config, stream raw PCM as binary frames, end with an empty text frame. Final
/// tokens arrive once; non-final tokens are re-sent with each response; `<end>` closes a phrase.
/// One connection accepts up to 300 minutes of audio; a 3.5-hour lecture is 210.
final class SonioxEngine: LiveTranscriber, @unchecked Sendable {
    let displayName = "Soniox stt-rt-v5"
    let runsOnDevice = false
    let events: AsyncStream<TranscriptionEvent>

    private static let endpoint = URL(string: "wss://stt-rt.soniox.com/transcribe-websocket")!
    private static let model = "stt-rt-v5"
    /// Audio kept while reconnecting: 120 s of 16-bit 16 kHz mono.
    private static let maxPendingBytes = 16_000 * 2 * 120
    /// Close a phrase that runs this long without a pause, at the next sentence end.
    private static let softPhraseLimit = 20.0
    private static let hardPhraseLimit = 40.0

    private let continuation: AsyncStream<TranscriptionEvent>.Continuation
    private let apiKey: String
    private let languageHints: [String]
    private let terms: [String]
    private let session = URLSession(configuration: .default)
    private let queue = DispatchQueue(label: "dawwen.soniox")

    // Everything below is confined to `queue`.
    private var socket: URLSessionWebSocketTask?
    private var isConnected = false
    private var isFinishing = false
    private var isClosed = false
    private var streamStartFrame: AVAudioFramePosition?
    private var pending: [(frame: AVAudioFramePosition, data: Data)] = []
    private var pendingBytes = 0
    private var lastSend = Date.distantPast
    private var reconnectAttempt = 0
    private var keepAliveTimer: DispatchSourceTimer?
    private var finishContinuation: CheckedContinuation<Void, Never>?

    private var phraseText = ""
    private var phraseStart: Double?
    private var phraseEnd: Double = 0
    private var phraseSpeaker: String?

    init(apiKey: String, language: String, terms: [String]) {
        self.apiKey = apiKey
        self.languageHints = [Languages.code(language)]
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
        var request = URLRequest(url: Self.endpoint)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
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
        if isConnected, let socket {
            if streamStartFrame == nil { streamStartFrame = startFrame }
            send(.data(data), on: socket)
        } else {
            if pendingBytes + data.count > Self.maxPendingBytes {
                // Dropping the whole backlog keeps the new stream's clock contiguous;
                // the audio itself is safe in the part files.
                pending.removeAll()
                pendingBytes = 0
            }
            pending.append((startFrame, data))
            pendingBytes += data.count
        }
    }

    private func flushPending(on socket: URLSessionWebSocketTask) {
        guard let first = pending.first else { return }
        streamStartFrame = first.frame
        for item in pending { send(.data(item.data), on: socket) }
        pending.removeAll()
        pendingBytes = 0
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
        if isFinishing {
            close()
            return
        }
        guard !isClosed else { return }
        if let handshakeStatus, [401, 402, 403].contains(handshakeStatus) {
            // A wrong key or an empty balance won't fix itself by reconnecting.
            handleError(code: handshakeStatus, message: "رُفض الاتصال")
            return
        }
        reconnectAttempt += 1
        let delay = min(30, pow(2, Double(min(reconnectAttempt, 5))))
        continuation.yield(.status("انقطع الاتصال بـ Soniox (\(reason)). إعادة المحاولة خلال \(Int(delay)) ث، والتسجيل مستمر."))
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.isClosed, !self.isFinishing, self.socket == nil else { return }
            self.connect()
        }
    }

    private func close() {
        guard !isClosed else { return }
        isClosed = true
        flushPhrase()
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
        let offset = Double(streamStartFrame ?? 0) / SegmentedRecorder.sampleRate
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
            let hint = (code == 401 || code == 403) ? "تحقق من مفتاح Soniox." : (code == 402 ? "رصيد Soniox انتهى." : "")
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
