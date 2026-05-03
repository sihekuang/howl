import Foundation
import Testing
@testable import VoiceKeyboardCore

@Suite("Preset.timeoutSec coding")
struct PresetTimeoutCodingTests {
    @Test func decode_picksUpTimeout() throws {
        let json = """
        {"name":"x","description":"","frame_stages":[],"chunk_stages":[],
         "transcribe":{"model_size":"small"},"llm":{"provider":"anthropic"},
         "timeout_sec":7}
        """
        let p = try JSONDecoder().decode(Preset.self, from: Data(json.utf8))
        #expect(p.timeoutSec == 7)
    }

    @Test func decode_missingTimeoutIsNil() throws {
        let json = """
        {"name":"x","description":"","frame_stages":[],"chunk_stages":[],
         "transcribe":{"model_size":"small"},"llm":{"provider":"anthropic"}}
        """
        let p = try JSONDecoder().decode(Preset.self, from: Data(json.utf8))
        #expect(p.timeoutSec == nil)
    }

    @Test func encode_emitsSnakeCaseKey() throws {
        let p = Preset(name: "x", description: "",
                       frameStages: [], chunkStages: [],
                       transcribe: .init(modelSize: "small"),
                       llm: .init(provider: "anthropic"),
                       timeoutSec: 12)
        let buf = try JSONEncoder().encode(p)
        let str = String(decoding: buf, as: UTF8.self)
        #expect(str.contains("\"timeout_sec\":12"))
    }
}
