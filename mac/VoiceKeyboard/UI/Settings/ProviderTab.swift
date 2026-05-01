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
            Picker("Provider", selection: Binding(
                get: { settings.llmProvider },
                set: { newProvider in
                    // Mutate provider + model atomically so the body-level
                    // .onChange(of: settings) fires once with consistent state
                    // (provider, model) instead of twice — once with the stale
                    // model, once after correction.
                    var next = settings
                    next.llmProvider = newProvider
                    if newProvider == "ollama" && next.llmModel.hasPrefix("claude-") {
                        next.llmModel = ""   // hand off to OllamaSection.refresh() to auto-detect
                    }
                    if newProvider == "anthropic" && !next.llmModel.hasPrefix("claude-") {
                        next.llmModel = "claude-sonnet-4-6"
                    }
                    settings = next
                }
            )) {
                ForEach(Self.providers, id: \.id) { p in
                    Text(p.label).tag(p.id)
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
