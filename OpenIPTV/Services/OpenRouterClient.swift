import Foundation

/// Minimal OpenRouter chat-completions client (OpenAI-compatible API).
///
/// Used only by `EPGFormatter` to tidy up guide text. Separate from
/// `IPTVRepository`, which is the Xtream network layer. Only the request body
/// you pass is sent — callers must never include account details or stream
/// URLs.
struct OpenRouterClient: Sendable {
    static let endpoint = URL(string: "https://openrouter.ai/api/v1/chat/completions")!
    static let defaultModel = "google/gemini-3.8-flash"

    let apiKey: String
    let model: String
    var session: URLSession = .shared

    struct Usage: Decodable, Sendable {
        let promptTokens: Int?
        let completionTokens: Int?

        enum CodingKeys: String, CodingKey {
            case promptTokens = "prompt_tokens"
            case completionTokens = "completion_tokens"
        }

        var total: Int { (promptTokens ?? 0) + (completionTokens ?? 0) }
    }

    enum ClientError: LocalizedError, Equatable {
        case invalidKey
        case outOfCredits
        case rateLimited(retryAfter: TimeInterval?)
        case unsupportedModel(String)
        case http(status: Int, message: String)
        case emptyResponse
        case unreadable(String)

        var errorDescription: String? {
            switch self {
            case .invalidKey:
                return String(localized: "OpenRouter rejected the API key.")
            case .outOfCredits:
                return String(localized: "Your OpenRouter account is out of credits.")
            case .rateLimited:
                return String(localized: "OpenRouter is rate limiting requests. Retrying shortly.")
            case .unsupportedModel(let message):
                return String(localized: "The model isn't available: \(message)")
            case .http(let status, let message):
                return String(localized: "OpenRouter error \(status): \(message)")
            case .emptyResponse:
                return String(localized: "The model returned an empty response.")
            case .unreadable(let detail):
                return String(localized: "Couldn't read the model's response: \(detail)")
            }
        }

        /// Errors that won't fix themselves — formatting pauses until the
        /// user changes settings, so a bad key or empty wallet can't loop.
        var isFatal: Bool {
            switch self {
            case .invalidKey, .outOfCredits, .unsupportedModel: return true
            default: return false
            }
        }
    }

    /// Sends one chat completion. When `schema` is given, requests strict JSON
    /// output; if the provider rejects structured output (HTTP 400), retries
    /// once without it and relies on the prompt.
    func complete(
        system: String,
        user: String,
        schema: [String: Any]?,
        maxTokens: Int = 4000
    ) async throws -> (content: String, usage: Usage?) {
        do {
            return try await send(system: system, user: user, schema: schema, maxTokens: maxTokens)
        } catch ClientError.http(let status, _) where status == 400 && schema != nil {
            return try await send(system: system, user: user, schema: nil, maxTokens: maxTokens)
        }
    }

    private func send(
        system: String,
        user: String,
        schema: [String: Any]?,
        maxTokens: Int
    ) async throws -> (content: String, usage: Usage?) {
        var body: [String: Any] = [
            "model": model,
            "temperature": 0,
            "max_tokens": maxTokens,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user]
            ]
        ]
        if let schema {
            body["response_format"] = [
                "type": "json_schema",
                "json_schema": ["name": "epg_cleanup", "strict": true, "schema": schema]
            ]
        }

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let decoded = try? JSONDecoder().decode(ChatResponse.self, from: data)

        if status != 200 || decoded?.error != nil {
            let message = decoded?.error?.message ?? String(data: data.prefix(300), encoding: .utf8) ?? ""
            // Errors in a 200 body carry their own code; fall back to the HTTP status.
            let bodyCode = decoded?.error?.code ?? 0
            let code = bodyCode != 0 ? bodyCode : status
            switch code {
            case 401, 403: throw ClientError.invalidKey
            case 402: throw ClientError.outOfCredits
            case 404: throw ClientError.unsupportedModel(message)
            case 429:
                let retry = (response as? HTTPURLResponse)?
                    .value(forHTTPHeaderField: "Retry-After")
                    .flatMap(TimeInterval.init)
                throw ClientError.rateLimited(retryAfter: retry)
            default:
                throw ClientError.http(status: code, message: message)
            }
        }

        guard let decoded else { throw ClientError.unreadable("not a chat completion") }
        guard let content = decoded.choices.first?.message.content,
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw ClientError.emptyResponse }
        return (content, decoded.usage)
    }

    private struct ChatResponse: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable { let content: String? }
            let message: Message
        }
        struct APIError: Decodable {
            let code: Int?
            let message: String?

            enum CodingKeys: String, CodingKey { case code, message }

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                code = c.flexibleInt(.code, default: 0)
                message = try? c.decode(String.self, forKey: .message)
            }
        }
        let choices: [Choice]
        let usage: Usage?
        let error: APIError?

        enum CodingKeys: String, CodingKey { case choices, usage, error }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            choices = (try? c.decode([Choice].self, forKey: .choices)) ?? []
            usage = try? c.decode(Usage.self, forKey: .usage)
            error = try? c.decode(APIError.self, forKey: .error)
        }
    }
}
