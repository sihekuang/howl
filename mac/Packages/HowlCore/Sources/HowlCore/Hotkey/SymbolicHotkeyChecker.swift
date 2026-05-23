import Foundation

public struct SymbolicHotkeyConflict: Equatable, Sendable {
    public let id: Int
    public let name: String

    public init(id: Int, name: String) {
        self.id = id
        self.name = name
    }
}

public protocol SymbolicHotkeyChecker: Sendable {
    /// Return any enabled macOS symbolic hotkeys that match the given shortcut.
    /// Empty array means no conflict found.
    func conflicts(for shortcut: KeyboardShortcut) -> [SymbolicHotkeyConflict]
}

/// Reads ~/Library/Preferences/com.apple.symbolichotkeys.plist and
/// compares each enabled entry against the user's shortcut. Only checks
/// IDs we know about; unknown IDs are reported as "another macOS shortcut".
public final class DefaultSymbolicHotkeyChecker: SymbolicHotkeyChecker, @unchecked Sendable {
    private let domain = "com.apple.symbolichotkeys"
    private let knownIDs: [Int: String]

    public init() {
        // Subset that conflict often. IDs sourced from public lore + macOS plists.
        self.knownIDs = [
            7:   "Move focus to the menu bar",
            8:   "Move focus to the Dock",
            9:   "Move focus to active or next window",
            10:  "Move focus to the window toolbar",
            11:  "Move focus to the floating window",
            12:  "Move focus to next window in active app",
            13:  "Move focus to status menus",
            27:  "Move focus to the next display",
            32:  "Mission Control: All windows",
            33:  "Mission Control: Application windows",
            36:  "Mission Control: Show Desktop",
            60:  "Select the previous input source",
            61:  "Select next source in Input menu",
            62:  "Spotlight: Show Finder search window",
            64:  "Spotlight: Show Spotlight search",
            65:  "Spotlight: Show Finder search window",
            79:  "Move focus to next Mission Control space",
            80:  "Move focus to previous Mission Control space",
            175: "Show Notification Center",
            190: "Show Launchpad",
            222: "Quick Note",
        ]
    }

    public func conflicts(for shortcut: KeyboardShortcut) -> [SymbolicHotkeyConflict] {
        guard let plist = readSymbolicHotkeys() else { return [] }
        var found: [SymbolicHotkeyConflict] = []
        for (idStr, value) in plist {
            guard let id = Int(idStr),
                  let entry = value as? [String: Any],
                  let enabled = entry["enabled"] as? Bool, enabled,
                  let valueDict = entry["value"] as? [String: Any],
                  let parameters = valueDict["parameters"] as? [Any],
                  parameters.count >= 3,
                  let kc = parameters[1] as? NSNumber,
                  let mask = parameters[2] as? NSNumber
            else { continue }

            let keyCode = UInt16(truncatingIfNeeded: kc.intValue)
            // The plist's mask uses NSEvent.ModifierFlags raw bits.
            let nsMask = mask.uintValue
            let modifiers = mapNSMaskToModifiers(nsMask)

            if keyCode == shortcut.keyCode && modifiers == shortcut.modifiers {
                let name = knownIDs[id] ?? "Another macOS shortcut (id \(id))"
                found.append(SymbolicHotkeyConflict(id: id, name: name))
            }
        }
        return found
    }

    private func readSymbolicHotkeys() -> [String: Any]? {
        // Prefer CFPreferencesCopyValue so byHost overrides are respected.
        let raw = CFPreferencesCopyValue(
            "AppleSymbolicHotKeys" as CFString,
            domain as CFString,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        )
        return raw as? [String: Any]
    }

    /// Map the raw NSEvent.ModifierFlags bitmask the plist stores into our
    /// ModifierFlags. NSEvent flags are: shift=0x20000, control=0x40000,
    /// option=0x80000, command=0x100000.
    private func mapNSMaskToModifiers(_ mask: UInt) -> ModifierFlags {
        var m: ModifierFlags = []
        if mask & 0x20000 != 0 { m.insert(.shift) }
        if mask & 0x40000 != 0 { m.insert(.control) }
        if mask & 0x80000 != 0 { m.insert(.option) }
        if mask & 0x100000 != 0 { m.insert(.command) }
        return m
    }
}
