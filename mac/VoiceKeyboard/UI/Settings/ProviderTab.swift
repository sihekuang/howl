import SwiftUI
import VoiceKeyboardCore

struct ProviderTab: View {
    let secrets: any SecretStore
    @State private var apiKeyDraft: String = ""
    @State private var apiKeyStatus: String = ""

    var body: some View {
        Form {
            LabeledContent("Provider") { Text("Anthropic") }
            LabeledContent("Model") { Text("claude-sonnet-4-6").font(.system(.body, design: .monospaced)) }
            SecureField("API Key", text: $apiKeyDraft, prompt: Text("sk-ant-..."))
            Button("Save") {
                do {
                    try secrets.setAPIKey(apiKeyDraft)
                    apiKeyStatus = "Saved"
                } catch {
                    apiKeyStatus = "Failed: \(error)"
                }
            }
            .disabled(!apiKeyDraft.hasPrefix("sk-ant-"))
            Text(apiKeyStatus).foregroundStyle(.secondary)
            Link("Get one from console.anthropic.com",
                 destination: URL(string: "https://console.anthropic.com/")!)
        }
        .formStyle(.grouped)
        .padding()
        .task {
            apiKeyDraft = (try? secrets.getAPIKey()) ?? ""
        }
    }
}
