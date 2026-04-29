import Foundation
import Testing
@testable import VoiceKeyboardCore

@Suite("SettingsStore")
struct SettingsStoreTests {
    @Test func writeAndReadBack() throws {
        let store = InMemorySettingsStore()
        try store.set(UserSettings(
            whisperModelSize: "small",
            language: "en",
            disableNoiseSuppression: false,
            llmProvider: "anthropic",
            llmModel: "claude-sonnet-4-6",
            customDict: ["MCP", "WebRTC"],
            hotkey: KeyboardShortcut.defaultPTT
        ))
        let got = try store.get()
        #expect(got.whisperModelSize == "small")
        #expect(got.customDict == ["MCP", "WebRTC"])
    }

    @Test func defaultsWhenEmpty() throws {
        let store = InMemorySettingsStore()
        let got = try store.get()
        #expect(got.whisperModelSize == "small")
        #expect(got.language == "en")
        #expect(got.disableNoiseSuppression == false)
        #expect(got.llmProvider == "anthropic")
        #expect(got.llmModel == "claude-sonnet-4-6")
        #expect(got.customDict == [])
    }
}
