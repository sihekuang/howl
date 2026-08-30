import Foundation

/// Runs an action once the caller has stopped scheduling it for
/// `interval` seconds — with a backstop: if `schedule` keeps being
/// called faster than `interval`, the action still fires no later
/// than `maxDelay` seconds after the FIRST schedule of the current
/// run. Extracted from the focus observer so the collapse-rapid-
/// events behaviour is testable without AppKit.
///
/// The backstop exists because a pure trailing debounce can be
/// starved forever by a sustained stream of schedules — a media
/// player retitling with a live timecode, a terminal retitling per
/// command, an animating page title, or a downloader's progress title
/// can all retitle faster than `interval`, and without a cap the
/// action would simply never fire while that keeps happening. This is
/// the standard debounce-with-maxWait shape.
public final class Debouncer: @unchecked Sendable {
    private let interval: TimeInterval
    private let maxDelay: TimeInterval
    private let lock = NSLock()
    private var pending: Task<Void, Never>?
    // When the current run's FIRST `schedule` call arrived. Reset to
    // nil once the action actually fires (or is cancelled), so the
    // next `schedule` call starts a fresh maxDelay window rather than
    // inheriting a stale one.
    private var runStartedAt: Date?

    public init(interval: TimeInterval, maxDelay: TimeInterval = 5.0) {
        self.interval = interval
        self.maxDelay = maxDelay
    }

    /// Schedule `action`, superseding any run not yet started. Fires
    /// after `interval` seconds of quiet, or after `maxDelay` seconds
    /// since the first call in this run, whichever comes first.
    public func schedule(_ action: @escaping @Sendable () async -> Void) {
        lock.lock()
        pending?.cancel()

        let now = Date()
        let startedAt = runStartedAt ?? now
        runStartedAt = startedAt

        let trailingDeadline = now.addingTimeInterval(interval)
        let capDeadline = startedAt.addingTimeInterval(maxDelay)
        let fireAt = min(trailingDeadline, capDeadline)
        let seconds = max(0, fireAt.timeIntervalSince(now))

        pending = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if Task.isCancelled { return }
            await action()
            self?.finishRun()
        }
        lock.unlock()
    }

    public func cancel() {
        lock.lock()
        pending?.cancel()
        pending = nil
        runStartedAt = nil
        lock.unlock()
    }

    private func finishRun() {
        lock.lock()
        pending = nil
        runStartedAt = nil
        lock.unlock()
    }

    deinit { pending?.cancel() }
}
