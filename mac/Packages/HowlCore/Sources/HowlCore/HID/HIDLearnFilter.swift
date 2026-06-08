import Foundation

/// Pure eligibility decision for learn-the-next-button: given one raw HID
/// element edge, returns the `HIDBinding` to learn, or `nil` if the edge
/// should be ignored.
///
/// Kept separate from `IOHIDTriggerMonitor` so the (non-obvious) rules about
/// what counts as a "learnable" trigger are fully unit-tested without IOKit.
public enum HIDLearnFilter {
    /// HID usage pages / usages we never learn.
    private static let keyboardPage = 0x07
    private static let genericDesktopPage = 0x01
    /// Continuous Generic Desktop axes (pointer X/Y/Z, stick rotations,
    /// slider, dial, wheel) — these move continuously and aren't discrete
    /// triggers, so a moving mouse/stick must not "learn" a binding.
    private static let continuousAxes: Set<Int> = [
        0x30, 0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38,
    ]

    public static func binding(
        vendorID: Int,
        productID: Int,
        usagePage: Int,
        usage: Int,
        value: Int
    ) -> HIDBinding? {
        // Only a down edge (press), never a release.
        guard value != 0 else { return nil }
        // Never the keyboard — that path is owned by the keyboard hotkey, and
        // the built-in keyboard is restricted anyway.
        guard usagePage != keyboardPage else { return nil }
        // Never a continuous pointer/stick axis.
        if usagePage == genericDesktopPage, continuousAxes.contains(usage) { return nil }
        return HIDBinding(vendorID: vendorID, productID: productID, usagePage: usagePage, usage: usage)
    }
}
