import Foundation
import Testing
@testable import VoiceKeyboardCore

@Suite("CancelKeyMonitor")
struct CancelKeyMonitorTests {
    @Test func stopBeforeStartIsIdempotent() {
        let monitor = CancelKeyMonitor()
        monitor.stop() // must not crash
        monitor.stop()
    }

    @Test func startAndStopDoNotCrash() {
        let monitor = CancelKeyMonitor()
        monitor.start(onCancel: {})
        monitor.stop()
    }

    @Test func multipleStopsAreIdempotent() {
        let monitor = CancelKeyMonitor()
        monitor.start(onCancel: {})
        monitor.stop()
        monitor.stop()
        monitor.stop()
    }

    @Test func startReplacesExistingMonitor() {
        let monitor = CancelKeyMonitor()
        monitor.start(onCancel: {})
        // Second start should remove the first monitor and install a new one.
        monitor.start(onCancel: {})
        monitor.stop()
    }
}
