import AVFoundation
import Speech

/// Results from both Apple modules expose their text the same way.
protocol AppleTranscriptionResult: SpeechModuleResult {
    var text: AttributedString { get }
}

extension SpeechTranscriber.Result: AppleTranscriptionResult {}
extension DictationTranscriber.Result: AppleTranscriptionResult {}

/// On-device transcription with SpeechAnalyzer (iPadOS 26).
final class AppleSpeechEngine: LiveTranscriber, @unchecked Sendable {
    enum Module {
        case speech(SpeechTranscriber)
        case dictation(DictationTranscriber)

        var speechModule: any SpeechModule {
            switch self {
            case .speech(let module): module
            case .dictation(let module): module
            }
        }

        var name: String {
            switch self {
            case .speech: "Apple SpeechTranscriber"
            case .dictation: "Apple DictationTranscriber"
            }
        }
    }

    let events: AsyncStream<TranscriptionEvent>
    let runsOnDevice = true
    private(set) var displayName = "Apple"

    private let continuation: AsyncStream<TranscriptionEvent>.Continuation
    private let locale: Locale
    private let vocabulary: [String]
    private let lock = NSLock()
    private let converter = AudioBufferConverter()
    private var analyzer: SpeechAnalyzer?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var analyzerFormat: AVAudioFormat?
    private var resultsTask: Task<Void, Never>?

    init(language: String, vocabulary: [String]) {
        locale = Locale(identifier: language)
        self.vocabulary = vocabulary
        (events, continuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
    }

    // MARK: - Module choice

    /// SpeechTranscriber when its model really exists for the language, else DictationTranscriber.
    ///
    /// `supportedLocales` is not enough: SpeechTranscriber lists Arabic, but its asset status is
    /// `.unsupported` and the download fails (Apple confirmed the listing was a mistake, Jan 2026;
    /// reproduced on macOS 26.5). DictationTranscriber transcribes Arabic on-device.
    static func makeModule(for locale: Locale, live: Bool) async -> Module? {
        if SpeechTranscriber.isAvailable,
           let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) {
            let transcriber = SpeechTranscriber(
                locale: supported,
                transcriptionOptions: [],
                reportingOptions: live ? [.volatileResults] : [],
                attributeOptions: [.audioTimeRange]
            )
            if await AssetInventory.status(forModules: [transcriber]) != .unsupported {
                return .speech(transcriber)
            }
        }
        if let supported = await DictationTranscriber.supportedLocale(equivalentTo: locale) {
            return .dictation(DictationTranscriber(
                locale: supported,
                contentHints: [.farField], // The lecturer is metres away from the iPad.
                transcriptionOptions: [.punctuation],
                reportingOptions: live ? [.volatileResults, .frequentFinalization] : [],
                attributeOptions: [.audioTimeRange]
            ))
        }
        return nil
    }

    static func supports(language: String) async -> Bool {
        await makeModule(for: Locale(identifier: language), live: false) != nil
    }

    static func installAssets(for module: any SpeechModule, status: (String) -> Void) async throws {
        let current = await AssetInventory.status(forModules: [module])
        // A request comes back even when the model is installed; it then finishes at once.
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) else { return }
        if current != .installed {
            status("تجهيز نموذج اللغة على الجهاز (يُنزَّل أول مرة فقط)…")
        }
        try await request.downloadAndInstall()
    }

    static func context(for vocabulary: [String]) -> AnalysisContext? {
        guard !vocabulary.isEmpty else { return nil }
        let context = AnalysisContext()
        context.contextualStrings[.general] = vocabulary
        return context
    }

    /// Text of a result without surrounding spaces or the bidi marks dictation adds to Arabic.
    static func cleanText(_ text: AttributedString) -> String {
        String(text.characters).trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{200E}\u{200F}")))
    }

    // MARK: - LiveTranscriber

    func start() async throws {
        guard let module = await Self.makeModule(for: locale, live: true) else {
            throw TranscriptionError.unsupportedLanguage(Languages.name(for: locale.identifier))
        }
        displayName = module.name
        let continuation = continuation
        try await Self.installAssets(for: module.speechModule) { continuation.yield(.status($0)) }

        let analyzer = SpeechAnalyzer(modules: [module.speechModule])
        if let context = Self.context(for: vocabulary) {
            try? await analyzer.setContext(context)
        }
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module.speechModule])
            ?? SegmentedRecorder.pipelineFormat
        // Bounded: if the analyzer falls behind (older iPad, heat), new audio is dropped and reported
        // as a gap instead of growing memory until the system kills the app, and the recording with it.
        // ~1,200 tap buffers ≈ 100 s of audio ≈ 6 MB.
        let (stream, input) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingOldest(1_200))

        switch module {
        case .speech(let transcriber):
            resultsTask = Task { [weak self] in await self?.consume(transcriber.results) }
        case .dictation(let transcriber):
            resultsTask = Task { [weak self] in await self?.consume(transcriber.results) }
        }
        try await analyzer.start(inputSequence: stream)
        continuation.yield(.status(""))

        lock.withLock {
            self.analyzer = analyzer
            self.analyzerFormat = format
            self.input = input
        }
    }

    func append(_ buffer: AVAudioPCMBuffer, startFrame: AVAudioFramePosition) {
        lock.lock()
        defer { lock.unlock() }
        guard let input, let analyzerFormat,
              let converted = try? converter.convert(buffer, to: analyzerFormat) else { return }
        // The exact position in the recording keeps timestamps right after pauses and heat stops.
        let start = CMTime(value: CMTimeValue(startFrame), timescale: CMTimeScale(SegmentedRecorder.sampleRate))
        if case .dropped = input.yield(AnalyzerInput(buffer: converted, bufferStartTime: start)) {
            let seconds = start.seconds
            let length = Double(converted.frameLength) / converted.format.sampleRate
            continuation.yield(.gap(start: seconds, end: seconds + length))
        }
    }

    func finish() async {
        let (analyzer, input) = lock.withLock {
            let pair = (self.analyzer, self.input)
            self.input = nil
            return pair
        }
        input?.finish()
        if let analyzer {
            do {
                try await analyzer.finalizeAndFinishThroughEndOfInput()
            } catch {
                await analyzer.cancelAndFinishNow()
            }
        }
        await resultsTask?.value
        continuation.finish()
    }

    private func consume<Results: AsyncSequence>(_ results: Results) async where Results.Element: AppleTranscriptionResult {
        do {
            for try await result in results {
                let text = Self.cleanText(result.text)
                if result.isFinal {
                    if !text.isEmpty {
                        let start = result.range.start.seconds
                        let end = result.range.end.seconds
                        continuation.yield(.final(
                            text: text,
                            start: start.isFinite ? start : 0,
                            end: end.isFinite ? end : (start.isFinite ? start : 0),
                            speaker: nil
                        ))
                    }
                    continuation.yield(.partial(""))
                } else {
                    continuation.yield(.partial(text))
                }
            }
        } catch {
            continuation.yield(.failure(error.localizedDescription))
        }
    }
}
