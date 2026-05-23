import Foundation

public enum OpenAIClientError: Error, Equatable {
    /// Connection-level failure (refused, DNS, timeout, etc.).
    case unreachable(URL)
    /// Server returned a non-2xx HTTP status. body is best-effort —
    /// callers can surface its first line for diagnostics.
    case http(status: Int, body: String)
    /// Response body wasn't the expected JSON shape.
    case decode(String)
}

/// One row from /v1/models. OpenAI doesn't expose a display_name field,
/// so we use the id as the label too. Sections can prettify if desired.
public struct OpenAIModel: Equatable, Identifiable, Sendable {
    public let id: String   // e.g. "gpt-4o-mini"

    public init(id: String) {
        self.id = id
    }
}

/// Minimal client for the OpenAI HTTP API. Constructed per-request: a
/// single Settings-tab interaction (loading models, validating the key).
public actor OpenAIClient {
    public static let defaultBaseURL: URL = URL(string: "https://api.openai.com")!

    private let baseURL: URL
    private let apiKey: String
    private let session: URLSession

    public init(apiKey: String,
                baseURL: URL = OpenAIClient.defaultBaseURL,
                session: URLSession = .shared) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.session = session
    }

    /// GET /v1/models — all models the key is authorized for, then filter
    /// down to chat-completion models that support streaming. OpenAI's
    /// list mixes in whisper, dall-e, embeddings, tts, etc., so we have
    /// to filter client-side.
    public func listModels() async throws -> [OpenAIModel] {
        let url = baseURL.appendingPathComponent("v1/models")
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 10

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw OpenAIClientError.unreachable(url)
        }

        guard let http = response as? HTTPURLResponse else {
            throw OpenAIClientError.decode("non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw OpenAIClientError.http(status: http.statusCode, body: body)
        }

        struct Page: Decodable {
            struct Row: Decodable { let id: String }
            let data: [Row]
        }
        let page: Page
        do {
            page = try JSONDecoder().decode(Page.self, from: data)
        } catch {
            throw OpenAIClientError.decode(String(describing: error))
        }

        return page.data
            .map(\.id)
            .filter(Self.isChatStreamingCapable)
            .sorted()
            .map(OpenAIModel.init)
    }

    /// Heuristic for "this id is a chat-completion model that supports
    /// streaming." OpenAI doesn't expose a capabilities field on
    /// /v1/models, so we go by id family + exclusions. Conservative —
    /// false negatives mean a user has to pick a model manually; false
    /// positives mean the picker offers an id that won't work for
    /// chat/streaming. We err toward false negatives.
    static func isChatStreamingCapable(_ id: String) -> Bool {
        // Chat-family prefixes. o1/o3/o4 are reasoning models; chatgpt-*
        // is the alias family OpenAI uses internally.
        let chatPrefixes = ["gpt-", "o1", "o3", "o4", "chatgpt-"]
        guard chatPrefixes.contains(where: id.hasPrefix) else { return false }

        // Substrings that indicate a non-chat-text variant of an otherwise
        // chat-prefixed id (e.g. gpt-4o-audio-preview, gpt-4o-transcribe,
        // gpt-4o-realtime-preview). These don't accept the
        // /chat/completions request shape we use.
        let nonChatSubstrings = [
            "audio", "tts", "transcribe", "realtime",
            "whisper", "embedding", "dall-e", "moderation", "search",
            "image", "instruct",
        ]
        if nonChatSubstrings.contains(where: id.contains) { return false }

        return true
    }
}
