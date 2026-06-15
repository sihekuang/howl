import Testing
import CoreGraphics
@testable import HowlCore

@Suite("HowlSyntheticEvent")
struct HowlSyntheticEventTests {
    @Test func markerIsStable() {
        // Guards against an accidental value change that would silently
        // break the cancel monitor's filter.
        #expect(HowlSyntheticEvent.marker == 0x484F_574C_0001)
    }

    @Test func cgEventMarkerRoundTrips() {
        guard let ev = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true) else {
            // No window server (headless CI) — CGEvent creation returns nil.
            // Nothing to assert; the pure decision logic is covered elsewhere.
            return
        }
        #expect(ev.isHowlSynthetic == false)
        ev.markAsHowlSynthetic()
        #expect(ev.isHowlSynthetic == true)
    }
}
