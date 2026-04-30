import Foundation

public struct KeyboardShortcut: Codable, Equatable, Sendable {
    public var keyCode: UInt16
    public var modifiers: ModifierFlags

    public init(keyCode: UInt16, modifiers: ModifierFlags) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// Carbon virtual key codes we care about.
    public static let kVK_Space: UInt16 = 49
    public static let kVK_Escape: UInt16 = 53

    public static let defaultPTT = KeyboardShortcut(
        keyCode: kVK_Space,
        modifiers: [.control]
    )

    public var displayString: String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option) { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        s += keyName
        return s
    }

    private var keyName: String {
        if let n = Self.keyNames[keyCode] { return n }
        return "Key\(keyCode)"
    }

    /// Carbon virtual keycode → human-readable label. Covers common keys
    /// the user is likely to bind. Anything else falls back to `KeyN`.
    private static let keyNames: [UInt16: String] = [
        49: "Space", 53: "Esc", 36: "Return", 48: "Tab", 51: "Delete",
        // Letters
        0: "A",  11: "B", 8: "C",  2: "D",  14: "E", 3: "F",  5: "G",
        4: "H",  34: "I", 38: "J", 40: "K", 37: "L", 46: "M", 45: "N",
        31: "O", 35: "P", 12: "Q", 15: "R", 1: "S",  17: "T", 32: "U",
        9: "V",  13: "W", 7: "X",  16: "Y", 6: "Z",
        // Digits
        29: "0", 18: "1", 19: "2", 20: "3", 21: "4",
        23: "5", 22: "6", 26: "7", 28: "8", 25: "9",
        // Function keys
        122: "F1",  120: "F2",  99: "F3",   118: "F4",
        96:  "F5",  97:  "F6",  98: "F7",   100: "F8",
        101: "F9",  109: "F10", 103: "F11", 111: "F12",
        // Arrows
        123: "←", 124: "→", 125: "↓", 126: "↑",
        // Punctuation
        27: "-", 24: "=", 33: "[", 30: "]", 41: ";", 39: "'",
        43: ",", 47: ".", 44: "/", 42: "\\", 50: "`",
    ]
}

/// Modifier set independent of NSEvent / CGEvent so it's Codable.
public struct ModifierFlags: OptionSet, Codable, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let shift   = ModifierFlags(rawValue: 1 << 0)
    public static let control = ModifierFlags(rawValue: 1 << 1)
    public static let option  = ModifierFlags(rawValue: 1 << 2)
    public static let command = ModifierFlags(rawValue: 1 << 3)
}

public protocol HotkeyMonitor: Sendable {
    /// Begin monitoring for the given shortcut. Replaces any prior shortcut.
    /// Throws if the OS rejects the registration (binding already in use,
    /// event handler install failed, etc.).
    func start(_ shortcut: KeyboardShortcut, onPress: @escaping @Sendable () -> Void, onRelease: @escaping @Sendable () -> Void) throws

    /// Cancel the current shortcut binding (idempotent).
    func stop()
}

public enum HotkeyError: Error {
    case tapInstallFailed
}
