import Foundation
import Testing
@testable import VoiceKeyboardCore

@Suite("OpenAIClient", .serialized)
struct OpenAIClientTests {
    private func makeClient(
        apiKey: String = "sk-test",
        handler: @escaping (URLRequest) -> (HTTPURLResponse, Data?, Error?)
    ) -> OpenAIClient {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [MockURLProtocol.self]
        MockURLProtocol.setHandler(for: "api.openai.com", handler)
        let session = URLSession(configuration: cfg)
        return OpenAIClient(
            apiKey: apiKey,
            baseURL: URL(string: "https://api.openai.com")!,
            session: session
        )
    }

    @Test func listModels_FiltersToChatStreamingFamilies() async throws {
        // Realistic mix from /v1/models.
        let body = """
        {"object":"list","data":[
          {"id":"gpt-4o-mini","object":"model"},
          {"id":"gpt-4o","object":"model"},
          {"id":"gpt-4o-audio-preview","object":"model"},
          {"id":"gpt-4o-transcribe","object":"model"},
          {"id":"o1","object":"model"},
          {"id":"o3-mini","object":"model"},
          {"id":"chatgpt-4o-latest","object":"model"},
          {"id":"text-embedding-3-large","object":"model"},
          {"id":"whisper-1","object":"model"},
          {"id":"tts-1","object":"model"},
          {"id":"dall-e-3","object":"model"},
          {"id":"davinci-002","object":"model"},
          {"id":"gpt-3.5-turbo-instruct","object":"model"}
        ]}
        """.data(using: .utf8)!
        let client = makeClient { req in
            #expect(req.url?.path == "/v1/models")
            #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body, nil)
        }
        let ids = try await client.listModels().map(\.id)
        // Chat-streaming families only, sorted.
        #expect(ids == ["chatgpt-4o-latest", "gpt-4o", "gpt-4o-mini", "o1", "o3-mini"])
    }

    @Test func listModels_HTTP401Auth() async throws {
        let client = makeClient { req in
            (HTTPURLResponse(url: req.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!,
             #"{"error":{"message":"Incorrect API key","type":"invalid_request_error"}}"#.data(using: .utf8), nil)
        }
        do {
            _ = try await client.listModels()
            Issue.record("expected error")
        } catch let OpenAIClientError.http(status, _) {
            #expect(status == 401)
        } catch {
            Issue.record("wrong error type: \(error)")
        }
    }

    @Test func listModels_Unreachable() async throws {
        let client = makeClient { _ in
            (HTTPURLResponse(url: URL(string: "https://api.openai.com")!, statusCode: 0, httpVersion: nil, headerFields: nil)!,
             nil, URLError(.cannotConnectToHost))
        }
        do {
            _ = try await client.listModels()
            Issue.record("expected error")
        } catch OpenAIClientError.unreachable {
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
        } catch OpenAIClientError.decode {
            // expected
        } catch {
            Issue.record("wrong error type: \(error)")
        }
    }

    @Test func isChatStreamingCapable_excludesEmbeddingsAndAudio() {
        #expect(OpenAIClient.isChatStreamingCapable("gpt-4o-mini"))
        #expect(OpenAIClient.isChatStreamingCapable("gpt-4o"))
        #expect(OpenAIClient.isChatStreamingCapable("o1"))
        #expect(OpenAIClient.isChatStreamingCapable("o3-mini"))
        #expect(OpenAIClient.isChatStreamingCapable("chatgpt-4o-latest"))

        #expect(!OpenAIClient.isChatStreamingCapable("gpt-4o-audio-preview"))
        #expect(!OpenAIClient.isChatStreamingCapable("gpt-4o-transcribe"))
        #expect(!OpenAIClient.isChatStreamingCapable("whisper-1"))
        #expect(!OpenAIClient.isChatStreamingCapable("text-embedding-3-large"))
        #expect(!OpenAIClient.isChatStreamingCapable("dall-e-3"))
        #expect(!OpenAIClient.isChatStreamingCapable("tts-1"))
        #expect(!OpenAIClient.isChatStreamingCapable("davinci-002"))
        #expect(!OpenAIClient.isChatStreamingCapable("gpt-3.5-turbo-instruct"))
    }
}
