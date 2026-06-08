import Foundation

/// Identifies a single HID device element chosen as a recording trigger.
///
/// Mirrors how `KeyboardShortcut` describes a keyboard trigger: a small,
/// `Codable` value type persisted in `UserSettings`. The four fields uniquely
/// pick one element on one device — vendor/product locate the device, usage
/// page/usage locate the element (e.g. a specific gamepad button or pedal).
public struct HIDBinding: Codable, Equatable, Sendable {
    public var vendorID: Int
    public var productID: Int
    /// The element's HID usage page (e.g. 0x09 = Button).
    public var usagePage: Int
    /// The element's HID usage within its page (e.g. button index).
    public var usage: Int

    public init(vendorID: Int, productID: Int, usagePage: Int, usage: Int) {
        self.vendorID = vendorID
        self.productID = productID
        self.usagePage = usagePage
        self.usage = usage
    }
}
