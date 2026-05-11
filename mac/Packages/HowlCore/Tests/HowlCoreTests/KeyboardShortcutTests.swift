import Foundation
import Testing
@testable import HowlCore

@Suite("KeyboardShortcut")
struct KeyboardShortcutTests {
    @Test func defaultPTTMatchesCtrlSpace() {
        let s = KeyboardShortcut.defaultPTT
        #expect(s.keyCode == KeyboardShortcut.kVK_Space)
        #expect(s.modifiers.contains(.control))
        #expect(!s.modifiers.contains(.option))
        #expect(!s.modifiers.contains(.command))
    }

    @Test func roundTripCodable() throws {
        let s = KeyboardShortcut(keyCode: 49, modifiers: [.option, .command])
        let data = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(KeyboardShortcut.self, from: data)
        #expect(back == s)
    }

    @Test func displayString() {
        let s = KeyboardShortcut.defaultPTT
        let str = s.displayString
        #expect(str.contains("⌃"))
        #expect(str.contains("Space"))
    }
}
