import Foundation
import Testing
@testable import HowlCore

@Suite("AnthropicClient", .serialized)
struct AnthropicClientTests {
    private func makeClient(
        apiKey: String = "sk-ant-test",
        handler: @escaping (URLRequest) -> (HTTPURLResponse, Data?, Error?)
    ) -> AnthropicClient {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [MockURLProtocol.self]
        MockURLProtocol.setHandler(for: "api.anthropic.com", handler)
        let session = URLSession(configuration: cfg)
        return AnthropicClient(
            apiKey: apiKey,
            baseURL: URL(string: "https://api.anthropic.com")!,
            session: session
        )
    }

    @Test func listModels_Success() async throws {
        let body = """
        {"data":[
          {"id":"claude-opus-4-7","display_name":"Claude Opus 4.7","type":"model"},
          {"id":"claude-sonnet-4-6","display_name":"Claude Sonnet 4.6","type":"model"}
        ],"has_more":false}
        """.data(using: .utf8)!
        let client = makeClient { req in
            #expect(req.url?.path == "/v1/models")
            #expect(req.value(forHTTPHeaderField: "x-api-key") == "sk-ant-test")
            #expect(req.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body, nil)
        }
        let models = try await client.listModels()
        #expect(models.count == 2)
        #expect(models[0].id == "claude-opus-4-7")
        #expect(models[0].displayName == "Claude Opus 4.7")
    }

    @Test func listModels_FiltersNonClaudePrefix() async throws {
        // /v1/models can in principle return non-claude entries (legacy
        // or experimental). The client should drop those.
        let body = """
        {"data":[
          {"id":"claude-haiku-4-5","display_name":"Claude Haiku 4.5","type":"model"},
          {"id":"text-embedding-3","display_name":"Text Embedding","type":"model"}
        ]}
        """.data(using: .utf8)!
        let client = makeClient { req in
            (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body, nil)
        }
        let models = try await client.listModels()
        #expect(models.map(\.id) == ["claude-haiku-4-5"])
    }

    @Test func listModels_FallsBackToIdWhenDisplayNameMissing() async throws {
        let body = #"{"data":[{"id":"claude-opus-4-7","type":"model"}]}"#.data(using: .utf8)!
        let client = makeClient { req in
            (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body, nil)
        }
        let models = try await client.listModels()
        #expect(models[0].displayName == "claude-opus-4-7")
    }

    @Test func listModels_HTTP401Auth() async throws {
        let client = makeClient { req in
            (HTTPURLResponse(url: req.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!,
             #"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#.data(using: .utf8), nil)
        }
        do {
            _ = try await client.listModels()
            Issue.record("expected error")
        } catch let AnthropicClientError.http(status, _) {
            #expect(status == 401)
        } catch {
            Issue.record("wrong error type: \(error)")
        }
    }

    @Test func listModels_Unreachable() async throws {
        let client = makeClient { _ in
            (HTTPURLResponse(url: URL(string: "https://api.anthropic.com")!, statusCode: 0, httpVersion: nil, headerFields: nil)!,
             nil, URLError(.cannotConnectToHost))
        }
        do {
            _ = try await client.listModels()
            Issue.record("expected error")
        } catch AnthropicClientError.unreachable {
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
            Issue.record("expected error")
        } catch AnthropicClientError.decode {
            // expected
        } catch {
            Issue.record("wrong error type: \(error)")
        }
    }
}
