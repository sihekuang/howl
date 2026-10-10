import Foundation

/// Reports the first captured frame that contains any sound, once per
/// recording. Bluetooth headsets deliver exact-zero buffers while they
/// switch into call mode (2–4 s for idle AirPods), so "first non-zero
/// sample" is when the mic is actually live — the moment to play the
/// listening cue.
///
/// `observe` runs on the audio thread; `reset` on the main actor.
public final class FirstSoundDetector: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false

    public init() {}

    /// Arm for a new recording.
    public func reset() {
        lock.lock(); fired = false; lock.unlock()
    }

    /// True for the first frame with a non-zero sample since `reset`,
    /// false for every other call.
    public func observe(_ samples: [Float]) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if fired { return false }
        guard samples.contains(where: { $0 != 0 }) else { return false }
        fired = true
        return true
    }
}
