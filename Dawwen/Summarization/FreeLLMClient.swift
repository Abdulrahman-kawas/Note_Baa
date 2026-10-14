import Foundation

/// Free language models, called straight from the iPad over their OpenAI-compatible APIs: the same
/// providers, models and fallback order as the free-llm router (github.com/Abdulrahman-kawas/free-llms,
/// providers.toml), without its Python server. Each provider needs its own free key in Settings.
enum FreeLLM {
    enum Provider: String, CaseIterable, Identifiable, Sendable {
        case gemini, groq, ollama, zai, cloudflare

        var id: String { rawValue }

        var title: String {
            switch self {
            case .gemini: "Google Gemini"
            case .groq: "Groq"
            case .ollama: "Ollama Cloud"
            case .zai: "Z AI"
            case .cloudflare: "Cloudflare"
            }
        }

        /// Where to get the key.
        var keyPage: String {
            switch self {
            case .gemini: "aistudio.google.com/apikey"
            case .groq: "console.groq.com/keys"
            case .ollama: "ollama.com/settings/keys"
            case .zai: "open.bigmodel.cn"
            case .cloudflare: "dash.cloudflare.com → AI → Workers AI → Use REST API"
            }
        }

        var keychainKey: KeychainStore.Key {
            switch self {
            case .gemini: .gemini
            case .groq: .groq
            case .ollama: .ollama
            case .zai: .zai
            case .cloudflare: .cloudflareToken
            }
        }

        /// Requests at once; Z AI's free tier takes one.
        var maxConcurrent: Int { self == .zai ? 1 : 8 }

        /// The OpenAI-compatible base and key, or nil when the key (or Cloudflare's account id) is missing.
        func endpoint() -> FreeLLMClient.Endpoint? {
            guard let key = KeychainStore.read(keychainKey) else { return nil }
            let base: String
            switch self {
            case .gemini: base = "https://generativelanguage.googleapis.com/v1beta/openai"
            case .groq: base = "https://api.groq.com/openai/v1"
            case .ollama: base = "https://ollama.com/v1"
            case .zai: base = "https://open.bigmodel.cn/api/paas/v4"
            case .cloudflare:
                guard let account = KeychainStore.read(.cloudflareAccount) else { return nil }
                base = "https://api.cloudflare.com/client/v4/accounts/\(account)/ai/v1"
            }
            guard let url = URL(string: base) else { return nil }
            return FreeLLMClient.Endpoint(baseURL: url, apiKey: key)
        }
    }

    struct Model: Hashable, Sendable {
        let provider: Provider
        let id: String
        let note: String
        /// Lower where the free tier or the context window is small.
        var maxOutput = 16_384

        /// "provider:model-id", as in providers.toml.
        var name: String { "\(provider.rawValue):\(id)" }
        var title: String { "\(provider.title) · \(id)" }
    }

    /// providers.toml's `order`: "automatic" tries these top to bottom.
    static let models: [Model] = [
        Model(provider: .gemini, id: "gemini-3.6-flash", note: "20 a day"),
        Model(provider: .gemini, id: "gemini-3.5-flash", note: "20 a day, its own quota"),
        Model(provider: .groq, id: "openai/gpt-oss-120b", note: "1,000 a day, 131K context", maxOutput: 8_192),
        Model(provider: .ollama, id: "gpt-oss:120b", note: "weekly limits, 128K context"),
        Model(provider: .zai, id: "glm-4.7-flash", note: "one request at a time, 200K context"),
        Model(provider: .ollama, id: "nemotron-3-ultra", note: "weekly limits, 262K context"),
        Model(provider: .cloudflare, id: "@cf/openai/gpt-oss-120b", note: "10,000 neurons a day, 128K context"),
        Model(provider: .groq, id: "openai/gpt-oss-20b", note: "1,000 a day", maxOutput: 8_192),
        Model(provider: .cloudflare, id: "@cf/meta/llama-3.3-70b-instruct-fp8-fast", note: "24K context", maxOutput: 4_096),
        Model(provider: .cloudflare, id: "@cf/mistralai/mistral-small-3.1-24b-instruct", note: "128K context")
    ]

    /// The free-llms .env names. Claude and Soniox keys are left out on purpose: they cost money,
    /// so they are only ever typed into Settings.
    static let envNames: [String: KeychainStore.Key] = [
        "GEMINI_API_KEY": .gemini, "GROQ_API_KEY": .groq, "OLLAMA_API_KEY": .ollama, "ZAI_API_KEY": .zai,
        "CLOUDFLARE_API_TOKEN": .cloudflareToken, "CLOUDFLARE_ACCOUNT_ID": .cloudflareAccount
    ]

    /// Saves the free keys found in `NAME=value` lines (a free-llms .env) to the Keychain and
    /// returns their names.
    @discardableResult
    static func importKeys(fromEnv text: String) -> [String] {
        var imported: [String] = []
        for line in text.split(whereSeparator: \.isNewline) {
            var entry = line.trimmingCharacters(in: .whitespaces)
            if entry.hasPrefix("export ") { entry.removeFirst(7) }
            let parts = entry.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, let key = envNames[parts[0]] else { continue }
            var value = parts[1]
            if let comment = value.range(of: " #") { value = String(value[..<comment.lowerBound]) }
            value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
            guard !value.isEmpty else { continue }
            if KeychainStore.read(key) != value { KeychainStore.save(value, for: key) }
            imported.append(parts[0])
        }
        return imported
    }

    #if DEBUG
    /// Debug builds only: a .env dropped into the Dawwen source folder is copied into the app, and its
    /// free keys go to the Keychain at launch. Release builds leave the file out of the app
    /// (EXCLUDED_SOURCE_FILE_NAMES in the project), so the keys never ship.
    static func importBundledEnv() {
        let url = Bundle.main.bundleURL.appendingPathComponent(".env")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        importKeys(fromEnv: text)
    }
    #endif

    /// One short request to the provider's first model, through the same path as a real question:
    /// proves the key, the model id and the request format. Spends one request of the free quota.
    static func test(_ provider: Provider) async -> String {
        guard let model = models.first(where: { $0.provider == provider }) else { return "no models" }
        guard var client = FreeLLMClient.current(models: [model]) else {
            return provider == .cloudflare && KeychainStore.read(.cloudflareToken) != nil
                ? "add the Cloudflare account ID" : "no key"
        }
        client.maxRetries = 0
        let request = ClaudeClient.Request(preamble: "Reply with the single word OK.", context: "",
                                           userMessage: "Test", effort: "low", maxTokens: 300)
        do {
            let reply = try await client.complete(request)
            return "works ✓ (\(model.id) replied: \(reply.trimmingCharacters(in: .whitespacesAndNewlines).prefix(30)))"
        } catch {
            return error.localizedDescription
        }
    }

    /// providers.toml's `extra_body`.
    static func extraBody(for model: Model) -> [String: Any] {
        switch model.provider {
        // Thinking is spent out of max_tokens; "minimal" leaves the budget for the answer.
        case .gemini: ["reasoning_effort": "minimal"]
        case .groq where model.id.hasPrefix("openai/gpt-oss"): ["reasoning_effort": "low"]
        // GLM thinks by default; off keeps answers quick.
        case .zai: ["thinking": ["type": "disabled"]]
        default: [:]
        }
    }
}

/// Which free models are resting after an error, and how many requests each provider has open.
/// Kept in memory: after a relaunch every model is tried again.
actor FreeLLMState {
    static let shared = FreeLLMState()

    private var restingUntil: [String: Date] = [:]
    private var open: [FreeLLM.Provider: Int] = [:]

    func isResting(_ model: FreeLLM.Model) -> Bool {
        (restingUntil[model.name] ?? .distantPast) > .now
    }

    func rest(_ model: FreeLLM.Model, seconds: Double) {
        restingUntil[model.name] = Date.now.addingTimeInterval(seconds)
    }

    func reserve(_ provider: FreeLLM.Provider) -> Bool {
        let count = open[provider, default: 0]
        guard count < provider.maxConcurrent else { return false }
        open[provider] = count + 1
        return true
    }

    func release(_ provider: FreeLLM.Provider) {
        open[provider] = max(0, open[provider, default: 1] - 1)
    }
}

/// Streams a reply from the first free model that answers. With several models (automatic), one
/// that fails before writing anything (limit reached, bad key, request too large) hands over to the
/// next; with one model it retries up to 3 times, like ClaudeClient.
struct FreeLLMClient: TextModelClient {
    struct Endpoint: Sendable {
        let baseURL: URL
        let apiKey: String
    }

    /// Only models whose provider has a key; tried in this order.
    let models: [FreeLLM.Model]
    let endpoints: [FreeLLM.Provider: Endpoint]
    /// Retries of a single model after a rate limit or a dropped connection.
    var maxRetries = 3

    enum FreeError: LocalizedError {
        case missingKey
        case http(String, Int, String)
        case api(String, String)
        case invalidResponse(String)
        case allResting
        case noneAnswered(String)

        var errorDescription: String? {
            switch self {
            case .missingKey: "Add a free key for this model (Gemini, Groq, Ollama, Z AI or Cloudflare) in Settings."
            case .http(let model, let code, let message): "\(model) error (\(code)): \(message)"
            case .api(let model, let message): "\(model) error: \(message)"
            case .invalidResponse(let model): "Unexpected response from \(model)."
            case .allResting: "Every free model with a key has reached its limit for now. Try again later, add another free key, or pick Claude in Settings."
            case .noneAnswered(let last): "None of the free models answered. The last error: \(last)"
            }
        }
    }

    /// Failed before any text arrived, so another try (or another model) is safe.
    private struct Skip: Error {
        let underlying: Error
        /// How long this model sits out; nil when only this request was the problem.
        let rest: Double?
        let retryable: Bool
        var retryAfter: Double?
    }

    private static let transientNetworkCodes: Set<URLError.Code> = [
        .networkConnectionLost, .timedOut, .notConnectedToInternet, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed
    ]

    /// nil when none of `models` has a key in the Keychain.
    static func current(models: [FreeLLM.Model]) -> FreeLLMClient? {
        var endpoints: [FreeLLM.Provider: Endpoint] = [:]
        for provider in Set(models.map(\.provider)) {
            endpoints[provider] = provider.endpoint()
        }
        let usable = models.filter { endpoints[$0.provider] != nil }
        guard !usable.isEmpty else { return nil }
        return FreeLLMClient(models: usable, endpoints: endpoints)
    }

    func stream(_ request: ClaudeClient.Request) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let state = FreeLLMState.shared
                let single = models.count == 1
                var lastError: Error?
                var attempt = 0
                var index = 0
                while index < models.count, !Task.isCancelled {
                    let model = models[index]
                    if !single, await state.isResting(model) {
                        index += 1
                        continue
                    }
                    guard await state.reserve(model.provider) else {
                        // Busy (Z AI takes one request at a time): move on, or wait when it's the last one.
                        if index + 1 < models.count { index += 1 } else { try? await Task.sleep(for: .seconds(1)) }
                        continue
                    }
                    var delivered = false
                    let outcome: Result<Void, Error>
                    do {
                        try await streamOnce(request, model: model) { text in
                            delivered = true
                            continuation.yield(text)
                        }
                        outcome = .success(())
                    } catch {
                        outcome = .failure(error)
                    }
                    await state.release(model.provider)
                    switch outcome {
                    case .success:
                        continuation.finish()
                        return
                    case .failure(let skip as Skip) where !delivered:
                        lastError = skip.underlying
                        if let rest = skip.rest { await state.rest(model, seconds: rest) }
                        if single, skip.retryable, attempt < maxRetries {
                            attempt += 1
                            try? await Task.sleep(for: .seconds(min(skip.retryAfter ?? pow(2, Double(attempt)), 30)))
                        } else {
                            index += 1
                        }
                    case .failure(let skip as Skip):
                        continuation.finish(throwing: skip.underlying)
                        return
                    case .failure(let error):
                        continuation.finish(throwing: error)
                        return
                    }
                }
                if Task.isCancelled {
                    continuation.finish()
                } else if let lastError {
                    continuation.finish(throwing: single ? lastError : FreeError.noneAnswered(lastError.localizedDescription))
                } else {
                    continuation.finish(throwing: FreeError.allResting)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The whole reply as one string (structured JSON outputs).
    func complete(_ request: ClaudeClient.Request) async throws -> String {
        var text = ""
        for try await piece in stream(request) { text += piece }
        // Some models wrap the JSON in ``` fences or add a sentence around it; keep the object.
        if request.outputSchema != nil,
           let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end {
            return String(text[start...end])
        }
        return text
    }

    private func streamOnce(_ request: ClaudeClient.Request, model: FreeLLM.Model, onText: (String) -> Void) async throws {
        guard let endpoint = endpoints[model.provider] else {
            throw Skip(underlying: FreeError.missingKey, rest: nil, retryable: false)
        }
        do {
            let result: (URLSession.AsyncBytes, URLResponse) = try await URLSession.shared.bytes(
                for: makeURLRequest(request, model: model, endpoint: endpoint)
            )
            let (bytes, response) = result
            guard let http = response as? HTTPURLResponse else {
                throw Skip(underlying: FreeError.invalidResponse(model.title), rest: 30, retryable: false)
            }
            guard http.statusCode == 200 else {
                var body = Data()
                for try await byte in bytes { body.append(byte) }
                let message = ClaudeClient.errorMessage(in: body)
                let retryAfter = http.value(forHTTPHeaderField: "retry-after").flatMap { Double($0) }
                throw Skip(
                    underlying: FreeError.http(model.title, http.statusCode, message),
                    rest: Self.rest(status: http.statusCode, message: message, retryAfter: retryAfter),
                    retryable: [408, 429, 500, 502, 503, 504].contains(http.statusCode),
                    retryAfter: retryAfter
                )
            }
            var wroteText = false
            var finishReason: String?
            for try await line in bytes.lines {
                guard line.hasPrefix("data:") else { continue }
                let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                if payload == "[DONE]" { break }
                guard let event = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else { continue }
                if let error = event["error"] {
                    let message = (error as? [String: Any])?["message"] as? String ?? (error as? String) ?? "Unknown error"
                    throw Skip(underlying: FreeError.api(model.title, message), rest: nil, retryable: false)
                }
                guard let choice = (event["choices"] as? [[String: Any]])?.first else { continue }
                // Only the answer: reasoning models stream their thinking in a separate field.
                if let delta = choice["delta"] as? [String: Any], let text = delta["content"] as? String, !text.isEmpty {
                    wroteText = true
                    onText(text)
                }
                if let reason = choice["finish_reason"] as? String { finishReason = reason }
            }
            guard wroteText else {
                throw Skip(underlying: FreeError.api(model.title, "empty reply"), rest: nil, retryable: false)
            }
            if finishReason == "length", request.outputSchema == nil {
                onText("\n\n_(The response stopped at the maximum length)_")
            }
        } catch let error as URLError where Self.transientNetworkCodes.contains(error.code) {
            throw Skip(underlying: error, rest: nil, retryable: true)
        }
    }

    /// How long a model sits out after an error, as the free-llm router does.
    private static func rest(status: Int, message: String, retryAfter: Double?) -> Double? {
        switch status {
        case 429:
            // Daily quota spent: leave it for an hour. Per-minute limit: what the server asks, or a minute.
            let lower = message.lowercased()
            let daily = ["per day", "perday", "daily", "tpd", "rpd"].contains { lower.contains($0) }
            return daily ? 3600 : (retryAfter ?? 60)
        case 402, 404: return 6 * 3600   // not on the free tier, or the model was retired
        case 500...599: return 30
        default: return nil              // 400, 401, 413: this request or a key the student can fix now
        }
    }

    private func makeURLRequest(_ request: ClaudeClient.Request, model: FreeLLM.Model, endpoint: Endpoint) throws -> URLRequest {
        var system = request.preamble
        if !request.context.isEmpty { system += "\n\n" + request.context }
        var body = FreeLLM.extraBody(for: model)
        if let schema = request.outputSchema,
           let object = try? JSONSerialization.jsonObject(with: Data(schema.utf8)) {
            system += "\n\nReply with only a JSON object that matches this JSON Schema, and nothing else:\n" + schema
            if model.provider == .zai {
                body["response_format"] = ["type": "json_object"]  // GLM takes no schema
            } else {
                body["response_format"] = [
                    "type": "json_schema",
                    "json_schema": ["name": "reply", "schema": object, "strict": true] as [String: Any]
                ] as [String: Any]
            }
        }
        body["model"] = model.id
        body["stream"] = true
        body["max_tokens"] = min(request.maxTokens, model.maxOutput)
        body["messages"] = [
            ["role": "system", "content": system],
            ["role": "user", "content": request.userMessage]
        ]
        var urlRequest = URLRequest(url: endpoint.baseURL.appendingPathComponent("chat/completions"))
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 900
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        urlRequest.setValue("Bearer \(endpoint.apiKey)", forHTTPHeaderField: "authorization")
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
        return urlRequest
    }
}
