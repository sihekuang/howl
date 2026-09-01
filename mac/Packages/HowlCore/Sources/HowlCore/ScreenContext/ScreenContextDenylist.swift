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
    private let skipAll: Bool

    public init(userAdditions: [String]) {
        self.init(userAdditions: userAdditions, hostBundleID: Bundle.main.bundleIdentifier)
    }

    /// Injectable host bundle ID so the self-exclusion is testable.
    /// `Bundle.main.bundleIdentifier` is nil under the SwiftPM test
    /// runner, which would make an assertion against it vacuously pass
    /// while proving nothing about the app.
    init(userAdditions: [String], hostBundleID: String?) {
        var all = Set(ScreenContextDenylist.builtIn.map { $0.lowercased() })

        // Never read our own windows. This is a correctness guard, not
        // a privacy one, and it is not optional.
        //
        // Reading Howl's own AX tree means asking SwiftUI for
        // `accessibilityChildren`, and SwiftUI answers that by running
        // a view-graph update — a full layout pass — inside the
        // synchronous AX call. Demanding main-thread work from a
        // background thread that is itself blocking on the AX reply is
        // a self-deadlock, and it froze the app: macOS's hang report
        // showed the walk parked in
        // `NSHostingView.accessibilityChildren()` →
        // `ViewRendererHost.updateViewGraph` → `HostingScrollView`.
        // The larger our own UI, the worse it gets, so the Settings
        // window — the exact window a user has open while configuring
        // this feature — is the worst possible target.
        //
        // Screenshotting ourselves is merely useless rather than
        // dangerous, but it is excluded by the same entry: keywords
        // scraped from Howl's own chrome would bias whisper toward tab
        // names, and with the activity inspector on screen the feature
        // would read its own previous output back in.
        //
        // Resolved rather than hardcoded: this project's bundle ID has
        // already changed once (VoiceKeyboard → Howl) and the rename is
        // still mid-migration, so a literal would silently rot into a
        // no-op — which would look exactly like this bug coming back.
        if let own = hostBundleID?.lowercased(), !own.isEmpty {
            all.insert(own)
        }
        for id in userAdditions {
            let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !trimmed.isEmpty { all.insert(trimmed) }
        }
        self.entries = all
        self.skipAll = false
    }

    private init(skipAll: Bool) {
        self.entries = []
        self.skipAll = skipAll
    }

    /// A denylist that refuses every window, unconditionally. For use
    /// when the caller cannot determine the user's actual denylist
    /// configuration (e.g. the settings store threw on decode) — the
    /// safe failure mode is "read nothing" rather than silently
    /// falling back to `ScreenContextDenylist(userAdditions: [])`,
    /// which would only cover the built-in password-manager list and
    /// drop protection for any app the user explicitly added.
    public static let skipEverything = ScreenContextDenylist(skipAll: true)

    /// Whether the focused window's owning app must not be read.
    /// A nil bundle ID (unidentifiable window) is skipped.
    public func shouldSkip(bundleID: String?) -> Bool {
        if skipAll { return true }
        guard let id = bundleID?.lowercased(), !id.isEmpty else { return true }
        return entries.contains(id)
    }
}
