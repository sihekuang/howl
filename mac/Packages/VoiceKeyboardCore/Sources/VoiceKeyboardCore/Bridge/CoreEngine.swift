import Foundation

/// Abstraction over the libvkb C ABI. Production impl is `LibvkbEngine`;
/// tests inject a fake.
public protocol CoreEngine: Sendable {
    /// Apply a Config to the engine. Replaces any prior configuration.
    /// Throws if the engine is busy (a capture is in flight) or the
    /// config is invalid (bad model path, etc.).
    func configure(_ config: EngineConfig) async throws

    /// Begin one PTT capture cycle. The host is then expected to feed
    /// Float32 mono 48 kHz frames via `pushAudio` and call `stopCapture`
    /// to signal end-of-input. Throws if not configured or busy.
    func startCapture() async throws

    /// Push a chunk of Float32 mono 48 kHz audio into the in-flight
    /// capture. Non-blocking on the audio thread: if the engine's
    /// internal buffer is full the chunk is dropped (and the engine
    /// emits a warning event once per cycle).
    func pushAudio(_ samples: [Float]) async throws

    /// End an in-flight capture by signaling end-of-input. The engine
    /// drains remaining frames, transcribes, cleans, and emits a
    /// `result` event. Idempotent.
    func stopCapture() async throws

    /// Drain at most one event from the C ABI's event queue. Returns
    /// nil when the queue is empty. Caller polls on a timer.
    func pollEvent() -> EngineEvent?

    /// The last error message set by the engine, if any.
    func lastError() -> String?

    /// Tear down the engine (idempotent).
    func shutdown()
}
