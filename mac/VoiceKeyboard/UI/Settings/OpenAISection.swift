import SwiftUI
import VoiceKeyboardCore

/// OpenAI-specific settings. Shown when settings.llmProvider == "openai".
struct OpenAISection: View {
    @Binding var settings: UserSettings
    let secrets: any SecretStore

    @State private var apiKeyDraft: String = ""
    @State private var apiKeyStatus: String = ""
    @State private var testStatus: TestStatus = .idle

    enum TestStatus: Equatable {
        case idle
        case testing
        case ok(String)        // model count or status
        case bad(String)       // human-readable failure
    }

    // OpenAI model IDs surfaced in the picker. Keep the default first
    // (small, cheap, fast). Add new ones at the top when they ship.
    private let llmModels: [(id: String, label: String)] = [
        ("gpt-4o-mini",  "GPT-4o mini — balanced (default)"),
        ("gpt-4o",       "GPT-4o — most capable"),
        ("gpt-4.1-mini", "GPT-4.1 mini"),
        ("gpt-4.1",      "GPT-4.1"),
    ]

    // Both legacy ("sk-...") and project-scoped ("sk-proj-...") OpenAI
    // keys start with "sk-", so a single prefix check covers both.
    private var keyLooksValid: Bool { apiKeyDraft.hasPrefix("sk-") }

    var body: some View {
        Group {
            Picker("Model", selection: $settings.llmModel) {
                ForEach(llmModels, id: \.id) { m in
                    Text(m.label).tag(m.id)
                }
            }
            SecureField("API Key", text: $apiKeyDraft, prompt: Text("sk-..."))
            HStack {
                Button("Save") {
                    do {
                        try secrets.setAPIKey(apiKeyDraft, forProvider: "openai")
                        apiKeyStatus = "Saved"
                    } catch {
                        apiKeyStatus = "Failed: \(error)"
                    }
                }
                .disabled(!keyLooksValid)

                Button(testStatus == .testing ? "Testing…" : "Test Key") {
                    Task { await runTest() }
                }
                .disabled(!keyLooksValid || testStatus == .testing)
            }
            Text(apiKeyStatus).foregroundStyle(.secondary)
            testResultRow
            Link("Get one from platform.openai.com",
                 destination: URL(string: "https://platform.openai.com/api-keys")!)
        }
        .task {
            apiKeyDraft = (try? secrets.getAPIKey(forProvider: "openai")) ?? ""
        }
    }

    @ViewBuilder
    private var testResultRow: some View {
        switch testStatus {
        case .idle:
            EmptyView()
        case .testing:
            Label("Reaching api.openai.com…", systemImage: "ellipsis.circle")
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
        guard let url = URL(string: "https://api.openai.com/v1/models") else {
            testStatus = .bad("invalid URL")
            return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
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
