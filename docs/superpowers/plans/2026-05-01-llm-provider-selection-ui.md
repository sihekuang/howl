# LLM Provider Selection UI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Surface the multi-provider LLM cleanup support shipped in PR #5 to the macOS app's Settings → Provider tab. Users can switch between Anthropic and Ollama, pick a model from each, and configure non-default Ollama endpoints when needed.

**Architecture:** Single tab with a top-level provider `Picker`, conditional sub-blocks per provider. New `OllamaClient` actor in `VoiceKeyboardCore` queries `/api/tags` on demand. `UserSettings` and `EngineConfig` gain a single new field (`llmBaseURL`) — the Go core (PR #5) already accepts the corresponding JSON key.

**Tech Stack:** SwiftUI (Form, Picker, disclosure groups), Swift Concurrency (actor + async/await + URLSession), URLProtocol-based mocks for `OllamaClient` tests, existing `XCTest` suite in `mac/Packages/VoiceKeyboardCore/Tests/`. Build/test via `make -C mac test` (Swift package tests) and `make -C mac build` (full .app).

**Spec:** `docs/superpowers/specs/2026-05-01-llm-provider-selection-ui-design.md`

---

### Task 1: Add `llmBaseURL` to `UserSettings`

**Files:**
- Modify: `mac/Packages/VoiceKeyboardCore/Sources/VoiceKeyboardCore/Storage/SettingsStore.swift`
- Test:   `mac/Packages/VoiceKeyboardCore/Tests/VoiceKeyboardCoreTests/SettingsStoreTests.swift`

- [ ] **Step 1: Write the failing test for round-trip + back-compat decode**

Append the following to `mac/Packages/VoiceKeyboardCore/Tests/VoiceKeyboardCoreTests/SettingsStoreTests.swift` inside the existing test class:

```swift
func testUserSettings_LLMBaseURL_RoundTrip() throws {
    var s = UserSettings()
    s.llmBaseURL = "http://10.0.0.5:11434"
    let data = try JSONEncoder().encode(s)
    let decoded = try JSONDecoder().decode(UserSettings.self, from: data)
    XCTAssertEqual(decoded.llmBaseURL, "http://10.0.0.5:11434")
}

func testUserSettings_LLMBaseURL_DefaultsEmptyOnLegacyBlob() throws {
    // Simulates a UserDefaults blob written before this PR (no llmBaseURL key).
    let legacyJSON = """
    {
      "whisperModelSize": "small",
      "language": "en",
      "disableNoiseSuppression": false,
      "llmProvider": "anthropic",
      "llmModel": "claude-sonnet-4-6",
      "customDict": [],
      "hotkey": {},
      "tseEnabled": false
    }
    """
    let data = legacyJSON.data(using: .utf8)!
    let decoded = try JSONDecoder().decode(UserSettings.self, from: data)
    XCTAssertEqual(decoded.llmBaseURL, "")
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd mac/Packages/VoiceKeyboardCore && swift test --filter SettingsStoreTests/testUserSettings_LLMBaseURL`
Expected: build error — `'UserSettings' has no member 'llmBaseURL'`.

- [ ] **Step 3: Add `llmBaseURL` to `UserSettings`**

Edit `mac/Packages/VoiceKeyboardCore/Sources/VoiceKeyboardCore/Storage/SettingsStore.swift`:

1. Add a stored property after `llmModel`:

```swift
public var llmModel: String
public var llmBaseURL: String   // NEW — empty = provider's default endpoint
public var customDict: [String]
```

2. Add the parameter to `init(...)` (default `""`) and assign it:

```swift
public init(
    whisperModelSize: String = "small",
    language: String = "en",
    disableNoiseSuppression: Bool = false,
    llmProvider: String = "anthropic",
    llmModel: String = "claude-sonnet-4-6",
    llmBaseURL: String = "",
    customDict: [String] = [],
    hotkey: KeyboardShortcut = .defaultPTT,
    inputDeviceUID: String? = nil,
    tseEnabled: Bool = false
) {
    // existing body, plus:
    self.llmBaseURL = llmBaseURL
}
```

3. In `init(from decoder:)`, decode with default `""`:

```swift
llmBaseURL = try c.decodeIfPresent(String.self, forKey: .llmBaseURL) ?? ""
```

4. Add the case to the `CodingKeys` enum (alphabetical group with the other LLM keys is fine).

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd mac/Packages/VoiceKeyboardCore && swift test --filter SettingsStoreTests`
Expected: all green, including the two new cases.

- [ ] **Step 5: Commit**

```bash
git add mac/Packages/VoiceKeyboardCore/Sources/VoiceKeyboardCore/Storage/SettingsStore.swift \
        mac/Packages/VoiceKeyboardCore/Tests/VoiceKeyboardCoreTests/SettingsStoreTests.swift
git commit -m "feat(settings): add llmBaseURL to UserSettings"
```

---

### Task 2: Add `llmBaseURL` to `EngineConfig`

**Files:**
- Modify: `mac/Packages/VoiceKeyboardCore/Sources/VoiceKeyboardCore/Bridge/EngineConfig.swift`
- Test:   `mac/Packages/VoiceKeyboardCore/Tests/VoiceKeyboardCoreTests/EngineConfigTests.swift`

- [ ] **Step 1: Write the failing test for JSON encoding under `llm_base_url` key**

Append to `EngineConfigTests.swift`:

```swift
func testEngineConfig_LLMBaseURL_EncodesUnderSnakeCaseKey() throws {
    let cfg = EngineConfig(
        whisperModelPath: "",
        whisperModelSize: "small",
        language: "en",
        disableNoiseSuppression: false,
        deepFilterModelPath: "",
        llmProvider: "ollama",
        llmModel: "llama3.2",
        llmAPIKey: "",
        customDict: [],
        llmBaseURL: "http://10.0.0.5:11434"
    )
    let data = try JSONEncoder().encode(cfg)
    let json = try XCTUnwrap(String(data: data, encoding: .utf8))
    XCTAssertTrue(json.contains("\"llm_base_url\":\"http://10.0.0.5:11434\""),
                  "expected llm_base_url in JSON, got: \(json)")
}

func testEngineConfig_LLMBaseURL_RoundTrip() throws {
    let cfg = EngineConfig(
        whisperModelPath: "/tmp/m.bin",
        whisperModelSize: "small",
        language: "en",
        disableNoiseSuppression: false,
        deepFilterModelPath: "",
        llmProvider: "ollama",
        llmModel: "qwen2.5:14b",
        llmAPIKey: "",
        customDict: [],
        llmBaseURL: ""
    )
    let data = try JSONEncoder().encode(cfg)
    let decoded = try JSONDecoder().decode(EngineConfig.self, from: data)
    XCTAssertEqual(decoded.llmBaseURL, "")
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd mac/Packages/VoiceKeyboardCore && swift test --filter EngineConfigTests/testEngineConfig_LLMBaseURL`
Expected: build error — `'EngineConfig' has no member 'llmBaseURL'` and the `init(...)` signature missing the parameter.

- [ ] **Step 3: Add `llmBaseURL` to `EngineConfig`**

Edit `mac/Packages/VoiceKeyboardCore/Sources/VoiceKeyboardCore/Bridge/EngineConfig.swift`:

1. Add the stored property after `llmAPIKey`:

```swift
public var llmAPIKey: String
public var llmBaseURL: String   // NEW — empty = provider's default endpoint
public var customDict: [String]
```

2. Add the parameter to `init(...)` after `llmAPIKey`. Default it to `""` for back-compat with existing call sites:

```swift
public init(
    whisperModelPath: String,
    whisperModelSize: String,
    language: String,
    disableNoiseSuppression: Bool,
    deepFilterModelPath: String,
    llmProvider: String,
    llmModel: String,
    llmAPIKey: String,
    customDict: [String],
    llmBaseURL: String = "",
    tseEnabled: Bool = false,
    tseProfileDir: String = "",
    tseModelPath: String = "",
    speakerEncoderPath: String = "",
    onnxLibPath: String = ""
) {
    // existing assignments, plus:
    self.llmBaseURL = llmBaseURL
}
```

3. Add the snake-cased key to `CodingKeys`:

```swift
case llmBaseURL = "llm_base_url"
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd mac/Packages/VoiceKeyboardCore && swift test --filter EngineConfigTests`
Expected: all green.

- [ ] **Step 5: Commit**

```bash
git add mac/Packages/VoiceKeyboardCore/Sources/VoiceKeyboardCore/Bridge/EngineConfig.swift \
        mac/Packages/VoiceKeyboardCore/Tests/VoiceKeyboardCoreTests/EngineConfigTests.swift
git commit -m "feat(engine): add llmBaseURL to EngineConfig (llm_base_url JSON key)"
```

---

### Task 3: `OllamaClient` actor with `listModels()`

**Files:**
- Create: `mac/Packages/VoiceKeyboardCore/Sources/VoiceKeyboardCore/LLM/OllamaClient.swift`
- Create: `mac/Packages/VoiceKeyboardCore/Tests/VoiceKeyboardCoreTests/OllamaClientTests.swift`

- [ ] **Step 1: Write the failing tests with URLProtocol mock**

Create `mac/Packages/VoiceKeyboardCore/Tests/VoiceKeyboardCoreTests/OllamaClientTests.swift`:

```swift
import XCTest
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

final class OllamaClientTests: XCTestCase {
    private func makeClient(handler: @escaping (URLRequest) -> (HTTPURLResponse, Data?, Error?)) -> OllamaClient {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [MockURLProtocol.self]
        MockURLProtocol.handler = handler
        let session = URLSession(configuration: cfg)
        return OllamaClient(baseURL: URL(string: "http://localhost:11434")!, session: session)
    }

    func testListModels_Success() async throws {
        let body = """
        {"models":[
          {"name":"llama3.2:latest","modified_at":"","size":0},
          {"name":"qwen2.5:14b","modified_at":"","size":0}
        ]}
        """.data(using: .utf8)!
        let client = makeClient { req in
            XCTAssertEqual(req.url?.path, "/api/tags")
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body, nil)
        }
        let names = try await client.listModels()
        XCTAssertEqual(names, ["llama3.2:latest", "qwen2.5:14b"])
    }

    func testListModels_EmptyList() async throws {
        let body = #"{"models":[]}"#.data(using: .utf8)!
        let client = makeClient { req in
            (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body, nil)
        }
        let names = try await client.listModels()
        XCTAssertEqual(names, [])
    }

    func testListModels_HTTP503() async {
        let client = makeClient { req in
            (HTTPURLResponse(url: req.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!,
             "service unavailable".data(using: .utf8), nil)
        }
        do {
            _ = try await client.listModels()
            XCTFail("expected error")
        } catch let OllamaClient.Error.http(status, _) {
            XCTAssertEqual(status, 503)
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testListModels_ConnectionRefused() async {
        let client = makeClient { _ in
            (HTTPURLResponse(url: URL(string: "http://localhost:11434")!, statusCode: 0, httpVersion: nil, headerFields: nil)!,
             nil, URLError(.cannotConnectToHost))
        }
        do {
            _ = try await client.listModels()
            XCTFail("expected error")
        } catch OllamaClient.Error.unreachable {
            // expected
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testListModels_GarbageJSON() async {
        let body = "not json".data(using: .utf8)!
        let client = makeClient { req in
            (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body, nil)
        }
        do {
            _ = try await client.listModels()
            XCTFail("expected error")
        } catch OllamaClient.Error.decode {
            // expected
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd mac/Packages/VoiceKeyboardCore && swift test --filter OllamaClientTests`
Expected: build error — `cannot find 'OllamaClient' in scope`.

- [ ] **Step 3: Implement `OllamaClient`**

Create `mac/Packages/VoiceKeyboardCore/Sources/VoiceKeyboardCore/LLM/OllamaClient.swift`:

```swift
import Foundation

/// Minimal client for the local Ollama HTTP API.
/// Currently only enumerates installed models; constructed per-request
/// because the typical lifetime is a single Settings-tab interaction.
public actor OllamaClient {
    public enum Error: Swift.Error, Equatable {
        /// Connection-level failure (refused, DNS, timeout, etc.).
        case unreachable(URL)
        /// Server returned a non-2xx HTTP status.
        case http(status: Int, body: String)
        /// Response body wasn't the expected JSON shape.
        case decode(String)
    }

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
        } catch let urlError as URLError {
            throw Error.unreachable(url).withCause(urlError)
        }

        guard let http = response as? HTTPURLResponse else {
            throw Error.decode("non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw Error.http(status: http.statusCode, body: body)
        }

        struct Tags: Decodable {
            struct Model: Decodable { let name: String }
            let models: [Model]
        }
        do {
            let tags = try JSONDecoder().decode(Tags.self, from: data)
            return tags.models.map(\.name)
        } catch {
            throw Error.decode(String(describing: error))
        }
    }
}

private extension OllamaClient.Error {
    /// Pass-through helper so the test can match `.unreachable` regardless
    /// of which underlying URLError code triggered it.
    func withCause(_: any Swift.Error) -> Self { self }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd mac/Packages/VoiceKeyboardCore && swift test --filter OllamaClientTests`
Expected: all five test cases green.

- [ ] **Step 5: Commit**

```bash
git add mac/Packages/VoiceKeyboardCore/Sources/VoiceKeyboardCore/LLM/OllamaClient.swift \
        mac/Packages/VoiceKeyboardCore/Tests/VoiceKeyboardCoreTests/OllamaClientTests.swift
git commit -m "feat(core): OllamaClient actor for /api/tags model listing"
```

---

### Task 4: Wire `llmBaseURL` through `EngineCoordinator` + gate API key on provider

**Files:**
- Modify: `mac/VoiceKeyboard/Engine/EngineCoordinator.swift`

- [ ] **Step 1: Locate the EngineConfig builder**

Run: `grep -n "EngineConfig(" mac/VoiceKeyboard/Engine/EngineCoordinator.swift`
Expected: one or two construction sites (typically inside `applyConfig()` or similar).

- [ ] **Step 2: Read the construction site**

Read the surrounding ~30 lines around each `EngineConfig(...)` call. Identify:
- Where `settings.llmAPIKey` (via `secrets.getAPIKey()`) is currently read
- Where `settings.llmModel` and `settings.llmProvider` are passed in
- Whether there's a single builder method or multiple

- [ ] **Step 3: Add `llmBaseURL` pass-through and gate `llmAPIKey` to anthropic**

For each `EngineConfig(...)` call site:

1. Add the new argument:

```swift
llmBaseURL: settings.llmBaseURL,
```

2. Replace any unconditional `llmAPIKey:` argument with a gated version:

```swift
llmAPIKey: settings.llmProvider == "anthropic" ? (try? secrets.getAPIKey()) ?? "" : "",
```

(Adjust the secret-read shape to match the existing code — the goal is "empty string when provider isn't anthropic" so non-anthropic providers don't ship the user's key over the C ABI.)

- [ ] **Step 4: Build + run the existing test suite**

```bash
make -C mac test
```

Expected: all green. (No new tests in this task — the data-flow change is covered by the Task 1/2 round-trip tests plus existing EngineCoordinator tests.)

- [ ] **Step 5: Commit**

```bash
git add mac/VoiceKeyboard/Engine/EngineCoordinator.swift
git commit -m "feat(engine): pass llmBaseURL through; gate llmAPIKey to anthropic"
```

---

### Task 5: Extract `AnthropicSection` subview from `ProviderTab`

**Files:**
- Create: `mac/VoiceKeyboard/UI/Settings/AnthropicSection.swift`
- Modify: `mac/VoiceKeyboard/UI/Settings/ProviderTab.swift`

This is a refactor — no behavior change. The existing Anthropic UI moves into a subview; `ProviderTab` becomes a thin wrapper that still only shows Anthropic content. The provider picker comes in Task 7.

- [ ] **Step 1: Read the current `ProviderTab.swift` in full**

Read `mac/VoiceKeyboard/UI/Settings/ProviderTab.swift` end-to-end (~120 lines). Note:
- The `@State` properties (`apiKeyDraft`, `apiKeyStatus`, `testStatus`)
- The `llmModels` array
- `body` shape: `Form { LabeledContent, Picker, SecureField, HStack of Buttons, Text status, testResultRow, Link }`
- `runTest()` async method

- [ ] **Step 2: Create `AnthropicSection.swift` with the existing content moved verbatim**

Create `mac/VoiceKeyboard/UI/Settings/AnthropicSection.swift`:

```swift
import SwiftUI
import VoiceKeyboardCore

/// Anthropic-specific settings. Shown when settings.llmProvider == "anthropic".
struct AnthropicSection: View {
    @Binding var settings: UserSettings
    let secrets: any SecretStore

    @State private var apiKeyDraft: String = ""
    @State private var apiKeyStatus: String = ""
    @State private var testStatus: TestStatus = .idle

    enum TestStatus: Equatable {
        case idle
        case testing
        case ok(String)
        case bad(String)
    }

    private let llmModels: [(id: String, label: String)] = [
        ("claude-opus-4-7",    "Opus 4.7 — most capable"),
        ("claude-sonnet-4-6",  "Sonnet 4.6 — balanced (default)"),
        ("claude-haiku-4-5",   "Haiku 4.5 — fastest, cheapest"),
    ]

    var body: some View {
        Group {
            Picker("Model", selection: $settings.llmModel) {
                ForEach(llmModels, id: \.id) { m in
                    Text(m.label).tag(m.id)
                }
            }
            SecureField("API Key", text: $apiKeyDraft, prompt: Text("sk-ant-..."))
            HStack {
                Button("Save") {
                    do {
                        try secrets.setAPIKey(apiKeyDraft)
                        apiKeyStatus = "Saved"
                    } catch {
                        apiKeyStatus = "Failed: \(error)"
                    }
                }
                .disabled(!apiKeyDraft.hasPrefix("sk-ant-"))

                Button(testStatus == .testing ? "Testing…" : "Test Key") {
                    Task { await runTest() }
                }
                .disabled(!apiKeyDraft.hasPrefix("sk-ant-") || testStatus == .testing)
            }
            Text(apiKeyStatus).foregroundStyle(.secondary)
            testResultRow
            Link("Get one from console.anthropic.com",
                 destination: URL(string: "https://console.anthropic.com/")!)
        }
        .task {
            apiKeyDraft = (try? secrets.getAPIKey()) ?? ""
        }
    }

    @ViewBuilder
    private var testResultRow: some View {
        switch testStatus {
        case .idle:
            EmptyView()
        case .testing:
            Label("Reaching api.anthropic.com…", systemImage: "ellipsis.circle")
                .foregroundStyle(.secondary)
        case .ok(let detail):
            Label("Key works — \(detail)", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .bad(let detail):
            Label(detail, systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
        }
    }

    private func runTest() async {
        testStatus = .testing
        let key = apiKeyDraft
        guard let url = URL(string: "https://api.anthropic.com/v1/models") else {
            testStatus = .bad("invalid URL")
            return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.timeoutInterval = 5

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else {
                testStatus = .bad("no HTTP response")
                return
            }
            switch http.statusCode {
            case 200:
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let arr = json["data"] as? [Any] {
                    testStatus = .ok("\(arr.count) models available")
                } else {
                    testStatus = .ok("HTTP 200")
                }
            case 401:
                testStatus = .bad("Invalid API key (HTTP 401)")
            case 403:
                testStatus = .bad("Key not authorized for this resource (HTTP 403)")
            case 429:
                testStatus = .bad("Rate-limited (HTTP 429)")
            default:
                let body = String(data: data, encoding: .utf8) ?? ""
                let snippet = body.prefix(120)
                testStatus = .bad("HTTP \(http.statusCode): \(snippet)")
            }
        } catch {
            testStatus = .bad("Network error: \(error.localizedDescription)")
        }
    }
}
```

- [ ] **Step 3: Slim down `ProviderTab.swift` to delegate to `AnthropicSection`**

Replace the whole body of `mac/VoiceKeyboard/UI/Settings/ProviderTab.swift` with:

```swift
import SwiftUI
import VoiceKeyboardCore

struct ProviderTab: View {
    @Binding var settings: UserSettings
    let onSave: (UserSettings) -> Void
    let secrets: any SecretStore

    var body: some View {
        Form {
            // Provider picker comes in Task 7. For now just show the
            // Anthropic block to keep parity with the pre-refactor UI.
            LabeledContent("Provider") { Text("Anthropic") }
            AnthropicSection(settings: $settings, secrets: secrets)
        }
        .formStyle(.grouped)
        .padding()
        .onChange(of: settings) { _, new in onSave(new) }
    }
}
```

- [ ] **Step 4: Build the .app**

```bash
make -C mac build
```

Expected: succeeds. (Pure refactor, no behavior change.)

- [ ] **Step 5: Commit**

```bash
git add mac/VoiceKeyboard/UI/Settings/AnthropicSection.swift \
        mac/VoiceKeyboard/UI/Settings/ProviderTab.swift
git commit -m "refactor(ui): extract AnthropicSection subview from ProviderTab"
```

---

### Task 6: Add `OllamaSection` subview with model picker, states, and Advanced base URL

**Files:**
- Create: `mac/VoiceKeyboard/UI/Settings/OllamaSection.swift`

This task delivers the full Ollama UX. The subview is self-contained: it owns its own loading state, refreshes against `settings.llmBaseURL`, and writes back to `$settings.llmModel`. It is **not yet wired into `ProviderTab`** — Task 7 does that.

- [ ] **Step 1: Create `OllamaSection.swift` with the loading state machine + UI**

Create `mac/VoiceKeyboard/UI/Settings/OllamaSection.swift`:

```swift
import SwiftUI
import VoiceKeyboardCore

/// Ollama-specific settings. Shown when settings.llmProvider == "ollama".
struct OllamaSection: View {
    @Binding var settings: UserSettings

    enum LoadState: Equatable {
        case idle
        case loading
        case loaded(models: [String])
        case empty                              // reachable, 0 installed
        case failed(message: String)
    }

    @State private var loadState: LoadState = .idle
    @State private var baseURLDraft: String = ""
    @State private var debounceTask: Task<Void, Never>?

    private static let defaultBaseURL = "http://localhost:11434"

    var body: some View {
        Group {
            modelRow
            advancedDisclosure
        }
        .task(id: effectiveBaseURL) {
            // Re-fires whenever effectiveBaseURL changes (incl. first appear).
            await refresh()
        }
        .onAppear {
            if baseURLDraft.isEmpty { baseURLDraft = settings.llmBaseURL }
        }
    }

    // MARK: – Model row (driven by loadState)

    @ViewBuilder
    private var modelRow: some View {
        switch loadState {
        case .idle, .loading:
            HStack {
                Text("Model")
                Spacer()
                ProgressView().controlSize(.small)
            }
        case .loaded(let models):
            HStack {
                Picker("Model", selection: $settings.llmModel) {
                    if !models.contains(settings.llmModel), !settings.llmModel.isEmpty {
                        // Keep the existing pick visible even if it's no longer installed.
                        Text("\(settings.llmModel) (not installed)").tag(settings.llmModel)
                    }
                    ForEach(models, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                Button {
                    Task { await refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh installed models")
            }
        case .empty:
            VStack(alignment: .leading, spacing: 6) {
                Text("No Ollama models installed.")
                Text("Run `ollama pull llama3.2` in your terminal, then refresh.")
                    .foregroundStyle(.secondary)
                    .font(.callout)
                HStack {
                    Button("Copy command") {
                        copyToPasteboard("ollama pull llama3.2")
                    }
                    Button("Refresh") { Task { await refresh() } }
                }
            }
        case .failed(let msg):
            VStack(alignment: .leading, spacing: 6) {
                Label("Couldn't reach Ollama at \(effectiveBaseURL)",
                      systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                Text(msg)
                    .foregroundStyle(.secondary)
                    .font(.callout)
                Text("Make sure Ollama is running, or change the base URL under Advanced.")
                    .foregroundStyle(.secondary)
                    .font(.callout)
                Button("Retry") { Task { await refresh() } }
            }
        }
    }

    // MARK: – Advanced disclosure (base URL)

    @ViewBuilder
    private var advancedDisclosure: some View {
        DisclosureGroup("Advanced") {
            HStack {
                TextField("Base URL", text: $baseURLDraft,
                          prompt: Text(Self.defaultBaseURL))
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: baseURLDraft) { _, new in
                        // Debounce 500ms so we don't fire on every keystroke.
                        debounceTask?.cancel()
                        debounceTask = Task {
                            try? await Task.sleep(nanoseconds: 500_000_000)
                            if Task.isCancelled { return }
                            settings.llmBaseURL = new == Self.defaultBaseURL ? "" : new
                        }
                    }
                Button("Reset to default") {
                    baseURLDraft = ""
                    settings.llmBaseURL = ""
                }
                .disabled(baseURLDraft.isEmpty)
            }
        }
    }

    // MARK: – Behaviour

    /// The URL we should actually hit. Empty `settings.llmBaseURL` means
    /// "use the default" (mirrors Go's `omitempty`).
    private var effectiveBaseURL: String {
        settings.llmBaseURL.isEmpty ? Self.defaultBaseURL : settings.llmBaseURL
    }

    private func refresh() async {
        loadState = .loading
        guard let url = URL(string: effectiveBaseURL) else {
            loadState = .failed(message: "Invalid URL.")
            return
        }
        let client = OllamaClient(baseURL: url)
        do {
            let names = try await client.listModels()
            loadState = names.isEmpty ? .empty : .loaded(models: names)
        } catch let OllamaClient.Error.unreachable(u) {
            loadState = .failed(message: "Connection refused at \(u.absoluteString)")
        } catch let OllamaClient.Error.http(status, body) {
            loadState = .failed(message: "HTTP \(status): \(body.prefix(120))")
        } catch let OllamaClient.Error.decode(detail) {
            loadState = .failed(message: "Bad response from Ollama: \(detail)")
        } catch {
            loadState = .failed(message: error.localizedDescription)
        }
    }

    private func copyToPasteboard(_ s: String) {
        #if canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
        #endif
    }
}

#if canImport(AppKit)
import AppKit
#endif
```

- [ ] **Step 2: Build the .app**

```bash
make -C mac build
```

Expected: succeeds. (`OllamaSection` isn't referenced from anywhere yet, but should compile in isolation.)

- [ ] **Step 3: Commit**

```bash
git add mac/VoiceKeyboard/UI/Settings/OllamaSection.swift
git commit -m "feat(ui): OllamaSection subview with model picker + Advanced base URL"
```

---

### Task 7: Wire the provider `Picker` into `ProviderTab`

**Files:**
- Modify: `mac/VoiceKeyboard/UI/Settings/ProviderTab.swift`

- [ ] **Step 1: Replace `ProviderTab.body` with the multi-provider version**

Edit `mac/VoiceKeyboard/UI/Settings/ProviderTab.swift`. Replace the whole body of `ProviderTab` with:

```swift
struct ProviderTab: View {
    @Binding var settings: UserSettings
    let onSave: (UserSettings) -> Void
    let secrets: any SecretStore

    private static let providers: [(id: String, label: String)] = [
        ("anthropic", "Anthropic — cloud"),
        ("ollama",    "Ollama — local"),
    ]

    var body: some View {
        Form {
            Picker("Provider", selection: $settings.llmProvider) {
                ForEach(Self.providers, id: \.id) { p in
                    Text(p.label).tag(p.id)
                }
            }
            .onChange(of: settings.llmProvider) { _, _ in
                // When switching to Ollama for the first time, clear the
                // Anthropic-shaped llmModel so the OllamaSection's picker
                // doesn't show "claude-sonnet-4-6 (not installed)".
                // Only clear if the current model clearly belongs to the
                // wrong provider — keep user-entered values otherwise.
                if settings.llmProvider == "ollama" && settings.llmModel.hasPrefix("claude-") {
                    settings.llmModel = ""
                }
                if settings.llmProvider == "anthropic" && !settings.llmModel.hasPrefix("claude-") {
                    settings.llmModel = "claude-sonnet-4-6"
                }
            }

            switch settings.llmProvider {
            case "anthropic":
                AnthropicSection(settings: $settings, secrets: secrets)
            case "ollama":
                OllamaSection(settings: $settings)
            default:
                Text("Unknown provider \(settings.llmProvider)")
                    .foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        .padding()
        .onChange(of: settings) { _, new in onSave(new) }
    }
}
```

- [ ] **Step 2: Build the .app**

```bash
make -C mac build
```

Expected: succeeds. (If a `switch` on String trips the SwiftUI `ViewBuilder` ergonomics, wrap the cases in a small `@ViewBuilder` helper — see Step 3.)

- [ ] **Step 3 (only if Step 2's build fails on the `switch`): wrap in a ViewBuilder helper**

If SwiftUI complains about the switch statement directly inside `Form`, refactor to a helper function:

```swift
@ViewBuilder
private var activeSection: some View {
    switch settings.llmProvider {
    case "anthropic": AnthropicSection(settings: $settings, secrets: secrets)
    case "ollama":    OllamaSection(settings: $settings)
    default: Text("Unknown provider \(settings.llmProvider)").foregroundStyle(.red)
    }
}
```

…and call `activeSection` in place of the inline switch.

- [ ] **Step 4: Run package tests**

```bash
make -C mac test
```

Expected: all green (no test changes in this task; verifying nothing regressed).

- [ ] **Step 5: Commit**

```bash
git add mac/VoiceKeyboard/UI/Settings/ProviderTab.swift
git commit -m "feat(ui): provider picker + OllamaSection wiring in ProviderTab"
```

---

### Task 8: Manual smoke test

**Files:** none

This task verifies the end-to-end flow that unit tests can't cover.

- [ ] **Step 1: Build and launch**

```bash
make -C mac run
```

- [ ] **Step 2: Anthropic regression check**

1. Open Settings → Provider tab.
2. Confirm provider is "Anthropic — cloud".
3. Confirm the Anthropic model picker shows three options.
4. Confirm the existing API key still loads from Keychain.
5. Click "Test Key" — confirm it still hits api.anthropic.com.

- [ ] **Step 3: Switch to Ollama**

1. Make sure Ollama is running locally (`ollama serve` or the .app).
2. In the Provider picker, select "Ollama — local".
3. Confirm the Anthropic block disappears; the Ollama block appears.
4. Confirm a `ProgressView` flashes briefly, then the model picker populates from your installed models (`ollama list` should match).
5. Pick a model.

- [ ] **Step 4: Trigger error states**

1. **Empty state**: temporarily rename your Ollama models dir or stop & restart the daemon with `ollama rm <every-model>` (don't actually do this — just open Advanced, set base URL to a port that has no Ollama, e.g. `http://localhost:11999`, observe the failed state with Retry).
2. **Reachable but empty list**: harder to set up; skip if you can't, the unit test covers it.
3. **Restore**: clear the base URL field; default is restored; model picker re-populates.

- [ ] **Step 5: Verify the actual cleanup runs**

1. Make sure ANTHROPIC_API_KEY is empty for the .app (or use a real key — doesn't matter for this step).
2. Trigger a dictation cycle (record + transcribe).
3. Watch the Console.app for `[vkb] LLM provider=ollama model=<your model>` and `[vkb] ollama.Clean: ...` lines confirming the right provider is being used.

- [ ] **Step 6: Commit a smoke-test note**

If anything was non-obvious, append a short note to the spec or a README. Otherwise, no commit needed for this task.

---

## Self-review

Spec → plan coverage:

| Spec section | Task |
|---|---|
| §2 Data-model changes — UserSettings.llmBaseURL | Task 1 |
| §2 Data-model changes — EngineConfig.llmBaseURL | Task 2 |
| §3 Ollama model fetching — OllamaClient | Task 3 |
| §1 UI layout — provider picker + sections | Tasks 5, 6, 7 |
| §1 UI layout — Anthropic block (refactored, behavior preserved) | Task 5 |
| §1 UI layout — Ollama block + Advanced base URL | Task 6 |
| §3 Ollama loading state machine | Task 6 |
| §4 Edge cases — empty list, offline, no-longer-installed | Task 6 |
| §4 Edge cases — switching providers + auto-save | Task 7 |
| §5 Testing — unit (OllamaClient, SettingsStore, EngineConfig) | Tasks 1, 2, 3 |
| §5 Testing — manual end-to-end | Task 8 |
| Persistence flow + EngineCoordinator API-key gating | Task 4 |
| Backward-compat decode for old UserDefaults blobs | Task 1 |

No gaps. No placeholders.

Type consistency check: `OllamaClient.Error` cases referenced in Task 6 (`.unreachable`, `.http(status:body:)`, `.decode`) match Task 3's definition. `LoadState` cases (`.idle`, `.loading`, `.loaded(models:)`, `.empty`, `.failed(message:)`) used consistently in Task 6's `body` switch. `AnthropicSection` initializer signature `(settings:secrets:)` consistent across Tasks 5 and 7. `OllamaSection` initializer `(settings:)` consistent.

Plan ready.
