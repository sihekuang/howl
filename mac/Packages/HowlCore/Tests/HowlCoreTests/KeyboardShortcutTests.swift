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

    @Test func controlAloneIsModifierOnly() {
        let s = KeyboardShortcut(keyCode: KeyboardShortcut.kVK_None, modifiers: [.control])
        #expect(s.isModifierOnly)
        #expect(s.usesEventTap)
        #expect(s.requiredModifiers == [.control])
        #expect(!s.isFnBased)
        #expect(!s.isFnLetterCombo)
    }

    @Test func multiModifierOnlyRequiresAll() {
        let s = KeyboardShortcut(keyCode: KeyboardShortcut.kVK_None, modifiers: [.control, .option])
        #expect(s.isModifierOnly)
        #expect(s.requiredModifiers == [.control, .option])
    }

    @Test func fnAloneStaysModifierOnly() {
        let s = KeyboardShortcut(keyCode: KeyboardShortcut.kVK_Function, modifiers: [])
        #expect(s.isModifierOnly)
        #expect(s.usesEventTap)
        #expect(s.requiredModifiers.contains(.fn))
    }

    @Test func fnModifierRequiresFnAndCompanion() {
        let s = KeyboardShortcut(keyCode: KeyboardShortcut.kVK_Function, modifiers: [.shift])
        #expect(s.isModifierOnly)
        #expect(s.requiredModifiers.contains(.fn))
        #expect(s.requiredModifiers.contains(.shift))
    }

    @Test func plainComboIsNotModifierOnly() {
        let s = KeyboardShortcut(keyCode: KeyboardShortcut.kVK_Space, modifiers: [.control])
        #expect(!s.isModifierOnly)
        #expect(!s.usesEventTap)
        #expect(s.requiredModifiers == [.control])
    }

    @Test func fnLetterUsesTapButIsNotModifierOnly() {
        let s = KeyboardShortcut(keyCode: 32 /* U */, modifiers: [.fn])
        #expect(!s.isModifierOnly)
        #expect(s.isFnLetterCombo)
        #expect(s.usesEventTap)
    }

    @Test func displayStringModifierOnlyShowsGlyphsOnly() {
        let one = KeyboardShortcut(keyCode: KeyboardShortcut.kVK_None, modifiers: [.control])
        #expect(one.displayString == "⌃")
        let two = KeyboardShortcut(keyCode: KeyboardShortcut.kVK_None, modifiers: [.control, .option])
        #expect(two.displayString == "⌃⌥")
        #expect(!one.displayString.contains("Key"))
    }

    @Test func modifierOnlyRoundTripsCodable() throws {
        let s = KeyboardShortcut(keyCode: KeyboardShortcut.kVK_None, modifiers: [.control, .command])
        let data = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(KeyboardShortcut.self, from: data)
        #expect(back == s)
        #expect(back.isModifierOnly)
    }
}
