import Testing
import Foundation
@testable import VoiceKeyboardCore

private final class Counter: @unchecked Sendable { var value = 0 }

@Suite("CancelKeyMonitor")
struct CancelKeyMonitorTests {
    @Test func callsHandlerOnEsc() {
        let c = Counter()
        let mon = CancelKeyMonitor(onCancel: { c.value += 1 })
        mon.simulateEscForTest()
        #expect(c.value == 1)
    }

    @Test func ignoresOtherKeys() {
        let c = Counter()
        let mon = CancelKeyMonitor(onCancel: { c.value += 1 })
        mon.simulateKeyForTest(keyCode: 0)
        #expect(c.value == 0)
    }
}
