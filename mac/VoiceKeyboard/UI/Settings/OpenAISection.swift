import SwiftUI
import VoiceKeyboardCore

/// OpenAI-specific settings. Shown when settings.llmProvider == "openai".
struct OpenAISection: View {
    @Binding var settings: UserSettings
    let secrets: any SecretStore

    @State private var apiKeyDraft: String = ""
    @State private var apiKeyStatus: String = ""
    @State private var loadState: LoadState = .noKey

    enum LoadState: Equatable {
        case noKey
        case loading
        case loaded(models: [OpenAIModel])
        case failed(message: String)
    }

    // Both legacy ("sk-...") and project-scoped ("sk-proj-...") OpenAI
    // keys start with "sk-", so a single prefix check covers both.
    private var keyLooksValid: Bool { apiKeyDraft.hasPrefix("sk-") }

    var body: some View {
        Group {
            modelRow
            SecureField("API Key", text: $apiKeyDraft, prompt: Text("sk-..."))
            HStack {
                Button("Save") {
                    do {
                        try secrets.setAPIKey(apiKeyDraft, forProvider: "openai")
                        apiKeyStatus = "Saved"
                        Task { await refreshModels() }
                    } catch {
                        apiKeyStatus = "Failed: \(error)"
                    }
                }
                .disabled(!keyLooksValid)
            }
            Text(apiKeyStatus).foregroundStyle(.secondary)
            Link("Get one from platform.openai.com",
                 destination: URL(string: "https://platform.openai.com/api-keys")!)
        }
        .task {
            apiKeyDraft = (try? secrets.getAPIKey(forProvider: "openai")) ?? ""
            await refreshModels()
        }
    }

    // MARK: – Model row (driven by loadState)

    @ViewBuilder
    private var modelRow: some View {
        switch loadState {
        case .noKey:
            HStack {
                Text("Model")
                Spacer()
                Text("Save an API key to load models")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        case .loading:
            HStack {
                Text("Model")
                Spacer()
                ProgressView().controlSize(.small)
            }
        case .loaded(let models):
            HStack {
                Picker("Model", selection: $settings.llmModel) {
                    if !models.contains(where: { $0.id == settings.llmModel }), !settings.llmModel.isEmpty {
                        Text("\(settings.llmModel) (not available)").tag(settings.llmModel)
                    }
                    ForEach(models) { m in
                        Text(m.id).tag(m.id)
                    }
                }
                Button {
                    Task { await refreshModels() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh model list")
            }
        case .failed(let msg):
            VStack(alignment: .leading, spacing: 6) {
                Label("Couldn't load models", systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                Text(msg)
                    .foregroundStyle(.secondary)
                    .font(.callout)
                Button("Retry") { Task { await refreshModels() } }
            }
        }
    }

    // MARK: – Behaviour

    private func refreshModels() async {
        let savedKey = (try? secrets.getAPIKey(forProvider: "openai")) ?? ""
        guard !savedKey.isEmpty else {
            loadState = .noKey
            return
        }
        loadState = .loading
        let client = OpenAIClient(apiKey: savedKey)
        do {
            let models = try await client.listModels()
            loadState = models.isEmpty
                ? .failed(message: "API returned no chat-streaming models — check your account permissions.")
                : .loaded(models: models)
        } catch let e as OpenAIClientError {
            loadState = .failed(message: humanize(e))
        } catch {
            loadState = .failed(message: error.localizedDescription)
        }
    }

    private func humanize(_ e: OpenAIClientError) -> String {
        switch e {
        case .unreachable(let url):
            return "Couldn't reach \(url.host ?? url.absoluteString)"
        case .http(let status, _):
            switch status {
            case 401: return "Invalid API key (HTTP 401)"
            case 403: return "Key not authorized for this resource (HTTP 403)"
            case 429: return "Rate-limited (HTTP 429)"
            default:  return "HTTP \(status)"
            }
        case .decode(let detail):
            return "Bad response from API: \(detail)"
        }
    }
}
