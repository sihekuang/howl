import Foundation
import Testing
@testable import HowlCore

@Suite("HIDLearnFilter")
struct HIDLearnFilterTests {
    private let vid = 0x046D
    private let pid = 0xC52B

    @Test func buttonDownEdgeIsLearned() {
        let b = HIDLearnFilter.binding(vendorID: vid, productID: pid, usagePage: 0x09, usage: 0x02, value: 1)
        #expect(b == HIDBinding(vendorID: vid, productID: pid, usagePage: 0x09, usage: 0x02))
    }

    @Test func upEdgeIsIgnored() {
        // value == 0 is a release; learn only captures a press.
        let b = HIDLearnFilter.binding(vendorID: vid, productID: pid, usagePage: 0x09, usage: 0x02, value: 0)
        #expect(b == nil)
    }

    @Test func keyboardKeyIsIgnored() {
        // Keyboard usage page (0x07) must never be learnable — the keyboard
        // hotkey path owns the keyboard, and the built-in keyboard is restricted.
        let b = HIDLearnFilter.binding(vendorID: vid, productID: pid, usagePage: 0x07, usage: 0x04, value: 1)
        #expect(b == nil)
    }

    @Test func pointerAxesAreIgnored() {
        // Continuous Generic Desktop axes (mouse X/Y/wheel, sticks) aren't
        // discrete triggers — moving the device must not "learn" a binding.
        for axis in [0x30, 0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38] {
            let b = HIDLearnFilter.binding(vendorID: vid, productID: pid, usagePage: 0x01, usage: axis, value: 5)
            #expect(b == nil, "GD axis \(axis) should be ignored")
        }
    }

    @Test func gamepadHatAndVendorButtonsAreLearnable() {
        // A hat switch (GD 0x39) and a consumer/vendor control page are valid
        // discrete triggers.
        let hat = HIDLearnFilter.binding(vendorID: vid, productID: pid, usagePage: 0x01, usage: 0x39, value: 1)
        #expect(hat == HIDBinding(vendorID: vid, productID: pid, usagePage: 0x01, usage: 0x39))
        let consumer = HIDLearnFilter.binding(vendorID: vid, productID: pid, usagePage: 0x0C, usage: 0xB0, value: 1)
        #expect(consumer == HIDBinding(vendorID: vid, productID: pid, usagePage: 0x0C, usage: 0xB0))
    }
}
