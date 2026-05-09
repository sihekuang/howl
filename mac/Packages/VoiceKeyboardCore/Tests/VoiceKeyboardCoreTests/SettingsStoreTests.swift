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

    @Test func tseEnabledRoundTrip() throws {
        let store = InMemorySettingsStore()
        var s = try store.get()
        #expect(s.tseEnabled == false, "default tseEnabled should be false")

        s.tseEnabled = true
        try store.set(s)
        let got = try store.get()
        #expect(got.tseEnabled == true)
    }

    @Test func testUserSettings_LLMBaseURL_RoundTrip() throws {
        var s = UserSettings()
        s.llmBaseURL = "http://10.0.0.5:11434"
        let data = try JSONEncoder().encode(s)
        let decoded = try JSONDecoder().decode(UserSettings.self, from: data)
        #expect(decoded.llmBaseURL == "http://10.0.0.5:11434")
    }

    @Test func testUserSettings_LLMBaseURL_DefaultsEmptyOnLegacyBlob() throws {
        // Simulates a UserDefaults blob written before this PR (no llmBaseURL key).
        let legacyJSON = """
        {
          "whisperModelSize": "small",
          "language": "en",
          "disableNoiseSuppression": false,
          "llmProvider": "anthropic",
          "llmModel": "claude-sonnet-4-6",
          "customDict": [],
          "tseEnabled": false
        }
        """
        let data = legacyJSON.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(UserSettings.self, from: data)
        #expect(decoded.llmBaseURL == "")
    }

}
