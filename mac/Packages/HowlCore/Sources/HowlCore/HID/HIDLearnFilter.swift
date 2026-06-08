import Foundation

/// Pure eligibility decision for learn-the-next-button: given one raw HID
/// element edge, returns the `HIDBinding` to learn, or `nil` if the edge
/// should be ignored.
///
/// Kept separate from `IOHIDTriggerMonitor` so the (non-obvious) rules about
/// what counts as a "learnable" trigger are fully unit-tested without IOKit.
///
/// **Only the HID Button usage page (0x09) is accepted.** Gamepads stream
/// continuous data on other pages — analog axes (Generic Desktop) and, on the
/// PS5 DualSense, a vendor-defined report on page 0xFF00 — which would
/// otherwise be "learned" instantly before the user presses anything, and then
/// fire the trigger continuously. Real digital buttons (gamepad face/shoulder,
/// extra mouse buttons, HID-button pedals) all live on the Button page.
public enum HIDLearnFilter {
    /// The one HID usage page we treat as a discrete, bindable trigger.
    public static let buttonUsagePage = 0x09

    /// Whether an element on this usage page is an acceptable trigger. Shared by
    /// learn (capture) and bind (honor a saved binding), so a stale non-button
    /// binding can't be re-armed.
    public static func acceptsUsagePage(_ usagePage: Int) -> Bool {
        usagePage == buttonUsagePage
    }

    public static func binding(
        vendorID: Int,
        productID: Int,
        usagePage: Int,
        usage: Int,
        value: Int
    ) -> HIDBinding? {
        // Only a down edge (press), never a release.
        guard value != 0 else { return nil }
        // Only real buttons — never keyboard keys, analog/stick axes, or
        // vendor-defined report streams.
        guard acceptsUsagePage(usagePage) else { return nil }
        return HIDBinding(vendorID: vendorID, productID: productID, usagePage: usagePage, usage: usage)
    }
}
