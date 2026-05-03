import Foundation
import Testing
@testable import VoiceKeyboardCore

@Suite("LMStudioClient", .serialized)
struct LMStudioClientTests {
    private func makeClient(handler: @escaping (URLRequest) -> (HTTPURLResponse, Data?, Error?)) -> LMStudioClient {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [MockURLProtocol.self]
        // MockURLProtocol routes by host; `127.0.0.1` keeps us out of
        // the localhost bucket the OllamaClient tests register, so the
        // two suites can run in parallel without trampling each other.
        MockURLProtocol.setHandler(for: "127.0.0.1", handler)
        let session = URLSession(configuration: cfg)
        return LMStudioClient(baseURL: URL(string: "http://127.0.0.1:1234/v1")!, session: session)
    }

    @Test func listModels_Success() async throws {
        let body = """
        {"object":"list","data":[
          {"id":"qwen2.5-7b-instruct","object":"model"},
          {"id":"llama-3.2-3b-instruct","object":"model"}
        ]}
        """.data(using: .utf8)!
        let client = makeClient { req in
            #expect(req.url?.path == "/v1/models")
            #expect(req.value(forHTTPHeaderField: "Authorization") == nil)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body, nil)
        }
        let names = try await client.listModels()
        #expect(names == ["qwen2.5-7b-instruct", "llama-3.2-3b-instruct"])
    }

    @Test func listModels_EmptyList() async throws {
        let body = #"{"object":"list","data":[]}"#.data(using: .utf8)!
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
        } catch let LMStudioClientError.http(status, _) {
            #expect(status == 503)
        } catch {
            Issue.record("wrong error type: \(error)")
        }
    }

    @Test func listModels_ConnectionRefused() async throws {
        let client = makeClient { _ in
            (HTTPURLResponse(url: URL(string: "http://127.0.0.1:1234/v1")!, statusCode: 0, httpVersion: nil, headerFields: nil)!,
             nil, URLError(.cannotConnectToHost))
        }
        do {
            _ = try await client.listModels()
            Issue.record("expected error to be thrown")
        } catch LMStudioClientError.unreachable {
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
        } catch LMStudioClientError.decode {
            // expected
        } catch {
            Issue.record("wrong error type: \(error)")
        }
    }
}
