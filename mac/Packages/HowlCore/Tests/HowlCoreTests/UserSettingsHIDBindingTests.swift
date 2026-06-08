import Foundation
import Testing
@testable import HowlCore

@Suite("UserSettings.hidBinding")
struct UserSettingsHIDBindingTests {
    @Test func defaultsToNil() {
        #expect(UserSettings().hidBinding == nil)
    }

    @Test func roundTripsWithBinding() throws {
        var s = UserSettings()
        s.hidBinding = HIDBinding(vendorID: 0x046D, productID: 0xC52B, usagePage: 0x09, usage: 0x01)
        let data = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(UserSettings.self, from: data)
        #expect(back.hidBinding == s.hidBinding)
    }

    /// Settings persisted before `hidBinding` existed (legacy installs) must
    /// keep loading, with the binding defaulting to nil.
    @Test func legacyJSONWithoutKeyDecodesToNil() throws {
        let legacy = Data("{}".utf8)
        let s = try JSONDecoder().decode(UserSettings.self, from: legacy)
        #expect(s.hidBinding == nil)
        #expect(s.hotkey == .defaultPTT)   // sanity: existing fallbacks intact
    }
}
