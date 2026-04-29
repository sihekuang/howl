import SwiftUI
import VoiceKeyboardCore

struct ProviderTab: View {
    let secrets: any SecretStore
    @State private var apiKeyDraft: String = ""
    @State private var apiKeyStatus: String = ""
    @State private var testStatus: TestStatus = .idle

    enum TestStatus: Equatable {
        case idle
        case testing
        case ok(String)        // model count or version
        case bad(String)       // human-readable failure
    }

    var body: some View {
        Form {
            LabeledContent("Provider") { Text("Anthropic") }
            LabeledContent("Model") { Text("claude-sonnet-4-6").font(.system(.body, design: .monospaced)) }
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
        .formStyle(.grouped)
        .padding()
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
