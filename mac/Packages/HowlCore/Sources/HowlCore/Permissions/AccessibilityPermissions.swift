import Foundation
import ApplicationServices
import AppKit

public protocol AccessibilityPermissions: Sendable {
    /// Returns whether the process is currently trusted (no UI side effect).
    func isTrusted() -> Bool

    /// Same as isTrusted, but additionally pops the system prompt asking
    /// the user to grant access if they haven't already.
    func requestTrust() -> Bool

    /// Open the System Settings panel to the Accessibility privacy section.
    func openSystemSettings()
}

public final class DefaultAccessibilityPermissions: AccessibilityPermissions, @unchecked Sendable {
    public init() {}

    public func isTrusted() -> Bool {
        AXIsProcessTrustedWithOptions(nil)
    }

    public func requestTrust() -> Bool {
        // "AXTrustedCheckOptionPrompt" is the string value of kAXTrustedCheckOptionPrompt.
        // Using the literal avoids a Swift 6 concurrency error on the C global.
        let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }

    public func openSystemSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
}
