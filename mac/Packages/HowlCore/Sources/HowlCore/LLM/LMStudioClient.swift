import Foundation

public enum LMStudioClientError: Error, Equatable {
    /// Connection-level failure (refused, DNS, timeout, etc.).
    case unreachable(URL)
    /// Server returned a non-2xx HTTP status.
    case http(status: Int, body: String)
    /// Response body wasn't the expected JSON shape.
    case decode(String)
}

/// Minimal client for the local LM Studio HTTP API.
///
/// LM Studio exposes an OpenAI-compatible REST surface under `/v1` on
/// port 1234 by default; we only use `/v1/models` to populate the
/// model picker. The actual chat call goes through the Go core's
/// OpenAI-compatible Cleaner.
///
/// Constructed per-request (per Settings-tab interaction).
public actor LMStudioClient {
    public static let defaultBaseURL: URL = URL(string: "http://localhost:1234/v1")!

    private let baseURL: URL
    private let session: URLSession

    public init(baseURL: URL = LMStudioClient.defaultBaseURL,
                session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    /// GET /v1/models — list available models. Order preserved from the
    /// server (LM Studio currently returns models in the order they were
    /// loaded / discovered on disk).
    public func listModels() async throws -> [String] {
        let url = baseURL.appendingPathComponent("models")
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 5

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw LMStudioClientError.unreachable(url)
        }

        guard let http = response as? HTTPURLResponse else {
            throw LMStudioClientError.decode("non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw LMStudioClientError.http(status: http.statusCode, body: body)
        }

        struct Page: Decodable {
            struct Row: Decodable { let id: String }
            let data: [Row]
        }
        do {
            let page = try JSONDecoder().decode(Page.self, from: data)
            return page.data.map(\.id)
        } catch {
            throw LMStudioClientError.decode(String(describing: error))
        }
    }
}
