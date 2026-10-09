import AVFoundation

enum EngineKind: String, CaseIterable, Identifiable, Codable {
    case auto
    case apple
    case soniox
    case none

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: "تلقائي"
        case .apple: "Apple على الجهاز"
        case .soniox: "Soniox السحابي"
        case .none: "تسجيل فقط"
        }
    }

    var detail: String {
        switch self {
        case .auto: "Soniox للعربية إن وُجد مفتاحه، وApple لبقية اللغات."
        case .apple: "مجاني ودون إنترنت. لا يدعم SpeechTranscriber العربية؛ يُستخدم إملاء الجهاز إن توفر."
        case .soniox: "أعلى دقة للعربية، يحتاج إنترنت ومفتاح API (0.12 $ للساعة)."
        case .none: "يحفظ البطارية؛ التفريغ لاحقاً من الملف."
        }
    }
}

enum TranscriptionEvent: Sendable {
    /// Unconfirmed text for the phrase being spoken; replaces the previous partial.
    case partial(String)
    /// A confirmed phrase, with its position in the recording timeline.
    case final(text: String, start: Double, end: Double, speaker: String?)
    case status(String)
    case failure(String)
}

/// A live speech-to-text engine fed by `SegmentedRecorder`.
protocol LiveTranscriber: AnyObject, Sendable {
    var displayName: String { get }
    /// On-device engines heat the iPad; cloud engines don't.
    var runsOnDevice: Bool { get }
    var events: AsyncStream<TranscriptionEvent> { get }
    func start() async throws
    /// Called on the audio thread with 16 kHz mono Float32 audio. Must return quickly.
    func append(_ buffer: AVAudioPCMBuffer, startFrame: AVAudioFramePosition)
    /// Flushes pending audio, delivers the last results, then ends `events`.
    func finish() async
}

enum TranscriptionError: LocalizedError {
    case missingSonioxKey
    case unsupportedLanguage(String)

    var errorDescription: String? {
        switch self {
        case .missingSonioxKey:
            "أضف مفتاح Soniox من الإعدادات."
        case .unsupportedLanguage(let name):
            "محرك Apple على هذا الجهاز لا يدعم \(name). استخدم Soniox، أو ثبّت لغة الإملاء من إعدادات لوحة المفاتيح."
        }
    }
}

enum TranscriberFactory {
    /// Turns the user's choice into a concrete engine for this language.
    static func resolve(_ requested: EngineKind, language: String, hasSonioxKey: Bool) async -> EngineKind {
        switch requested {
        case .none:
            return .none
        case .apple:
            return .apple
        case .soniox:
            if hasSonioxKey { return .soniox }
            return await AppleSpeechEngine.supports(language: language) ? .apple : .none
        case .auto:
            if Languages.code(language) == "ar", hasSonioxKey { return .soniox }
            if await AppleSpeechEngine.supports(language: language) { return .apple }
            return hasSonioxKey ? .soniox : .none
        }
    }

    static func make(_ kind: EngineKind, language: String, vocabulary: [String]) throws -> LiveTranscriber? {
        switch kind {
        case .apple:
            return AppleSpeechEngine(language: language, vocabulary: vocabulary)
        case .soniox:
            guard let key = KeychainStore.read(.soniox) else { throw TranscriptionError.missingSonioxKey }
            return SonioxEngine(apiKey: key, language: language, terms: vocabulary)
        case .auto, .none:
            return nil
        }
    }
}
