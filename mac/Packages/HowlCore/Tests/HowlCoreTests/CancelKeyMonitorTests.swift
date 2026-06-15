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

    @Test func cancelsOnAnyKey() {
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

    @Test func shouldCancelDecision() {
        #expect(CancelKeyMonitor.shouldCancel(userData: 0) == true)
        #expect(CancelKeyMonitor.shouldCancel(userData: 12345) == true)
        #expect(CancelKeyMonitor.shouldCancel(userData: HowlSyntheticEvent.marker) == false)
    }
}
