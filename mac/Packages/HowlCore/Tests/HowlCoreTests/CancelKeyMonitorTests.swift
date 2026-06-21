import Testing
import Foundation
@testable import HowlCore

private final class Counter: @unchecked Sendable { var value = 0 }

@Suite("CancelKeyMonitor")
struct CancelKeyMonitorTests {
    @Test func cancelsOnEsc() {
        let c = Counter()
        let mon = CancelKeyMonitor(onCancel: { c.value += 1 })
        mon.simulateEscForTest()
        #expect(c.value == 1)
    }

    @Test func cancelsOnAnyFreshKey() {
        let c = Counter()
        let mon = CancelKeyMonitor(onCancel: { c.value += 1 })
        mon.simulateKeyForTest(keyCode: 0)
        #expect(c.value == 1)
    }

    @Test func ignoresHowlSyntheticKey() {
        let c = Counter()
        let mon = CancelKeyMonitor(onCancel: { c.value += 1 })
        mon.simulateSyntheticKeyForTest()
        #expect(c.value == 0)
    }

    @Test func ignoresAutoRepeatOfHeldKey() {
        let c = Counter()
        let mon = CancelKeyMonitor(onCancel: { c.value += 1 })
        // A held push-to-talk combo's base key auto-repeats; those repeats
        // must NOT cancel the dictation they triggered.
        mon.simulateKeyForTest(keyCode: 49, isAutorepeat: true)
        #expect(c.value == 0)
    }

    @Test func shouldCancelDecision() {
        // A fresh, real keypress cancels.
        #expect(CancelKeyMonitor.shouldCancel(userData: 0, isAutorepeat: false) == true)
        #expect(CancelKeyMonitor.shouldCancel(userData: 12345, isAutorepeat: false) == true)
        // Our own injected keystroke never cancels.
        #expect(CancelKeyMonitor.shouldCancel(userData: HowlSyntheticEvent.marker, isAutorepeat: false) == false)
        // OS auto-repeat of a held key never cancels.
        #expect(CancelKeyMonitor.shouldCancel(userData: 0, isAutorepeat: true) == false)
    }
}
