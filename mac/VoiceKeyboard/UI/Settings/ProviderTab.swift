import SwiftUI
import VoiceKeyboardCore

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

            activeSection
        }
        .formStyle(.grouped)
        .padding()
        .onChange(of: settings) { _, new in onSave(new) }
    }

    @ViewBuilder
    private var activeSection: some View {
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
}
