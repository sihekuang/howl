import Foundation
import Testing
@testable import HowlCore

/// End-to-end routing through the protocol seam: a `FakeHIDTriggerMonitor`
/// drives the arbiter exactly the way `EngineCoordinator` wires the real
/// monitor, so we prove "both sources live at once, first owns stop" with no
/// IOKit involved. `onStart`/`onStop` here stand in for the engine's
/// `startCapture()` / `stopCapture()` (the coordinator wraps them in a Task).
@Suite("HID trigger routing")
struct HIDTriggerRoutingTests {
    @Test func hidPressStartsAndReleaseStops() async throws {
        let starts = CallCounter()
        let stops = CallCounter()
        let arbiter = TriggerArbiter(onStart: { starts.inc() }, onStop: { stops.inc() })
        let hid = arbiter.source(.hid)
        let monitor = FakeHIDTriggerMonitor()

        try await monitor.start(nil, onPress: hid.onPress, onRelease: hid.onRelease)
        monitor.fireDown()
        #expect(starts.value == 1)
        monitor.fireUp()
        #expect(stops.value == 1)
    }

    @Test func keyboardPressIgnoredDuringHidOwnedSession() async throws {
        let starts = CallCounter()
        let stops = CallCounter()
        let arbiter = TriggerArbiter(onStart: { starts.inc() }, onStop: { stops.inc() })
        let keyboard = arbiter.source(.keyboard)
        let hid = arbiter.source(.hid)
        let monitor = FakeHIDTriggerMonitor()

        try await monitor.start(nil, onPress: hid.onPress, onRelease: hid.onRelease)
        monitor.fireDown()        // HID owns the session
        keyboard.onPress()        // keyboard press during HID session → ignored
        #expect(starts.value == 1)

        monitor.fireUp()          // HID (the owner) releases → stop
        #expect(stops.value == 1)
    }

    @Test func startStoresBindingForInspection() async throws {
        let arbiter = TriggerArbiter(onStart: {}, onStop: {})
        let hid = arbiter.source(.hid)
        let monitor = FakeHIDTriggerMonitor()
        let binding = HIDBinding(vendorID: 1, productID: 2, usagePage: 0x09, usage: 0x03)

        try await monitor.start(binding, onPress: hid.onPress, onRelease: hid.onRelease)
        #expect(monitor.startedBinding == binding)
    }

    @Test func learnDeliversCapturedBinding() async throws {
        let monitor = FakeHIDTriggerMonitor()
        let learned = LearnedBox()
        try await monitor.learnNextBinding { learned.set($0) }

        let captured = HIDBinding(vendorID: 9, productID: 8, usagePage: 0x09, usage: 0x05)
        monitor.fireLearned(captured)
        #expect(learned.value == captured)
    }
}

/// Reference box so a `@Sendable` learn callback can publish its result.
private final class LearnedBox: @unchecked Sendable {
    private(set) var value: HIDBinding?
    func set(_ b: HIDBinding) { value = b }
}
