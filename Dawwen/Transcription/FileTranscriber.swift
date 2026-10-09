import AVFoundation
import Speech

/// Transcribes recorded or imported audio after the fact, with Apple's on-device models.
/// Used to fill what live transcription missed (heat, crash, record-only mode) and for imports.
enum FileTranscriber {
    struct Segment: Sendable {
        let text: String
        let start: Double
        let end: Double
    }

    static func transcribe(
        urls: [URL],
        language: String,
        vocabulary: [String],
        progress: @escaping @Sendable (String) -> Void
    ) async throws -> [Segment] {
        let locale = Locale(identifier: language)
        var segments: [Segment] = []
        var offset = 0.0
        for (index, url) in urls.enumerated() {
            try Task.checkCancellation()
            guard let file = try? AVAudioFile(forReading: url) else { continue }
            progress("التفريغ من الصوت: الجزء \(index + 1) من \(urls.count)")
            guard let module = await AppleSpeechEngine.makeModule(for: locale, live: false) else {
                throw TranscriptionError.unsupportedLanguage(Languages.name(for: language))
            }
            try await AppleSpeechEngine.installAssets(for: module.speechModule) { progress($0) }

            let analyzer = SpeechAnalyzer(modules: [module.speechModule])
            if let context = AppleSpeechEngine.context(for: vocabulary) {
                try? await analyzer.setContext(context)
            }
            let base = offset
            let collector: Task<[Segment], Never>
            switch module {
            case .speech(let transcriber):
                collector = Task { await collect(transcriber.results, offset: base) }
            case .dictation(let transcriber):
                collector = Task { await collect(transcriber.results, offset: base) }
            }
            if let lastSample = try await analyzer.analyzeSequence(from: file) {
                try await analyzer.finalizeAndFinish(through: lastSample)
            } else {
                await analyzer.cancelAndFinishNow()
            }
            segments += await collector.value
            offset += Double(file.length) / file.processingFormat.sampleRate
        }
        return segments
    }

    private static func collect<Results: AsyncSequence>(_ results: Results, offset: Double) async -> [Segment]
    where Results.Element: AppleTranscriptionResult {
        var segments: [Segment] = []
        do {
            for try await result in results where result.isFinal {
                let text = AppleSpeechEngine.cleanText(result.text)
                guard !text.isEmpty else { continue }
                let start = result.range.start.seconds
                let end = result.range.end.seconds
                segments.append(Segment(
                    text: text,
                    start: offset + (start.isFinite ? start : 0),
                    end: offset + (end.isFinite ? end : 0)
                ))
            }
        } catch {
            // Keep whatever was transcribed before the error.
        }
        return segments
    }
}
