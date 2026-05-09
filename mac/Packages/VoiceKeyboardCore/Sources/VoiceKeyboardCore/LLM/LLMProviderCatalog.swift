// mac/Packages/VoiceKeyboardCore/Sources/VoiceKeyboardCore/LLM/LLMProviderCatalog.swift
import Foundation

/// Single source of truth for the LLM provider list, the default
/// model per provider, the model→provider belonging predicate, and a
/// curated fallback model list for each cloud provider.
///
/// Consumed by both Settings → LLM Provider (full UI with API-key auth +
/// dynamic API-side model fetch) and Settings → Pipeline → Editor (per-
/// preset model override, no auth, picks from the curated list).
///
/// For local providers (ollama, lmstudio) the curated list is empty —
/// model lists are device-local and fetched at runtime by their
/// respective Section views; the per-preset editor binds to a free-
/// form text model name in those cases.
public enum LLMProviderCatalog {

    public static let providers: [(id: String, label: String)] = [
        ("anthropic", "Anthropic — cloud"),
        ("openai",    "OpenAI — cloud"),
        ("ollama",    "Ollama — local"),
        ("lmstudio",  "LM Studio — local"),
    ]

    /// Default model id for the named provider. Empty for local
    /// providers (the per-section auto-detect picks one).
    public static func defaultModel(for provider: String) -> String {
        switch provider {
        case "anthropic": return "claude-sonnet-4-6"
        case "openai":    return "gpt-4o-mini"
        case "ollama":    return ""
        case "lmstudio":  return ""
        default:          return ""
        }
    }

    /// Whether `model` is plausibly served by `provider`. Used to decide
    /// whether a provider switch should reset the model field. Local
    /// providers always return false: their model identifiers are
    /// device-local and not interchangeable with cloud providers.
    public static func modelBelongs(_ model: String, to provider: String) -> Bool {
        switch provider {
        case "anthropic":          return model.hasPrefix("claude-")
        case "openai":             return model.hasPrefix("gpt-") || model.hasPrefix("o1")
        case "ollama", "lmstudio": return false
        default:                   return false
        }
    }

    /// Static curated list of common models for the named provider.
    /// Used as the dropdown options in the Pipeline editor's per-preset
    /// llm body, where there is no API key to drive a dynamic fetch.
    /// Empty for local providers.
    public static func curatedModels(for provider: String) -> [String] {
        switch provider {
        case "anthropic":
            return [
                "claude-opus-4-7",
                "claude-sonnet-4-6",
                "claude-haiku-4-5",
            ]
        case "openai":
            return [
                "gpt-4o",
                "gpt-4o-mini",
                "gpt-4-turbo",
                "o1-preview",
                "o1-mini",
            ]
        case "ollama", "lmstudio":
            return []
        default:
            return []
        }
    }
}
