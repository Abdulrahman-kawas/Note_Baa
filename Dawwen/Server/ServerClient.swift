import Foundation

/// The optional Dawwen gateway (AWS Lambda). Nothing in the recording path depends on it: every
/// call here has an on-device or direct-key fallback.
///
/// Auth: one token per device, "<device id>.<secret>", made by server/tools/issue_device_token.py and
/// pasted once into Settings. It lives in the Keychain; the server keeps only its SHA-256.
struct ServerClient: Sendable {
    let baseURL: URL
    let token: String

    static var current: ServerClient? {
        guard let raw = UserDefaults.standard.string(forKey: SettingsKey.gatewayURL)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              let url = URL(string: raw), url.scheme == "https",
              let token = KeychainStore.read(.gatewayToken), token.contains(".") else { return nil }
        return ServerClient(baseURL: url, token: token)
    }

    enum ServerError: LocalizedError {
        case http(Int, String)
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .http(let code, let message): "Server error (\(code)): \(message)"
            case .invalidResponse: "Unexpected response from the server."
            }
        }
    }

    // MARK: - Wire types (snake_case, as the FastAPI models expect)

    struct ClaudeCall: Encodable, Sendable {
        let model: String
        let preamble: String
        let context: String
        let userMessage: String
        let effort: String
        let maxTokens: Int
        let outputSchema: String?

        enum CodingKeys: String, CodingKey {
            case model, preamble, context, effort
            case userMessage = "user_message"
            case maxTokens = "max_tokens"
            case outputSchema = "output_schema"
        }
    }

    struct RefineRequest: Encodable, Sendable {
        let customID: String
        let userMessage: String
        enum CodingKeys: String, CodingKey {
            case customID = "custom_id"
            case userMessage = "user_message"
        }
    }

    struct RefinePayload: Encodable, Sendable {
        let model: String
        let preamble: String
        let context: String
        let effort: String
        let maxTokens: Int
        let outputSchema: String
        let requests: [RefineRequest]
        enum CodingKeys: String, CodingKey {
            case model, preamble, context, effort, requests
            case maxTokens = "max_tokens"
            case outputSchema = "output_schema"
        }
    }

    struct JobRequest: Encodable, Sendable {
        let type: String          // summary | refine_translation | hq_asr
        let lectureID: UUID
        let engine: String        // claude-batch | home
        var claude: ClaudeCall?
        var refine: RefinePayload?
        var language: String?
        enum CodingKeys: String, CodingKey {
            case type, engine, claude, refine, language
            case lectureID = "lecture_id"
        }
    }

    struct Job: Decodable, Sendable {
        let id: String
        let type: String
        let status: String        // queued | running | done | failed
        let error: String?
        let resultURL: URL?
        enum CodingKeys: String, CodingKey {
            case id, type, status, error
            case resultURL = "result_url"
        }
    }

    /// Batch results: `{"type": ..., "results": {"<custom id>": {"text": ...} | {"error": ...}}}`.
    struct JobResult: Decodable, Sendable {
        struct Item: Decodable, Sendable {
            let text: String?
            let error: String?
        }
        let type: String
        let results: [String: Item]?
    }

    struct UploadTarget: Decodable, Sendable {
        let url: URL
        let headers: [String: String]
    }

    private struct UploadBody: Encodable {
        let lectureID: UUID
        let name: String
        let sha256: String
        let bytes: Int
        enum CodingKeys: String, CodingKey {
            case name, sha256, bytes
            case lectureID = "lecture_id"
        }
    }

    private struct TemporaryKey: Decodable {
        let apiKey: String
        enum CodingKeys: String, CodingKey { case apiKey = "api_key" }
    }

    // MARK: - Endpoints

    func sonioxTemporaryKey() async throws -> String {
        let key: TemporaryKey = try await send(request("/v1/soniox/temp-key", method: "POST"))
        return key.apiKey
    }

    /// For ClaudeClient: same SSE stream as api.anthropic.com.
    func claudeRequest(_ call: ClaudeCall) throws -> URLRequest {
        var urlRequest = try request("/v1/claude/messages", method: "POST", body: call)
        urlRequest.timeoutInterval = 900
        return urlRequest
    }

    func uploadTarget(lectureID: UUID, name: String, sha256: String, bytes: Int) async throws -> UploadTarget {
        try await send(request("/v1/backup/upload-url", method: "POST",
                               body: UploadBody(lectureID: lectureID, name: name, sha256: sha256, bytes: bytes)))
    }

    func createJob(_ job: JobRequest) async throws -> Job {
        try await send(request("/v1/jobs", method: "POST", body: job))
    }

    func job(_ id: String) async throws -> Job {
        try await send(request("/v1/jobs/\(id)"))
    }

    func result(of job: Job) async throws -> Data {
        guard let url = job.resultURL else { throw ServerError.invalidResponse }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ServerError.invalidResponse }
        return data
    }

    // MARK: - Plumbing

    private func request(_ path: String, method: String = "GET") throws -> URLRequest {
        // Function URLs end with "/"; avoid "//v1/..." (FastAPI would answer 404).
        var base = baseURL.absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + path) else { throw ServerError.invalidResponse }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = method
        urlRequest.timeoutInterval = 60
        urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return urlRequest
    }

    private func request<Body: Encodable>(_ path: String, method: String, body: Body) throws -> URLRequest {
        var urlRequest = try request(path, method: method)
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONEncoder().encode(body)
        return urlRequest
    }

    private func send<T: Decodable>(_ urlRequest: URLRequest) async throws -> T {
        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else { throw ServerError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw ServerError.http(http.statusCode, ClaudeClient.errorMessage(in: data))
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
