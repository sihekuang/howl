import Foundation

public enum AnthropicClientError: Error, Equatable {
    /// Connection-level failure (refused, DNS, timeout, etc.).
    case unreachable(URL)
    /// Server returned a non-2xx HTTP status. body is best-effort —
    /// callers can surface its first line for diagnostics.
    case http(status: Int, body: String)
    /// Response body wasn't the expected JSON shape.
    case decode(String)
}

/// One row from /v1/models. Exposes both the API id (used in Cleaner
/// requests as model="...") and the human-friendly display name (shown
/// in the Settings picker).
public struct AnthropicModel: Equatable, Identifiable, Sendable {
    public let id: String           // e.g. "claude-sonnet-4-6"
    public let displayName: String  // e.g. "Claude Sonnet 4.6"

    public init(id: String, displayName: String) {
        self.id = id
        self.displayName = displayName
    }
}

/// Minimal client for the Anthropic HTTP API. Constructed per-request:
/// the typical lifetime is a single Settings-tab interaction (loading
/// models, validating the key on Save).
public actor AnthropicClient {
    public static let defaultBaseURL: URL = URL(string: "https://api.anthropic.com")!

    private let baseURL: URL
    private let apiKey: String
    private let session: URLSession

    public init(apiKey: String,
                baseURL: URL = AnthropicClient.defaultBaseURL,
                session: URLSession = .shared) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.session = session
    }

    /// GET /v1/models — list all models the key is authorized for. Filters
    /// to ids starting with "claude-" so we don't accidentally surface
    /// internal/legacy models that aren't chat-capable. All Claude chat
    /// models support streaming, so no separate streaming filter is
    /// needed for this provider.
    public func listModels() async throws -> [AnthropicModel] {
        let url = baseURL.appendingPathComponent("v1/models")
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.timeoutInterval = 10

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw AnthropicClientError.unreachable(url)
        }

        guard let http = response as? HTTPURLResponse else {
            throw AnthropicClientError.decode("non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw AnthropicClientError.http(status: http.statusCode, body: body)
        }

        struct Page: Decodable {
            struct Row: Decodable {
                let id: String
                let display_name: String?
            }
            let data: [Row]
        }
        let page: Page
        do {
            page = try JSONDecoder().decode(Page.self, from: data)
        } catch {
            throw AnthropicClientError.decode(String(describing: error))
        }
        return page.data
            .filter { $0.id.hasPrefix("claude-") }
            .map { AnthropicModel(id: $0.id, displayName: $0.display_name ?? $0.id) }
    }
}
