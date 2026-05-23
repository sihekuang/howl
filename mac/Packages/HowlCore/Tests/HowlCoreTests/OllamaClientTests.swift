import Foundation
import Testing
@testable import HowlCore

/// URLProtocol subclass that returns canned responses. Handlers are
/// registered per host so multiple test suites (Ollama at localhost,
/// Anthropic at api.anthropic.com, OpenAI at api.openai.com) can run
/// concurrently without their static state clobbering each other.
final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) private static var handlers: [String: (URLRequest) -> (HTTPURLResponse, Data?, Error?)] = [:]
    nonisolated(unsafe) private static let lock = NSLock()

    /// Register a handler for requests whose URL.host equals `host`.
    /// Pass nil to unregister; safe to call from any test.
    static func setHandler(
        for host: String,
        _ handler: ((URLRequest) -> (HTTPURLResponse, Data?, Error?))?
    ) {
        lock.lock(); defer { lock.unlock() }
        if let handler = handler {
            handlers[host] = handler
        } else {
            handlers.removeValue(forKey: host)
        }
    }

    private static func handler(for host: String) -> ((URLRequest) -> (HTTPURLResponse, Data?, Error?))? {
        lock.lock(); defer { lock.unlock() }
        return handlers[host]
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let host = request.url?.host ?? ""
        guard let handler = MockURLProtocol.handler(for: host) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        let (response, data, error) = handler(request)
        if let error = error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if let data = data { client?.urlProtocol(self, didLoad: data) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite("OllamaClient", .serialized)
struct OllamaClientTests {
    private func makeClient(handler: @escaping (URLRequest) -> (HTTPURLResponse, Data?, Error?)) -> OllamaClient {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [MockURLProtocol.self]
        MockURLProtocol.setHandler(for: "localhost", handler)
        let session = URLSession(configuration: cfg)
        return OllamaClient(baseURL: URL(string: "http://localhost:11434")!, session: session)
    }

    @Test func listModels_Success() async throws {
        let body = """
        {"models":[
          {"name":"llama3.2:latest","modified_at":"","size":0},
          {"name":"qwen2.5:14b","modified_at":"","size":0}
        ]}
        """.data(using: .utf8)!
        let client = makeClient { req in
            #expect(req.url?.path == "/api/tags")
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body, nil)
        }
        let names = try await client.listModels()
        #expect(names == ["llama3.2:latest", "qwen2.5:14b"])
    }

    @Test func listModels_EmptyList() async throws {
        let body = #"{"models":[]}"#.data(using: .utf8)!
        let client = makeClient { req in
            (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body, nil)
        }
        let names = try await client.listModels()
        #expect(names.isEmpty)
    }

    @Test func listModels_HTTP503() async throws {
        let client = makeClient { req in
            (HTTPURLResponse(url: req.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!,
             "service unavailable".data(using: .utf8), nil)
        }
        do {
            _ = try await client.listModels()
            Issue.record("expected error to be thrown")
        } catch let OllamaClientError.http(status, _) {
            #expect(status == 503)
        } catch {
            Issue.record("wrong error type: \(error)")
        }
    }

    @Test func listModels_ConnectionRefused() async throws {
        let client = makeClient { _ in
            (HTTPURLResponse(url: URL(string: "http://localhost:11434")!, statusCode: 0, httpVersion: nil, headerFields: nil)!,
             nil, URLError(.cannotConnectToHost))
        }
        do {
            _ = try await client.listModels()
            Issue.record("expected error to be thrown")
        } catch OllamaClientError.unreachable {
            // expected
        } catch {
            Issue.record("wrong error type: \(error)")
        }
    }

    @Test func listModels_GarbageJSON() async throws {
        let body = "not json".data(using: .utf8)!
        let client = makeClient { req in
            (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body, nil)
        }
        do {
            _ = try await client.listModels()
            Issue.record("expected error to be thrown")
        } catch OllamaClientError.decode {
            // expected
        } catch {
            Issue.record("wrong error type: \(error)")
        }
    }

    @Test func preloadModel_Success() async throws {
        let body = #"{"model":"llama3.2","done":true,"done_reason":"load"}"#.data(using: .utf8)!
        let client = makeClient { req in
            #expect(req.url?.path == "/api/generate")
            #expect(req.httpMethod == "POST")
            // Verify the body carries model + keep_alive.
            if let bodyData = req.httpBodyStreamData() ?? req.httpBody,
               let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any] {
                #expect(json["model"] as? String == "llama3.2")
                #expect(json["keep_alive"] as? String == "30m")
            } else {
                Issue.record("preload body did not parse as JSON")
            }
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body, nil)
        }
        try await client.preloadModel("llama3.2")
    }

    @Test func preloadModel_HTTPError() async {
        let client = makeClient { req in
            (HTTPURLResponse(url: req.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!,
             #"{"error":"model 'missing' not found"}"#.data(using: .utf8), nil)
        }
        do {
            try await client.preloadModel("missing")
            Issue.record("expected error")
        } catch OllamaClientError.http(let status, _) {
            #expect(status == 404)
        } catch {
            Issue.record("wrong error type: \(error)")
        }
    }

    @Test func preloadModel_Unreachable() async {
        let client = makeClient { _ in
            (HTTPURLResponse(url: URL(string: "http://localhost:11434")!, statusCode: 0, httpVersion: nil, headerFields: nil)!,
             nil, URLError(.cannotConnectToHost))
        }
        do {
            try await client.preloadModel("llama3.2")
            Issue.record("expected error")
        } catch OllamaClientError.unreachable {
            // expected
        } catch {
            Issue.record("wrong error type: \(error)")
        }
    }
}

// URLRequest's httpBody can be nil for streaming bodies; this helper
// reads from httpBodyStream when present so tests don't have to know
// which form was used. Returns nil if neither is set.
private extension URLRequest {
    func httpBodyStreamData() -> Data? {
        guard let stream = httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufSize = 1024
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
        defer { buf.deallocate() }
        while stream.hasBytesAvailable {
            let n = stream.read(buf, maxLength: bufSize)
            if n <= 0 { break }
            data.append(buf, count: n)
        }
        return data.isEmpty ? nil : data
    }
}
