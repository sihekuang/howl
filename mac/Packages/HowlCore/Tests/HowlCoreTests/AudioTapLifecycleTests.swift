import Foundation
import Testing
@testable import HowlCore

// Crash seen in production 2026-09-09 (Howl 0.12.1): three trigger
// presses within 30 ms. `AVAudioInputCapture.start` had installed the
// tap for press 1 and was still inside `AVAudioEngine.start()` when
// the release arrived; `stop()` saw `isRunning == false` and left the
// tap in place; press 2 then called `installTap` again and AVFAudio
// raised "required condition is false: nullptr == Tap()".
//
// The coordinator is MainActor-isolated, but `await`ing the capture
// class hands the actor back, so press/release/press DO interleave
// with an in-flight start. The lifecycle below is the piece that must
// hold up under that: one tap at a time, and a stop always removes
// whatever was installed, even mid-start.

/// Records what the fake engine was told to do, in order, and flags
/// the exact thing that crashed: a tap installed over a tap.
private final class EngineLog: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var events: [String] = []
    private var tapsOutstanding = 0
    private(set) var doubleInstalls = 0

    func install() {
        lock.lock(); defer { lock.unlock() }
        if tapsOutstanding > 0 { doubleInstalls += 1 }
        tapsOutstanding += 1
        events.append("install")
    }
    func remove() {
        lock.lock(); defer { lock.unlock() }
        tapsOutstanding -= 1
        events.append("remove")
    }
    func note(_ e: String) { lock.lock(); events.append(e); lock.unlock() }
    var outstanding: Int { lock.lock(); defer { lock.unlock() }; return tapsOutstanding }
}

private func onThread(_ body: @escaping @Sendable () -> Void) -> DispatchGroup {
    let group = DispatchGroup()
    DispatchQueue.global().async(group: group, execute: body)
    return group
}

@Suite("Audio tap lifecycle")
struct AudioTapLifecycleTests {

    @Test func press_release_press_never_installs_a_tap_over_a_tap() throws {
        let log = EngineLog()
        let lifecycle = AudioTapLifecycle()
        let engineEntered = DispatchSemaphore(value: 0)
        let letEngineFinish = DispatchSemaphore(value: 0)

        // Press 1: the engine start blocks, exactly like the 30 ms of
        // HAL setup in production.
        let press1 = onThread {
            _ = try? lifecycle.start(
                installTap: { log.install() },
                removeTap: { log.remove() },
                runEngine: { log.note("run"); engineEntered.signal(); letEngineFinish.wait() }
            )
        }
        #expect(engineEntered.wait(timeout: .now() + 5) == .success)

        // Release and press 2 arrive while press 1 is still starting.
        let release = onThread {
            lifecycle.stop(removeTap: { log.remove() }, stopEngine: { log.note("halt") })
        }
        let press2 = onThread {
            _ = try? lifecycle.start(
                installTap: { log.install() },
                removeTap: { log.remove() },
                runEngine: { log.note("run") }
            )
        }
        letEngineFinish.signal()
        #expect(press1.wait(timeout: .now() + 5) == .success)
        #expect(release.wait(timeout: .now() + 5) == .success)
        #expect(press2.wait(timeout: .now() + 5) == .success)

        #expect(log.doubleInstalls == 0, "AVFAudio aborts the process on this: \(log.events)")
        #expect(log.outstanding <= 1)
    }

    @Test func a_stop_that_lands_mid_start_still_removes_the_tap() {
        let log = EngineLog()
        let lifecycle = AudioTapLifecycle()
        let engineEntered = DispatchSemaphore(value: 0)
        let letEngineFinish = DispatchSemaphore(value: 0)

        let start = onThread {
            _ = try? lifecycle.start(
                installTap: { log.install() },
                removeTap: { log.remove() },
                runEngine: { engineEntered.signal(); letEngineFinish.wait(); log.note("run") }
            )
        }
        #expect(engineEntered.wait(timeout: .now() + 5) == .success)
        let stop = onThread {
            lifecycle.stop(removeTap: { log.remove() }, stopEngine: { log.note("halt") })
        }
        letEngineFinish.signal()
        #expect(start.wait(timeout: .now() + 5) == .success)
        #expect(stop.wait(timeout: .now() + 5) == .success)

        #expect(log.events == ["install", "run", "remove", "halt"])
        #expect(log.outstanding == 0)
        #expect(lifecycle.isRunning == false)
    }

    @Test func a_second_start_on_a_running_capture_is_a_no_op() throws {
        let log = EngineLog()
        let lifecycle = AudioTapLifecycle()
        let first = try lifecycle.start(installTap: { log.install() }, removeTap: { log.remove() }, runEngine: {})
        let second = try lifecycle.start(installTap: { log.install() }, removeTap: { log.remove() }, runEngine: {})
        #expect(first == true)
        #expect(second == false)
        #expect(log.events == ["install"])
    }

    @Test func an_engine_that_fails_to_start_leaves_no_tap_behind() {
        struct Boom: Error {}
        let log = EngineLog()
        let lifecycle = AudioTapLifecycle()
        #expect(throws: Boom.self) {
            try lifecycle.start(installTap: { log.install() }, removeTap: { log.remove() }, runEngine: { throw Boom() })
        }
        #expect(log.events == ["install", "remove"])
        #expect(lifecycle.isRunning == false)
        // And the next start is allowed.
        #expect((try? lifecycle.start(installTap: { log.install() }, removeTap: { log.remove() }, runEngine: {})) == true)
    }

    @Test func stop_before_any_start_does_nothing() {
        let log = EngineLog()
        let lifecycle = AudioTapLifecycle()
        lifecycle.stop(removeTap: { log.remove() }, stopEngine: { log.note("halt") })
        #expect(log.events.isEmpty)
    }
}
