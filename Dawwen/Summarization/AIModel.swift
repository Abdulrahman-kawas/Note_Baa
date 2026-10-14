import Foundation

/// Anything that answers a `ClaudeClient.Request`: Claude, or the free models.
protocol TextModelClient: Sendable {
    func stream(_ request: ClaudeClient.Request) -> AsyncThrowingStream<String, Error>
    func complete(_ request: ClaudeClient.Request) async throws -> String
}

extension ClaudeClient: TextModelClient {}

/// A model choice in Settings (summary, questions, refinement). Stored by `rawValue`, so the Claude
/// choices keep the strings saved before the free models were added.
enum AIModel: Hashable, Identifiable {
    case claude(ClaudeModelOption)
    /// `FreeLLM.models` in order: the first one that has a key, isn't resting, and answers.
    case freeAuto
    case free(FreeLLM.Model)

    init?(rawValue: String) {
        if let option = ClaudeModelOption(rawValue: rawValue) {
            self = .claude(option)
        } else if rawValue == "free:auto" {
            self = .freeAuto
        } else if let model = FreeLLM.models.first(where: { "free:" + $0.name == rawValue }) {
            self = .free(model)
        } else {
            return nil
        }
    }

    var rawValue: String {
        switch self {
        case .claude(let option): option.rawValue
        case .freeAuto: "free:auto"
        case .free(let model): "free:" + model.name
        }
    }

    var id: String { rawValue }

    static let freeCases: [AIModel] = [.freeAuto] + FreeLLM.models.map { .free($0) }

    var title: String {
        switch self {
        case .claude(let option): option.title
        case .freeAuto: "Free models (automatic)"
        case .free(let model): model.title
        }
    }

    var priceNote: String {
        switch self {
        case .claude(let option): option.priceNote
        case .freeAuto: "Free within each provider's limits; moves to the next model when one runs out"
        case .free(let model): "Free (\(model.note))"
        }
    }

    /// For the routes only Claude has (Message Batches through the gateway).
    var claude: ClaudeModelOption? {
        if case .claude(let option) = self { return option }
        return nil
    }

    /// What actually runs: a Claude choice with no Claude key (and no gateway) falls back to the free
    /// models when any of them has a key, so free keys work without changing the model pickers.
    func resolved() -> AIModel {
        if case .claude(let option) = self, ClaudeClient.current(model: option) == nil,
           FreeLLMClient.current(models: FreeLLM.models) != nil {
            return .freeAuto
        }
        return self
    }

    /// nil when the key it needs isn't in Settings (see `missingKeyError`).
    func client() -> (any TextModelClient)? {
        switch self {
        case .claude(let option): ClaudeClient.current(model: option)
        case .freeAuto: FreeLLMClient.current(models: FreeLLM.models)
        case .free(let model): FreeLLMClient.current(models: [model])
        }
    }

    var missingKeyError: Error {
        claude == nil ? FreeLLMClient.FreeError.missingKey : ClaudeClient.ClaudeError.missingKey
    }
}
