import Testing
import Foundation
@testable import HowlCore

@Suite struct UserSettingsSecondaryLanguageTests {
    @Test func defaultsToNone() {
        #expect(UserSettings().secondaryLanguage == "none")
    }

    @Test func roundTripsThroughCodable() throws {
        var s = UserSettings()
        s.secondaryLanguage = "zh"
        let data = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(UserSettings.self, from: data)
        #expect(back.secondaryLanguage == "zh")
    }

    @Test func decodesMissingKeyAsNone() throws {
        // Legacy stored settings (no secondary_language key) must default.
        let json = #"{"whisperModelSize":"small","language":"en"}"#.data(using: .utf8)!
        let s = try JSONDecoder().decode(UserSettings.self, from: json)
        #expect(s.secondaryLanguage == "none")
    }
}
