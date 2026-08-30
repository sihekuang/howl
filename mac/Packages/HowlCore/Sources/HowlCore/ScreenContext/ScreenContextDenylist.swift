import Foundation

/// Bundle IDs whose windows are never read for screen context.
///
/// Fail-closed: an app we cannot identify is skipped rather than read.
public struct ScreenContextDenylist: Sendable {
    /// Apps that are never read regardless of user settings. Password
    /// managers and the system keychain — windows whose contents are
    /// secrets by definition.
    public static let builtIn: [String] = [
        "com.1password.1password",
        "com.1password.1password7",
        "com.agilebits.onepassword7",
        "com.apple.keychainaccess",
        "com.bitwarden.desktop",
        "com.lastpass.lastpassmacdesktop",
        "com.dashlane.Dashlane",
        // Legacy Dashlane bundle ID (from its older iOS-extension-derived
        // macOS build). Kept deliberately alongside the current one above
        // so older installs stay covered — do not remove.
        "com.dashlane.dashlanephonefinal",
        "in.sinew.Enpass-Desktop",
        "com.apple.Passwords",
    ]

    private let entries: Set<String>

    public init(userAdditions: [String]) {
        var all = Set(ScreenContextDenylist.builtIn.map { $0.lowercased() })
        for id in userAdditions {
            let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !trimmed.isEmpty { all.insert(trimmed) }
        }
        self.entries = all
    }

    /// Whether the focused window's owning app must not be read.
    /// A nil bundle ID (unidentifiable window) is skipped.
    public func shouldSkip(bundleID: String?) -> Bool {
        guard let id = bundleID?.lowercased(), !id.isEmpty else { return true }
        return entries.contains(id)
    }
}
