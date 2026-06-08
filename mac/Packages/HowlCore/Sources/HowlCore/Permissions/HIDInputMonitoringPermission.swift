import Foundation
import IOKit.hid
import AppKit

/// Input Monitoring (TCC) permission for HID listening. This is a *separate*
/// permission from Accessibility — listening to raw HID input requires it even
/// though the keyboard hotkey path does not. Mirrors `AccessibilityPermissions`
/// so it injects and fakes the same way (interface segregation: not folded into
/// `HIDTriggerMonitor`).
public protocol HIDInputMonitoringPermission: Sendable {
    /// Whether Input Monitoring is currently granted (no UI side effect).
    func isGranted() -> Bool

    /// Same as `isGranted`, but pops the system prompt if not yet decided.
    /// Returns whether access is granted after the request.
    func request() -> Bool

    /// Open System Settings to the Input Monitoring privacy section.
    func openSystemSettings()
}

public final class DefaultHIDInputMonitoringPermission: HIDInputMonitoringPermission, @unchecked Sendable {
    public init() {}

    public func isGranted() -> Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    public func request() -> Bool {
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    public func openSystemSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!
        NSWorkspace.shared.open(url)
    }
}
