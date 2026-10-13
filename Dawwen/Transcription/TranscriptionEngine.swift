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
        case .auto: "Apple على الجهاز للإنجليزية (مجاني ودون إنترنت)، وSoniox للعربية إن وُجد مفتاحه."
        case .apple: "مجاني ودون إنترنت. SpeechTranscriber للإنجليزية؛ إملاء الجهاز للعربية."
        case .soniox: "اختياري للدقة الأعلى وتمييز المتحدثين. يحتاج إنترنت ومفتاحاً (نحو 0.12 $ للساعة)."
        case .none: "يحفظ البطارية؛ التفريغ لاحقاً من الصوت."
        }
    }
}

enum TranscriptionEvent: Sendable {
    /// Unconfirmed text for the phrase being spoken; replaces the previous partial.
    case partial(String)
    /// A confirmed phrase, with its position in the recording timeline.
    case final(text: String, start: Double, end: Double, speaker: String?)
    /// Audio in [start, end) seconds will never get live text (dropped backlog, lost connection).
    case gap(start: Double, end: Double)
    case status(String)
    case failure(String)
}

/// A live speech-to-text engine fed by `SegmentedRecorder` (through `TranscriberFeed`).
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
            "أضف مفتاح Soniox من الإعدادات، أو فعّل Soniox عبر الخادم."
        case .unsupportedLanguage(let name):
            "محرك Apple على هذا الجهاز لا يدعم \(name). استخدم Soniox، أو ثبّت لغة الإملاء من إعدادات لوحة المفاتيح."
        }
    }
}

/// Where Soniox keys come from: a short-lived key minted by the gateway (preferred), or the
/// permanent key in the Keychain (works without the server).
enum SonioxCredentials {
    static var isConfigured: Bool {
        KeychainStore.read(.soniox) != nil || (AppSettings.current.sonioxViaGateway && ServerClient.current != nil)
    }

    static func keyProvider() -> SonioxEngine.KeyProvider? {
        let permanent = KeychainStore.read(.soniox)
        let gateway = AppSettings.current.sonioxViaGateway ? ServerClient.current : nil
        guard permanent != nil || gateway != nil else { return nil }
        return {
            if let gateway {
                do {
                    return try await gateway.sonioxTemporaryKey()
                } catch {
                    if let permanent { return permanent } // server down: keep transcribing
                    throw error
                }
            }
            if let permanent { return permanent }
            throw TranscriptionError.missingSonioxKey
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

    static func make(_ kind: EngineKind, language: String, vocabulary: [String], translationTarget: String?) throws -> (any LiveTranscriber)? {
        switch kind {
        case .apple:
            return AppleSpeechEngine(language: language, vocabulary: vocabulary)
        case .soniox:
            guard let provider = SonioxCredentials.keyProvider() else { throw TranscriptionError.missingSonioxKey }
            // English-taught courses in Arab universities still switch to Arabic now and then.
            let secondary = translationTarget.flatMap { Languages.code($0) == "ar" && Languages.code(language) != "ar" ? "ar" : nil }
            return SonioxEngine(keyProvider: provider, language: language, terms: vocabulary, secondaryLanguage: secondary)
        case .auto, .none:
            return nil
        }
    }
}
