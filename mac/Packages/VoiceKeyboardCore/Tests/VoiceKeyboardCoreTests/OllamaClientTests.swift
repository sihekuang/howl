import Foundation
import Testing
@testable import VoiceKeyboardCore

/// URLProtocol subclass that returns canned responses keyed by URL path.
final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (HTTPURLResponse, Data?, Error?))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = MockURLProtocol.handler else {
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
        MockURLProtocol.handler = handler
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
}
