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

    @Test func nonButtonPagesAreIgnored() {
        // Only the Button usage page (0x09) is a reliable discrete trigger.
        // Hat switches (GD 0x39) and consumer controls (0x0C) are excluded —
        // gamepads stream continuous data on non-button pages.
        #expect(HIDLearnFilter.binding(vendorID: vid, productID: pid, usagePage: 0x01, usage: 0x39, value: 1) == nil)
        #expect(HIDLearnFilter.binding(vendorID: vid, productID: pid, usagePage: 0x0C, usage: 0xB0, value: 1) == nil)
    }

    @Test func acceptsOnlyButtonPage() {
        // Shared policy used by both learn (capture) and bind (honor a saved
        // binding) — keep them in lock-step.
        #expect(HIDLearnFilter.acceptsUsagePage(0x09))
        #expect(!HIDLearnFilter.acceptsUsagePage(0xFF00))
        #expect(!HIDLearnFilter.acceptsUsagePage(0x01))
        #expect(!HIDLearnFilter.acceptsUsagePage(0x07))
    }

    @Test func vendorDefinedStreamIsIgnored() {
        // Regression: a PS5 DualSense (054C:0CE6) streams continuous vendor
        // reports on page 0xFF00 the instant it connects. Learn must wait for a
        // real button press, never capture this noise.
        let b = HIDLearnFilter.binding(vendorID: 0x054C, productID: 0x0CE6, usagePage: 0xFF00, usage: 0x22, value: 5)
        #expect(b == nil)
    }
}
