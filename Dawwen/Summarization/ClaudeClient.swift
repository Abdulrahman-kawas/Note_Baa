import Foundation

/// Minimal streaming client for the Claude Messages API (no official Swift SDK; raw HTTP + SSE).
/// Talks to Anthropic directly with the Keychain key, or to the Dawwen gateway, which holds the key,
/// caps spending and relays the same event stream.
struct ClaudeClient: Sendable {
    enum Backend: Sendable {
        case direct(apiKey: String)
        case gateway(ServerClient)
    }

    let backend: Backend
    let model: ClaudeModelOption

    struct Request: Sendable {
        /// Stable instructions, sent first in `system`.
        var preamble: String
        /// The transcript (or glossary). Marked for prompt caching, so follow-up questions on the
        /// same lecture read it from cache. Left out when empty.
        var context: String
        var userMessage: String
        var effort: String = "high"
        var maxTokens = 64_000
        /// JSON Schema text: the reply becomes JSON matching it (`output_config.format`).
        var outputSchema: String?
    }

    enum ClaudeError: LocalizedError {
        case missingKey
        case http(Int, String)
        case api(String)
        case refusal
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .missingKey: "Add a Claude API key in Settings, or turn on Claude through the server."
            case .http(let code, let message): "Claude error (\(code)): \(message)"
            case .api(let message): "Claude error: \(message)"
            case .refusal: "The model declined to complete the request. Try another model in Settings."
            case .invalidResponse: "Unexpected response from Claude."
            }
        }
    }

    /// Worth another try: overload, rate limit, a dropped connection before any text arrived.
    private struct Retryable: Error {
        let underlying: Error
        let retryAfter: Double?
    }

    private static let retryStatuses: Set<Int> = [408, 429, 500, 502, 503, 504, 529]
    private static let transientNetworkCodes: Set<URLError.Code> = [
        .networkConnectionLost, .timedOut, .notConnectedToInternet, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed
    ]

    /// The gateway when it is configured for Claude, else the key in the Keychain.
    static func current(model: ClaudeModelOption) -> ClaudeClient? {
        let settings = AppSettings.current
        if settings.claudeViaGateway, let server = ServerClient.current {
            return ClaudeClient(backend: .gateway(server), model: model)
        }
        if let key = KeychainStore.read(.anthropic) {
            return ClaudeClient(backend: .direct(apiKey: key), model: model)
        }
        return nil
    }

    /// Streams the text of the reply as it is generated. Retries up to 3 times (exponential
    /// back-off, or `retry-after`) as long as no text has been delivered yet.
    func stream(_ request: Request) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var attempt = 0
                while true {
                    var delivered = false
                    do {
                        try await streamOnce(request) { text in
                            delivered = true
                            continuation.yield(text)
                        }
                        continuation.finish()
                        return
                    } catch let retry as Retryable where !delivered && attempt < 3 && !Task.isCancelled {
                        attempt += 1
                        let delay = retry.retryAfter ?? pow(2, Double(attempt))
                        try? await Task.sleep(for: .seconds(min(delay, 30)))
                    } catch let retry as Retryable {
                        continuation.finish(throwing: retry.underlying)
                        return
                    } catch {
                        continuation.finish(throwing: error)
                        return
                    }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The whole reply as one string (structured JSON outputs).
    func complete(_ request: Request) async throws -> String {
        var text = ""
        for try await piece in stream(request) { text += piece }
        return text
    }

    private func streamOnce(_ request: Request, onText: (String) -> Void) async throws {
        do {
            let result: (URLSession.AsyncBytes, URLResponse) = try await URLSession.shared.bytes(for: makeURLRequest(request))
            let (bytes, response) = result
            guard let http = response as? HTTPURLResponse else { throw ClaudeError.invalidResponse }
            guard http.statusCode == 200 else {
                var body = Data()
                for try await byte in bytes { body.append(byte) }
                let error = ClaudeError.http(http.statusCode, Self.errorMessage(in: body))
                if Self.retryStatuses.contains(http.statusCode) {
                    let retryAfter = http.value(forHTTPHeaderField: "retry-after").flatMap { Double($0) }
                    throw Retryable(underlying: error, retryAfter: retryAfter)
                }
                throw error
            }
            var stopReason: String?
            for try await line in bytes.lines {
                guard line.hasPrefix("data:") else { continue }
                let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                guard let event = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any],
                      let type = event["type"] as? String else { continue }
                switch type {
                case "content_block_delta":
                    if let delta = event["delta"] as? [String: Any],
                       delta["type"] as? String == "text_delta",
                       let text = delta["text"] as? String {
                        onText(text)
                    }
                case "message_delta":
                    if let delta = event["delta"] as? [String: Any], let reason = delta["stop_reason"] as? String {
                        stopReason = reason
                    }
                case "error":
                    let error = event["error"] as? [String: Any]
                    let message = error?["message"] as? String ?? "Unknown error"
                    if error?["type"] as? String == "overloaded_error" {
                        throw Retryable(underlying: ClaudeError.api(message), retryAfter: nil)
                    }
                    throw ClaudeError.api(message)
                default:
                    break // message_start, content_block_start/stop, thinking deltas, ping, message_stop
                }
            }
            // Check the stop reason before treating the text as complete.
            if stopReason == "refusal" { throw ClaudeError.refusal }
            if stopReason == "max_tokens", request.outputSchema == nil {
                onText("\n\n_(The response stopped at the maximum length)_")
            }
        } catch let error as URLError where Self.transientNetworkCodes.contains(error.code) {
            throw Retryable(underlying: error, retryAfter: nil)
        }
    }

    private func makeURLRequest(_ request: Request) throws -> URLRequest {
        switch backend {
        case .direct(let apiKey):
            var urlRequest = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
            urlRequest.httpMethod = "POST"
            urlRequest.timeoutInterval = 900
            urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
            urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            urlRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            if model.supportsServerFallback {
                // If a safety classifier declines, the API retries on Anthropic's recommended model.
                urlRequest.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
            }
            urlRequest.httpBody = try JSONSerialization.data(withJSONObject: Self.messagesBody(model: model, request: request))
            return urlRequest
        case .gateway(let server):
            return try server.claudeRequest(ServerClient.ClaudeCall(
                model: model.rawValue,
                preamble: request.preamble,
                context: request.context,
                userMessage: request.userMessage,
                effort: request.effort,
                maxTokens: request.maxTokens,
                outputSchema: request.outputSchema
            ))
        }
    }

    /// Kept identical to `build_params` in server/gateway/app/claude.py.
    static func messagesBody(model: ClaudeModelOption, request: Request) -> [String: Any] {
        var outputConfig: [String: Any] = ["effort": request.effort]
        if let schema = request.outputSchema,
           let object = try? JSONSerialization.jsonObject(with: Data(schema.utf8)) {
            outputConfig["format"] = ["type": "json_schema", "schema": object]
        }
        var system: [[String: Any]] = [["type": "text", "text": request.preamble]]
        if !request.context.isEmpty {
            system.append(["type": "text", "text": request.context, "cache_control": ["type": "ephemeral"]])
        }
        var body: [String: Any] = [
            "model": model.rawValue,
            "max_tokens": request.maxTokens,
            "stream": true,
            "thinking": ["type": "adaptive"],
            "output_config": outputConfig,
            "system": system,
            "messages": [["role": "user", "content": request.userMessage]]
        ]
        if model.supportsServerFallback { body["fallbacks"] = "default" }
        return body
    }

    static func errorMessage(in body: Data) -> String {
        if let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
           let error = object["error"] as? [String: Any],
           let message = error["message"] as? String {
            return message
        }
        return String(decoding: body.prefix(300), as: UTF8.self)
    }
}
