// mac/Packages/VoiceKeyboardCore/Tests/VoiceKeyboardCoreTests/PresetsClientTests.swift
import Foundation
import Testing
@testable import VoiceKeyboardCore

@Suite("PresetsClient", .serialized)
struct PresetsClientTests {
    @Test func list_decodesEmptyArray() async throws {
        let engine = SpyCoreEngine()
        engine.stubPresetsListJSON = "[]"
        let c = LibVKBPresetsClient(engine: engine)
        let got = try await c.list()
        #expect(got.isEmpty)
    }

    @Test func list_decodesPresets() async throws {
        let json = """
        [
          {"name":"default","description":"x","frame_stages":[],"chunk_stages":[],
           "transcribe":{"model_size":"small"},"llm":{"provider":"anthropic"}}
        ]
        """
        let engine = SpyCoreEngine()
        engine.stubPresetsListJSON = json
        let c = LibVKBPresetsClient(engine: engine)
        let got = try await c.list()
        #expect(got.count == 1)
        #expect(got[0].name == "default")
    }

    @Test func get_returnsPreset() async throws {
        let engine = SpyCoreEngine()
        engine.stubPresetGetJSON["default"] = """
        {"name":"default","description":"x","frame_stages":[],"chunk_stages":[],
         "transcribe":{"model_size":"small"},"llm":{"provider":"anthropic"}}
        """
        let c = LibVKBPresetsClient(engine: engine)
        let got = try await c.get("default")
        #expect(got.name == "default")
    }

    @Test func save_roundTrips() async throws {
        let engine = SpyCoreEngine()
        engine.stubPresetSaveRC = 0
        let c = LibVKBPresetsClient(engine: engine)
        let p = Preset(name: "x", description: "y",
                       frameStages: [], chunkStages: [],
                       transcribe: .init(modelSize: "small"),
                       llm: .init(provider: "anthropic"))
        try await c.save(p)
    }

    @Test func save_invalidNameThrows() async {
        let engine = SpyCoreEngine()
        engine.stubPresetSaveRC = 5
        let c = LibVKBPresetsClient(engine: engine)
        let p = Preset(name: "../bad", description: "",
                       frameStages: [], chunkStages: [],
                       transcribe: .init(modelSize: "small"),
                       llm: .init(provider: "anthropic"))
        await #expect(throws: PresetsClientError.self) { try await c.save(p) }
    }

    @Test func delete_succeeds() async throws {
        let engine = SpyCoreEngine()
        engine.stubPresetDeleteRC = 0
        let c = LibVKBPresetsClient(engine: engine)
        try await c.delete("custom")
    }

    @Test func delete_reservedNameThrows() async {
        let engine = SpyCoreEngine()
        engine.stubPresetDeleteRC = 5
        let c = LibVKBPresetsClient(engine: engine)
        await #expect(throws: PresetsClientError.self) { try await c.delete("default") }
    }
}
