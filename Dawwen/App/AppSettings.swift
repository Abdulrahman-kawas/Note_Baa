import Foundation

enum SettingsKey {
    static let sourceLanguage = "sourceLanguage"
    static let translationEnabled = "translationEnabled"
    static let targetLanguage = "targetLanguage"
    static let engine = "engine"
    static let claudeModel = "claudeModel"
    static let summaryLanguage = "summaryLanguage"
    static let keepScreenOn = "keepScreenOn"
    static let vocabulary = "vocabulary"
}

/// Snapshot of the user's preferences, read from UserDefaults when a lecture starts.
struct AppSettings {
    var sourceLanguage: String
    var translationEnabled: Bool
    var targetLanguage: String
    var engine: EngineKind
    var claudeModel: ClaudeModelOption
    var summaryLanguage: String
    var keepScreenOn: Bool
    /// Course terms that bias recognition (one per line in Settings).
    var vocabulary: [String]

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            SettingsKey.sourceLanguage: "en-US",
            SettingsKey.translationEnabled: true,
            SettingsKey.targetLanguage: "ar",
            SettingsKey.engine: EngineKind.auto.rawValue,
            SettingsKey.claudeModel: ClaudeModelOption.opus.rawValue,
            SettingsKey.summaryLanguage: "ar",
            SettingsKey.keepScreenOn: true,
            SettingsKey.vocabulary: ""
        ])
    }

    static var current: AppSettings {
        let defaults = UserDefaults.standard
        return AppSettings(
            sourceLanguage: defaults.string(forKey: SettingsKey.sourceLanguage) ?? "en-US",
            translationEnabled: defaults.bool(forKey: SettingsKey.translationEnabled),
            targetLanguage: defaults.string(forKey: SettingsKey.targetLanguage) ?? "ar",
            engine: EngineKind(rawValue: defaults.string(forKey: SettingsKey.engine) ?? "") ?? .auto,
            claudeModel: ClaudeModelOption(rawValue: defaults.string(forKey: SettingsKey.claudeModel) ?? "") ?? .opus,
            summaryLanguage: defaults.string(forKey: SettingsKey.summaryLanguage) ?? "ar",
            keepScreenOn: defaults.bool(forKey: SettingsKey.keepScreenOn),
            vocabulary: (defaults.string(forKey: SettingsKey.vocabulary) ?? "")
                .split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        )
    }
}

struct LanguageOption: Identifiable, Hashable {
    let id: String
    let name: String
}

enum Languages {
    static let lecture: [LanguageOption] = [
        .init(id: "ar-SA", name: "العربية"),
        .init(id: "en-US", name: "English (US)"),
        .init(id: "en-GB", name: "English (UK)"),
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
        .init(id: "ar", name: "العربية"),
        .init(id: "en", name: "English"),
        .init(id: "fr", name: "Français"),
        .init(id: "de", name: "Deutsch"),
        .init(id: "es", name: "Español"),
        .init(id: "tr", name: "Türkçe")
    ]

    static func name(for id: String) -> String {
        if let match = (lecture + translation).first(where: { $0.id == id }) { return match.name }
        return Locale(identifier: "ar").localizedString(forIdentifier: id) ?? id
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

    /// Input / output price per million tokens (platform.claude.com pricing, Oct 2026).
    var priceNote: String {
        switch self {
        case .opus: "4 $ / 20 $ لكل مليون token"
        case .sonnet: "2 $ / 10 $ لكل مليون token"
        case .haiku: "0.10 $ / 0.50 $ لكل مليون token"
        }
    }

    /// Haiku has no server-side refusal fallback; sending `fallbacks` there is pointless.
    var supportsServerFallback: Bool { self != .haiku }
}
