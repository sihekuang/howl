import Foundation
import Testing
@testable import VoiceKeyboardCore

@Suite("LLMProviderCatalog")
struct LLMProviderCatalogTests {

    @Test func providers_listed_in_canonical_order() {
        let ids = LLMProviderCatalog.providers.map { $0.id }
        #expect(ids == ["anthropic", "openai", "ollama", "lmstudio"])
    }

    @Test func defaultModel_returns_a_curated_model_for_cloud_providers() {
        for id in ["anthropic", "openai"] {
            let dflt = LLMProviderCatalog.defaultModel(for: id)
            #expect(!dflt.isEmpty, "expected non-empty default for \(id)")
            #expect(LLMProviderCatalog.curatedModels(for: id).contains(dflt),
                    "default \(dflt) for \(id) should be in curated list")
        }
    }

    @Test func defaultModel_is_empty_for_local_providers() {
        #expect(LLMProviderCatalog.defaultModel(for: "ollama") == "")
        #expect(LLMProviderCatalog.defaultModel(for: "lmstudio") == "")
    }

    @Test func modelBelongs_matches_provider_prefix_rules() {
        #expect(LLMProviderCatalog.modelBelongs("claude-sonnet-4-6", to: "anthropic"))
        #expect(LLMProviderCatalog.modelBelongs("gpt-4o-mini", to: "openai"))
        #expect(LLMProviderCatalog.modelBelongs("o1-preview", to: "openai"))
        #expect(!LLMProviderCatalog.modelBelongs("claude-sonnet-4-6", to: "openai"))
        #expect(!LLMProviderCatalog.modelBelongs("anything", to: "ollama"))
        #expect(!LLMProviderCatalog.modelBelongs("anything", to: "lmstudio"))
    }

    @Test func curatedModels_nonempty_for_cloud_providers() {
        #expect(!LLMProviderCatalog.curatedModels(for: "anthropic").isEmpty)
        #expect(!LLMProviderCatalog.curatedModels(for: "openai").isEmpty)
    }

    @Test func curatedModels_empty_for_local_providers() {
        #expect(LLMProviderCatalog.curatedModels(for: "ollama").isEmpty)
        #expect(LLMProviderCatalog.curatedModels(for: "lmstudio").isEmpty)
    }
}
