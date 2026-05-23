import Foundation
import Testing
@testable import HowlCore

@Suite("Preset.LLMSpec.model coding")
struct PresetLLMModelCodingTests {

    @Test func decodes_model_when_present() throws {
        let json = #"""
        {"provider": "anthropic", "model": "claude-haiku-4-5"}
        """#
        let spec = try JSONDecoder().decode(Preset.LLMSpec.self, from: Data(json.utf8))
        #expect(spec.provider == "anthropic")
        #expect(spec.model == "claude-haiku-4-5")
    }

    @Test func decodes_nil_model_when_absent() throws {
        let json = #"""
        {"provider": "anthropic"}
        """#
        let spec = try JSONDecoder().decode(Preset.LLMSpec.self, from: Data(json.utf8))
        #expect(spec.provider == "anthropic")
        #expect(spec.model == nil)
    }

    @Test func encodes_without_model_key_when_nil() throws {
        let spec = Preset.LLMSpec(provider: "ollama", model: nil)
        let data = try JSONEncoder().encode(spec)
        let str = String(decoding: data, as: UTF8.self)
        #expect(!str.contains("\"model\""))
        #expect(str.contains("\"provider\":\"ollama\""))
    }

    @Test func encodes_model_when_set() throws {
        let spec = Preset.LLMSpec(provider: "anthropic", model: "claude-sonnet-4-6")
        let data = try JSONEncoder().encode(spec)
        let str = String(decoding: data, as: UTF8.self)
        #expect(str.contains("\"model\":\"claude-sonnet-4-6\""))
    }
}
