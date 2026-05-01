import SwiftUI
import VoiceKeyboardCore

struct ProviderTab: View {
    @Binding var settings: UserSettings
    let onSave: (UserSettings) -> Void
    let secrets: any SecretStore

    private static let providers: [(id: String, label: String)] = [
        ("anthropic", "Anthropic — cloud"),
        ("openai",    "OpenAI — cloud"),
        ("ollama",    "Ollama — local"),
    ]

    // Default model per provider, used when the user switches and the
    // current model belongs to a different family. Kept in one place so
    // the picker switch logic below stays declarative.
    private static let defaultModels: [String: String] = [
        "anthropic": "claude-sonnet-4-6",
        "openai":    "gpt-4o-mini",
        "ollama":    "",   // empty hands off to OllamaSection auto-detect
    ]

    /// Whether the currently-selected model belongs to the given provider.
    /// Used to decide whether a provider switch should reset the model.
    private static func modelBelongs(_ model: String, to provider: String) -> Bool {
        switch provider {
        case "anthropic": return model.hasPrefix("claude-")
        case "openai":    return model.hasPrefix("gpt-") || model.hasPrefix("o1")
        case "ollama":    return !model.hasPrefix("claude-") && !model.hasPrefix("gpt-")
        default:          return false
        }
    }

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
                    if !Self.modelBelongs(next.llmModel, to: newProvider) {
                        next.llmModel = Self.defaultModels[newProvider] ?? ""
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
        case "openai":
            OpenAISection(settings: $settings, secrets: secrets)
        case "ollama":
            OllamaSection(settings: $settings)
        default:
            Text("Unknown provider \(settings.llmProvider)")
                .foregroundStyle(.red)
        }
    }
}
