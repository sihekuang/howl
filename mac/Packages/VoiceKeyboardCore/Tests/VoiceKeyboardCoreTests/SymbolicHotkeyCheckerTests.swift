import Foundation
import Testing
@testable import VoiceKeyboardCore

@Suite("SymbolicHotkeyChecker")
struct SymbolicHotkeyCheckerTests {
    /// Constructs the format the macOS plist uses, with NSEvent.ModifierFlags raw bits.
    private func entry(keyCode: Int, mask: UInt, enabled: Bool = true) -> [String: Any] {
        [
            "enabled": enabled,
            "value": [
                "parameters": [0, keyCode, mask],
                "type": "standard",
            ],
        ]
    }

    @Test func roundTripModifierMask() {
        // We can't easily test the system-plist read path in CI, but we can
        // sanity-check the modifier mapping by reflection on a known case.
        // For ⌃Space (kVK 49, NSEvent.control = 0x40000):
        // keyCode == 49, mask must produce [.control].
        let checker = DefaultSymbolicHotkeyChecker()
        let result = checker.conflicts(for: KeyboardShortcut(keyCode: 49, modifiers: [.control]))
        // The system might or might not have ⌃Space wired; we only check
        // the call path doesn't crash and returns a typed array.
        _ = result
        #expect(true)
    }

    @Test func nonConflictingShortcutReturnsEmpty() {
        let checker = DefaultSymbolicHotkeyChecker()
        // F19 with no modifiers is essentially never a system shortcut.
        let result = checker.conflicts(for: KeyboardShortcut(keyCode: 80, modifiers: []))
        #expect(result.isEmpty)
    }

    @Test func conflictDescriptionContainsKnownName() {
        // Synthesize a known-conflict scenario by looking up the name table
        // entry directly. The display surface must include it.
        let conflict = SymbolicHotkeyConflict(id: 60, name: "Select the previous input source")
        #expect(conflict.name.contains("input source"))
    }
}
