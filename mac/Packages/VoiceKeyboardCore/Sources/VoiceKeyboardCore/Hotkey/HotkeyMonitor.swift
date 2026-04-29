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
        switch keyCode {
        case Self.kVK_Space: return "Space"
        case Self.kVK_Escape: return "Esc"
        default: return "Key\(keyCode)"
        }
    }
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
    /// Throws if the OS rejects the event tap install.
    func start(_ shortcut: KeyboardShortcut, onPress: @escaping @Sendable () -> Void, onRelease: @escaping @Sendable () -> Void) throws

    /// Cancel the current shortcut binding (idempotent).
    func stop()
}
