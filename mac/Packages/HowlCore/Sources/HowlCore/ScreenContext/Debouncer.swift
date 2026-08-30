import Foundation

/// Runs an action once the caller has stopped scheduling it for
/// `interval` seconds. Extracted from the focus observer so the
/// collapse-rapid-events behaviour is testable without AppKit.
public final class Debouncer: @unchecked Sendable {
    private let interval: TimeInterval
    private let lock = NSLock()
    private var pending: Task<Void, Never>?

    public init(interval: TimeInterval) {
        self.interval = interval
    }

    /// Schedule `action`, superseding any run not yet started.
    public func schedule(_ action: @escaping @Sendable () async -> Void) {
        lock.lock()
        pending?.cancel()
        let seconds = interval
        pending = Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if Task.isCancelled { return }
            await action()
        }
        lock.unlock()
    }

    public func cancel() {
        lock.lock()
        pending?.cancel()
        pending = nil
        lock.unlock()
    }

    deinit { pending?.cancel() }
}
