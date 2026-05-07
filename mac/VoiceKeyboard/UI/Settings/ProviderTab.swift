import SwiftUI
import VoiceKeyboardCore

struct ProviderTab: View {
    @Binding var settings: UserSettings
    let onSave: (UserSettings) -> Void
    let secrets: any SecretStore

    var body: some View {
        SettingsPane {
            Picker("Provider", selection: Binding(
                get: { settings.llmProvider },
                set: { newProvider in
                    // Mutate provider + model atomically so the body-level
                    // .onChange(of: settings) fires once with consistent state
                    // (provider, model) instead of twice — once with the stale
                    // model, once after correction.
                    var next = settings
                    next.llmProvider = newProvider
                    if !LLMProviderCatalog.modelBelongs(next.llmModel, to: newProvider) {
                        next.llmModel = LLMProviderCatalog.defaultModel(for: newProvider)
                    }
                    settings = next
                }
            )) {
                ForEach(LLMProviderCatalog.providers, id: \.id) { p in
                    Text(p.label).tag(p.id)
                }
            }

            Divider()

            activeSection
        }
        .onChange(of: settings) { _, new in onSave(new) }
    }

    @ViewBuilder
    private var activeSection: some View {
        switch settings.llmProvider {
        case "anthropic":
            AnthropicSection(settings: $settings, secrets: secrets)
        case "openai":
            OpenAISection(settings: $settings, secrets: secrets)
        case "ollama":
            OllamaSection(settings: $settings)
        case "lmstudio":
            LMStudioSection(settings: $settings)
        default:
            Text("Unknown provider \(settings.llmProvider)")
                .foregroundStyle(.red)
        }
    }
}
