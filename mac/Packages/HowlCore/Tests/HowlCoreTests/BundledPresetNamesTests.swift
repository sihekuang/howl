import Foundation
import Testing
@testable import HowlCore

@Suite("Preset.bundledNames")
struct BundledPresetNamesTests {

    @Test func bundledNames_matches_known_set() {
        // Mirrors core/internal/presets/pipeline-presets.json. If a
        // bundled preset is added/removed there, update both the JSON
        // and this set together.
        #expect(Preset.bundledNames == ["default", "minimal", "aggressive", "paranoid"])
    }

    @Test func isBundled_true_for_bundled_names() {
        let p = Preset(
            name: "paranoid",
            description: "",
            frameStages: [], chunkStages: [],
            transcribe: .init(modelSize: "small"),
            llm: .init(provider: "anthropic")
        )
        #expect(p.isBundled == true)
    }

    @Test func isBundled_false_for_user_names() {
        let p = Preset(
            name: "my-custom",
            description: "",
            frameStages: [], chunkStages: [],
            transcribe: .init(modelSize: "small"),
            llm: .init(provider: "anthropic")
        )
        #expect(p.isBundled == false)
    }
}
