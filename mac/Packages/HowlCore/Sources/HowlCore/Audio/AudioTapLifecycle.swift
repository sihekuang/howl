import Foundation

/// The install-tap / start-engine / remove-tap / stop-engine sequence
/// of an `AVAudioEngine` input capture, serialized under one lock.
///
/// Why this exists: `EngineCoordinator` is MainActor-isolated, but
/// `await`ing the capture class hands the actor back, so a trigger
/// release — or a second press — can run while `start` is still
/// inside `AVAudioEngine.start()` on the cooperative pool. Seen in
/// production 2026-09-09 (Howl 0.12.1): three presses in 30 ms, the
/// mid-start `stop()` found `isRunning == false` and left the tap in
/// place, the next `start` installed a tap over it, and AVFAudio
/// raised "required condition is false: nullptr == Tap()", which is
/// an uncaught ObjC exception and takes the process down.
///
/// Two rules, both enforced here rather than by callers:
/// 1. A tap is installed only when none is. A `start` that arrives
///    while one is installed (or being installed) is a no-op and
///    reports `false`.
/// 2. A `stop` removes whatever `start` has installed so far, even if
///    the engine never started. It waits for an in-flight `start` to
///    finish rather than skipping it.
final class AudioTapLifecycle: @unchecked Sendable {
    private let lock = NSLock()
    private var tapInstalled = false
    private var engineRunning = false

    /// Whether the engine has been started and not yet stopped.
    var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return engineRunning
    }

    /// Installs the tap and starts the engine, atomically with respect
    /// to `stop` and other `start`s. Returns `false` when a tap is
    /// already installed and nothing was done. If `installTap` throws,
    /// nothing is installed; if `runEngine` throws, the tap is removed
    /// again before the error propagates.
    @discardableResult
    func start(
        installTap: () throws -> Void,
        removeTap: () -> Void,
        runEngine: () throws -> Void
    ) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        if tapInstalled { return false }
        try installTap()
        tapInstalled = true
        do {
            try runEngine()
        } catch {
            removeTap()
            tapInstalled = false
            throw error
        }
        engineRunning = true
        return true
    }

    /// Removes the tap if one is installed and stops the engine if it
    /// is running. Idempotent.
    func stop(removeTap: () -> Void, stopEngine: () -> Void) {
        lock.lock(); defer { lock.unlock() }
        if tapInstalled {
            removeTap()
            tapInstalled = false
        }
        if engineRunning {
            stopEngine()
            engineRunning = false
        }
    }
}
