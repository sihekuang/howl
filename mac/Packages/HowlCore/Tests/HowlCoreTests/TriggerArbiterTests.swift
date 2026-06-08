import Foundation
import Testing
@testable import HowlCore

/// Thread-safe call counter for the arbiter's start/stop closures.
/// `@unchecked` is fine: the arbiter invokes these synchronously on the
/// calling thread in these tests, mirroring the SpyCoreEngine pattern.
private final class Counter: @unchecked Sendable {
    private(set) var value = 0
    func inc() { value += 1 }
}

@Suite("TriggerArbiter")
struct TriggerArbiterTests {
    private func make() -> (TriggerArbiter, starts: Counter, stops: Counter) {
        let starts = Counter()
        let stops = Counter()
        let arbiter = TriggerArbiter(
            onStart: { starts.inc() },
            onStop: { stops.inc() }
        )
        return (arbiter, starts, stops)
    }

    @Test func firstPressBecomesOwnerAndStarts() {
        let (arbiter, starts, stops) = make()
        arbiter.source(.keyboard).onPress()
        #expect(starts.value == 1)
        #expect(stops.value == 0)
    }

    @Test func secondSourcePressIgnoredWhileOwned() {
        let (arbiter, starts, stops) = make()
        arbiter.source(.keyboard).onPress()   // keyboard owns
        arbiter.source(.hid).onPress()        // ignored — already owned
        #expect(starts.value == 1)
        #expect(stops.value == 0)
    }

    @Test func nonOwnerReleaseIsIgnored() {
        let (arbiter, starts, stops) = make()
        arbiter.source(.keyboard).onPress()   // keyboard owns
        arbiter.source(.hid).onRelease()      // hid isn't owner → ignored
        #expect(starts.value == 1)
        #expect(stops.value == 0)
    }

    @Test func ownerReleaseClearsTokenAndStops() {
        let (arbiter, starts, stops) = make()
        let kb = arbiter.source(.keyboard)
        kb.onPress()
        kb.onRelease()
        #expect(starts.value == 1)
        #expect(stops.value == 1)
    }

    @Test func tokenIsReusableAfterOwnerReleases() {
        let (arbiter, starts, stops) = make()
        let kb = arbiter.source(.keyboard)
        kb.onPress()
        kb.onRelease()
        // After release the token is free, so the other source can acquire.
        arbiter.source(.hid).onPress()
        #expect(starts.value == 2)
        #expect(stops.value == 1)
    }

    /// Device-disconnect mid-hold: the monitor fires a synthetic release on the
    /// owning source. The token must clear (no stuck owner), and any stale
    /// duplicate release that arrives afterward is harmlessly ignored.
    @Test func deviceDisconnectForceReleaseClearsAndIsIdempotent() {
        let (arbiter, starts, stops) = make()
        let hid = arbiter.source(.hid)
        hid.onPress()                 // hid owns (user holding pedal)
        hid.onRelease()               // synthetic release on disconnect
        hid.onRelease()               // stale duplicate — must be ignored
        #expect(starts.value == 1)
        #expect(stops.value == 1)
        // Token is genuinely free: keyboard can now start.
        arbiter.source(.keyboard).onPress()
        #expect(starts.value == 2)
    }

    @Test func releaseBeforeAnyPressIsIgnored() {
        let (arbiter, starts, stops) = make()
        arbiter.source(.keyboard).onRelease()
        #expect(starts.value == 0)
        #expect(stops.value == 0)
    }
}
