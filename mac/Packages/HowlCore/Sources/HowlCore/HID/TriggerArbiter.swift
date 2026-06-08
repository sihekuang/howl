import Foundation
import os

/// Identifies a recording trigger source fanned into the arbiter.
///
/// Adding a future source (a network trigger, a second pedal protocol) means
/// adding a case here — the arbiter, `EngineCoordinator`, and the engine are
/// untouched (open/closed).
public enum TriggerSourceID: Hashable, Sendable {
    case keyboard
    case hid
}

/// Fans multiple trigger sources into a single start/stop seam using an
/// owner-token rule, so the engine only ever sees real start/stop transitions.
///
/// Owner-token rules (the `owner` field is guarded by an `os_unfair_lock`
/// because edges arrive from Carbon's main thread and the HID run loop):
/// - press + no owner   → set owner = source, call `onStart`.
/// - press + owner set   → ignore.
/// - release + source is owner     → clear owner, call `onStop`.
/// - release + source is not owner → ignore.
///
/// The closures are invoked *outside* the lock so a source can re-enter the
/// arbiter (or block) without risking a deadlock.
public final class TriggerArbiter: Sendable {
    private let onStart: @Sendable () -> Void
    private let onStop: @Sendable () -> Void
    private let owner = OSAllocatedUnfairLock<TriggerSourceID?>(initialState: nil)

    public init(
        onStart: @escaping @Sendable () -> Void,
        onStop: @escaping @Sendable () -> Void
    ) {
        self.onStart = onStart
        self.onStop = onStop
    }

    /// Vends the press/release closures a single source wraps its edges with.
    /// Each source keeps its existing closure-based interface; the owner-token
    /// logic lives entirely here.
    public func source(
        _ id: TriggerSourceID
    ) -> (onPress: @Sendable () -> Void, onRelease: @Sendable () -> Void) {
        (
            onPress: { [weak self] in self?.press(id) },
            onRelease: { [weak self] in self?.release(id) }
        )
    }

    private func press(_ id: TriggerSourceID) {
        let shouldStart = owner.withLock { current -> Bool in
            guard current == nil else { return false }
            current = id
            return true
        }
        if shouldStart { onStart() }
    }

    private func release(_ id: TriggerSourceID) {
        let shouldStop = owner.withLock { current -> Bool in
            guard current == id else { return false }
            current = nil
            return true
        }
        if shouldStop { onStop() }
    }
}
