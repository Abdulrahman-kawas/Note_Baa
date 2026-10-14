import Foundation

enum SettingsKey {
    static let sourceLanguage = "sourceLanguage"
    static let translationEnabled = "translationEnabled"
    static let targetLanguage = "targetLanguage"
    static let engine = "engine"
    static let claudeModel = "claudeModel"
    static let askModel = "askModel"
    static let refineModel = "refineModel"
    static let summaryLanguage = "summaryLanguage"
    static let keepScreenOn = "keepScreenOn"
    static let vocabulary = "vocabulary"
    static let glossary = "glossary"
    static let allowBluetoothMic = "allowBluetoothMic"
    static let gatewayURL = "gatewayURL"
    static let claudeViaGateway = "claudeViaGateway"
    static let sonioxViaGateway = "sonioxViaGateway"
    static let backupEnabled = "backupEnabled"
    static let refineEngine = "refineEngine"
}

struct GlossaryEntry: Hashable, Sendable {
    let term: String
    let translation: String
}

/// Snapshot of the user's preferences, read from UserDefaults when needed.
struct AppSettings {
    var sourceLanguage: String
    var translationEnabled: Bool
    var targetLanguage: String
    var engine: EngineKind
    /// Summaries.
    var claudeModel: ClaudeModelOption
    /// "Ask the lecture": many small questions over the cached transcript.
    var askModel: ClaudeModelOption
    /// Context-aware translation pass after the lecture.
    var refineModel: ClaudeModelOption
    var summaryLanguage: String
    var keepScreenOn: Bool
    /// Course terms that bias recognition (one per line in Settings).
    var vocabulary: [String]
    /// "English term = المصطلح" lines: fixed translations for the refinement pass.
    var glossary: [GlossaryEntry]
    var allowBluetoothMic: Bool
    var claudeViaGateway: Bool
    var sonioxViaGateway: Bool
    var backupEnabled: Bool
    /// "now" (from the iPad), "claude-batch" or "home" (through the gateway).
    var refineEngine: String

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            SettingsKey.sourceLanguage: "en-US",           // the owner's lectures are in English
            SettingsKey.translationEnabled: true,
            SettingsKey.targetLanguage: "ar",              // ...translated live into Arabic
            SettingsKey.engine: EngineKind.auto.rawValue,  // auto = Apple on-device for English
            SettingsKey.claudeModel: ClaudeModelOption.sonnet.rawValue,
            SettingsKey.askModel: ClaudeModelOption.haiku.rawValue,
            SettingsKey.refineModel: ClaudeModelOption.haiku.rawValue,
            SettingsKey.summaryLanguage: "en",
            SettingsKey.keepScreenOn: true,
            SettingsKey.vocabulary: "",
            SettingsKey.glossary: "",
            SettingsKey.allowBluetoothMic: false,
            SettingsKey.claudeViaGateway: false,
            SettingsKey.sonioxViaGateway: false,
            SettingsKey.backupEnabled: false,
            SettingsKey.refineEngine: "now"
        ])
    }

    static var current: AppSettings {
        let defaults = UserDefaults.standard
        func model(_ key: String, _ fallback: ClaudeModelOption) -> ClaudeModelOption {
            ClaudeModelOption(rawValue: defaults.string(forKey: key) ?? "") ?? fallback
        }
        return AppSettings(
            sourceLanguage: defaults.string(forKey: SettingsKey.sourceLanguage) ?? "en-US",
            translationEnabled: defaults.bool(forKey: SettingsKey.translationEnabled),
            targetLanguage: defaults.string(forKey: SettingsKey.targetLanguage) ?? "ar",
            engine: EngineKind(rawValue: defaults.string(forKey: SettingsKey.engine) ?? "") ?? .auto,
            claudeModel: model(SettingsKey.claudeModel, .sonnet),
            askModel: model(SettingsKey.askModel, .haiku),
            refineModel: model(SettingsKey.refineModel, .haiku),
            summaryLanguage: defaults.string(forKey: SettingsKey.summaryLanguage) ?? "en",
            keepScreenOn: defaults.bool(forKey: SettingsKey.keepScreenOn),
            vocabulary: lines(defaults.string(forKey: SettingsKey.vocabulary)),
            glossary: lines(defaults.string(forKey: SettingsKey.glossary)).compactMap { line in
                let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
                return GlossaryEntry(term: parts[0], translation: parts[1])
            },
            allowBluetoothMic: defaults.bool(forKey: SettingsKey.allowBluetoothMic),
            claudeViaGateway: defaults.bool(forKey: SettingsKey.claudeViaGateway),
            sonioxViaGateway: defaults.bool(forKey: SettingsKey.sonioxViaGateway),
            backupEnabled: defaults.bool(forKey: SettingsKey.backupEnabled),
            refineEngine: defaults.string(forKey: SettingsKey.refineEngine) ?? "now"
        )
    }

    private static func lines(_ text: String?) -> [String] {
        (text ?? "")
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

struct LanguageOption: Identifiable, Hashable {
    let id: String
    let name: String
}

enum Languages {
    static let lecture: [LanguageOption] = [
        .init(id: "en-US", name: "English (US)"),
        .init(id: "en-GB", name: "English (UK)"),
        .init(id: "ar-SA", name: "Arabic"),
        .init(id: "fr-FR", name: "Français"),
        .init(id: "de-DE", name: "Deutsch"),
        .init(id: "es-ES", name: "Español"),
        .init(id: "it-IT", name: "Italiano"),
        .init(id: "tr-TR", name: "Türkçe"),
        .init(id: "pt-BR", name: "Português"),
        .init(id: "ja-JP", name: "日本語"),
        .init(id: "ko-KR", name: "한국어"),
        .init(id: "zh-CN", name: "中文")
    ]

    static let translation: [LanguageOption] = [
        .init(id: "ar", name: "Arabic"),
        .init(id: "en", name: "English"),
        .init(id: "fr", name: "Français"),
        .init(id: "de", name: "Deutsch"),
        .init(id: "es", name: "Español"),
        .init(id: "tr", name: "Türkçe")
    ]

    static func name(for id: String) -> String {
        if let match = (lecture + translation).first(where: { $0.id == id }) { return match.name }
        return Locale(identifier: "en").localizedString(forIdentifier: id) ?? id
    }

    /// English name, used inside prompts.
    static func englishName(for id: String) -> String {
        Locale(identifier: "en").localizedString(forIdentifier: id) ?? id
    }

    static func code(_ id: String) -> String {
        String(id.prefix { $0 != "-" && $0 != "_" }).lowercased()
    }

    static func isRTL(_ id: String) -> Bool {
        ["ar", "he", "fa", "ur"].contains(code(id))
    }
}

enum ClaudeModelOption: String, CaseIterable, Identifiable {
    case opus = "claude-opus-5-5"
    case sonnet = "claude-sonnet-5-5"
    case haiku = "claude-haiku-5-5"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .opus: "Claude Opus 5.5"
        case .sonnet: "Claude Sonnet 5.5"
        case .haiku: "Claude Haiku 5.5"
        }
    }

    /// Input / output price per million tokens (Claude API pricing, Oct 2026).
    var priceNote: String {
        switch self {
        case .opus: "$4 / $20 per million tokens"
        case .sonnet: "$2 / $10 per million tokens"
        case .haiku: "$0.10 / $0.50 per million tokens (up to 100K tokens)"
        }
    }

    /// Haiku has no server-side refusal fallback; sending `fallbacks` there is pointless.
    var supportsServerFallback: Bool { self != .haiku }
}
