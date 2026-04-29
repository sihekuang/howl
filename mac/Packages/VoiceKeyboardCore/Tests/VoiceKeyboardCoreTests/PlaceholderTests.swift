import Testing
@testable import VoiceKeyboardCore

@Suite("Placeholder")
struct PlaceholderTests {
    @Test @MainActor func versionPresent() {
        #expect(VoiceKeyboardCore.version == "0.1.0")
    }
}
