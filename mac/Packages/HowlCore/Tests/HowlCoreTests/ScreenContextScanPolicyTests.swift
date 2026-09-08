import Foundation
import Testing
@testable import HowlCore

@Suite("Screen context scan policy")
struct ScreenContextScanPolicyTests {
    @Test("scans while the machine is in active use")
    func active_machine() {
        #expect(ScreenContextScanPolicy.shouldScan(idleSeconds: 0))
        #expect(ScreenContextScanPolicy.shouldScan(idleSeconds: 12))
    }

    @Test("pauses once the machine has been idle past the limit")
    func idle_machine() {
        #expect(!ScreenContextScanPolicy.shouldScan(idleSeconds: 61))
        #expect(!ScreenContextScanPolicy.shouldScan(idleSeconds: 3600))
    }

    @Test("the idle boundary is inclusive — exactly at the limit still scans")
    func boundary() {
        #expect(ScreenContextScanPolicy.shouldScan(idleSeconds: 60, maxIdle: 60))
        #expect(!ScreenContextScanPolicy.shouldScan(idleSeconds: 60.001, maxIdle: 60))
    }

    @Test("fails OPEN when idle time is unknown")
    func unknown_idle_time() {
        // A wrong "yes" costs one screenshot; a wrong "no" silently
        // disables periodic scanning entirely. Deliberately the
        // opposite of the denylist's fail-closed rule, which is
        // protecting something rather than spending something.
        #expect(ScreenContextScanPolicy.shouldScan(idleSeconds: nil))
    }
}
