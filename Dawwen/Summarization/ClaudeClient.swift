import Foundation

/// Minimal streaming client for the Claude Messages API (no official Swift SDK; raw HTTP + SSE).
struct ClaudeClient: Sendable {
    let apiKey: String
    let model: ClaudeModelOption

    struct Request: Sendable {
        /// Stable instructions, sent first in `system`.
        var preamble: String
        /// The transcript. Marked for prompt caching, so follow-up questions on the
        /// same lecture read it from cache.
        var context: String
        var userMessage: String
        var effort: String = "high"
        var maxTokens = 64_000
    }

    enum ClaudeError: LocalizedError {
        case missingKey
        case http(Int, String)
        case api(String)
        case refusal
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .missingKey: "أضف مفتاح Claude API من الإعدادات."
            case .http(let code, let message): "خطأ من Claude (\(code)): \(message)"
            case .api(let message): "خطأ من Claude: \(message)"
            case .refusal: "رفض النموذج إكمال الطلب. جرّب نموذجاً آخر من الإعدادات."
            case .invalidResponse: "رد غير متوقع من Claude."
            }
        }
    }

    /// Streams the text of the reply as it is generated.
    func stream(_ request: Request) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: try makeURLRequest(request))
                    guard let http = response as? HTTPURLResponse else { throw ClaudeError.invalidResponse }
                    guard http.statusCode == 200 else {
                        var body = Data()
                        for try await byte in bytes { body.append(byte) }
                        throw ClaudeError.http(http.statusCode, Self.errorMessage(in: body))
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
                                continuation.yield(text)
                            }
                        case "message_delta":
                            if let delta = event["delta"] as? [String: Any], let reason = delta["stop_reason"] as? String {
                                stopReason = reason
                            }
                        case "error":
                            let error = event["error"] as? [String: Any]
                            throw ClaudeError.api(error?["message"] as? String ?? "خطأ غير معروف")
                        default:
                            break // message_start, content_block_start/stop, thinking deltas, ping, message_stop
                        }
                    }
                    // Check the stop reason before treating the text as complete.
                    if stopReason == "refusal" { throw ClaudeError.refusal }
                    if stopReason == "max_tokens" {
                        continuation.yield("\n\n_(توقف الرد عند الحد الأقصى للطول)_")
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func makeURLRequest(_ request: Request) throws -> URLRequest {
        var urlRequest = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 900
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        var body: [String: Any] = [
            "model": model.rawValue,
            "max_tokens": request.maxTokens,
            "stream": true,
            "thinking": ["type": "adaptive"],
            "output_config": ["effort": request.effort],
            "system": [
                ["type": "text", "text": request.preamble],
                ["type": "text", "text": request.context, "cache_control": ["type": "ephemeral"]]
            ],
            "messages": [
                ["role": "user", "content": request.userMessage]
            ]
        ]
        if model.supportsServerFallback {
            // If a safety classifier declines, the API retries on Anthropic's recommended model.
            body["fallbacks"] = "default"
            urlRequest.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        }
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
        return urlRequest
    }

    private static func errorMessage(in body: Data) -> String {
        if let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
           let error = object["error"] as? [String: Any],
           let message = error["message"] as? String {
            return message
        }
        return String(decoding: body.prefix(300), as: UTF8.self)
    }
}
