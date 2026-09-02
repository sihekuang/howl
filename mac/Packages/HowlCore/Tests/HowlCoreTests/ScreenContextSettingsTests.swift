import Foundation
import Testing
@testable import HowlCore

@Suite("ScreenContext settings")
struct ScreenContextSettingsTests {

    @Test func screen_context_defaults_to_enabled() {
        #expect(UserSettings().screenContextEnabled == true)
    }

    @Test func denylist_defaults_to_empty() {
        #expect(UserSettings().screenContextDenylist.isEmpty)
    }

    @Test func survives_a_json_round_trip() throws {
        var s = UserSettings()
        s.screenContextEnabled = false
        s.screenContextDenylist = ["com.example.diary"]

        let data = try JSONEncoder().encode(s)
        let out = try JSONDecoder().decode(UserSettings.self, from: data)

        #expect(out.screenContextEnabled == false)
        #expect(out.screenContextDenylist == ["com.example.diary"])
    }

    @Test func legacy_settings_without_the_keys_decode_with_defaults() throws {
        // Existing installs have no screenContext keys; decoding must
        // not fail and must land on the shipped default. Build the
        // legacy payload by encoding a real UserSettings and deleting
        // the new keys, so this test can't rot against unrelated
        // changes to KeyboardShortcut/HIDBinding encoding.
        var s = UserSettings()
        s.screenContextEnabled = false
        s.screenContextDenylist = ["com.example.diary"]
        let data = try JSONEncoder().encode(s)
        var object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        object.removeValue(forKey: "screenContextEnabled")
        object.removeValue(forKey: "screenContextDenylist")
        let legacy = try JSONSerialization.data(withJSONObject: object)

        let out = try JSONDecoder().decode(UserSettings.self, from: legacy)
        #expect(out.screenContextEnabled == true)
        #expect(out.screenContextDenylist.isEmpty)
    }
}
