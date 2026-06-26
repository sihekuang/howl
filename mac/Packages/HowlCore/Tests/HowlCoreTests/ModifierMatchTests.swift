import CoreGraphics
import Testing
@testable import HowlCore

@Suite("requiredFlagsHeld")
struct ModifierMatchTests {
    @Test func controlHeldMatchesControlRequirement() {
        #expect(CarbonHotkeyMonitor.requiredFlagsHeld([.maskControl], required: [.control]))
    }

    @Test func controlNotHeldFailsControlRequirement() {
        #expect(!CarbonHotkeyMonitor.requiredFlagsHeld([], required: [.control]))
    }

    @Test func extraHeldFlagsDoNotBreakMatch() {
        // Required is just control; command also held -> still matches.
        #expect(CarbonHotkeyMonitor.requiredFlagsHeld([.maskControl, .maskCommand], required: [.control]))
    }

    @Test func allOfMultiRequirementMustBeHeld() {
        #expect(CarbonHotkeyMonitor.requiredFlagsHeld([.maskControl, .maskAlternate], required: [.control, .option]))
        #expect(!CarbonHotkeyMonitor.requiredFlagsHeld([.maskControl], required: [.control, .option]))
    }

    @Test func eachModifierMapsToCorrectMask() {
        #expect(CarbonHotkeyMonitor.requiredFlagsHeld([.maskAlternate], required: [.option]))
        #expect(CarbonHotkeyMonitor.requiredFlagsHeld([.maskCommand], required: [.command]))
        #expect(CarbonHotkeyMonitor.requiredFlagsHeld([.maskShift], required: [.shift]))
        #expect(CarbonHotkeyMonitor.requiredFlagsHeld([.maskSecondaryFn], required: [.fn]))
    }
}
