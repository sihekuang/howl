import Foundation

/// Abstraction over the libvkb C ABI. Production impl is `LibvkbEngine`;
/// tests inject a fake.
public protocol CoreEngine: Sendable {
    /// Apply a Config to the engine. Replaces any prior configuration.
    /// Throws if the engine is busy (a capture is in flight) or the
    /// config is invalid (bad model path, etc.).
    func configure(_ config: EngineConfig) async throws

    /// Begin one PTT capture cycle. Throws if not configured or busy.
    func startCapture() async throws

    /// End an in-flight capture (idempotent).
    func stopCapture() async throws

    /// Drain at most one event from the C ABI's event queue. Returns
    /// nil when the queue is empty. Caller polls on a timer.
    func pollEvent() -> EngineEvent?

    /// The last error message set by the engine, if any.
    func lastError() -> String?

    /// Tear down the engine (idempotent).
    func shutdown()
}
