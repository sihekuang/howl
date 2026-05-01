import Foundation

public enum OllamaClientError: Error, Equatable {
    /// Connection-level failure (refused, DNS, timeout, etc.).
    case unreachable(URL)
    /// Server returned a non-2xx HTTP status.
    case http(status: Int, body: String)
    /// Response body wasn't the expected JSON shape.
    case decode(String)
}

/// Minimal client for the local Ollama HTTP API.
/// Currently only enumerates installed models; constructed per-request
/// because the typical lifetime is a single Settings-tab interaction.
public actor OllamaClient {
    private let baseURL: URL
    private let session: URLSession

    public init(baseURL: URL = URL(string: "http://localhost:11434")!,
                session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    /// GET /api/tags — list installed models. Returns names in the
    /// order the Ollama service returns them (typically newest first).
    public func listModels() async throws -> [String] {
        let url = baseURL.appendingPathComponent("api/tags")
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 5

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw OllamaClientError.unreachable(url)
        }

        guard let http = response as? HTTPURLResponse else {
            throw OllamaClientError.decode("non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw OllamaClientError.http(status: http.statusCode, body: body)
        }

        struct Tags: Decodable {
            struct Model: Decodable { let name: String }
            let models: [Model]
        }
        do {
            let tags = try JSONDecoder().decode(Tags.self, from: data)
            return tags.models.map(\.name)
        } catch {
            throw OllamaClientError.decode(String(describing: error))
        }
    }
}
