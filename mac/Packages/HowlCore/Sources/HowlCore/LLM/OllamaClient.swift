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
    public static let defaultBaseURL: URL = URL(string: "http://localhost:11434")!

    private let baseURL: URL
    private let session: URLSession

    public init(baseURL: URL = OllamaClient.defaultBaseURL,
                session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    /// POST /api/generate with no prompt — asks Ollama to load `model`
    /// into memory and keep it resident for `keepAlive`. Returns once
    /// the load completes (typically 5–15 s for a fresh 8B model on
    /// CPU; sub-second if already warm). Use as a hint right after the
    /// user picks a model so their first real dictation is fast.
    ///
    /// Throws the usual `OllamaClientError` cases on failure, but most
    /// callers should treat this as best-effort and ignore errors —
    /// any failure here surfaces again on the next real Clean call.
    public func preloadModel(_ model: String, keepAlive: String = "30m") async throws {
        let url = baseURL.appendingPathComponent("api/generate")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Up to 30 s — model load can be slow on cold disks. Real Clean
        // calls have their own (longer) timeout in the Go core.
        req.timeoutInterval = 30
        struct Body: Encodable {
            let model: String
            let keep_alive: String
        }
        req.httpBody = try? JSONEncoder().encode(Body(model: model, keep_alive: keepAlive))

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
        // Body shape on success is {"model":..., "done":true, "done_reason":"load", ...}.
        // We don't need to decode it; the 200 is the signal.
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
