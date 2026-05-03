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
    /// capture. Synchronous and safe to call from any thread (the
    /// underlying C ABI is internally synchronized). Non-blocking:
    /// if the engine's internal buffer is full the chunk is dropped
    /// and a single warning event is emitted per cycle.
    ///
    /// IMPORTANT: this MUST NOT be actor-isolated. Audio-thread
    /// callbacks pushing through `Task.detached` race with
    /// `stopCapture` for actor entry; many pushes lose the race and
    /// vanish, causing the pipeline to receive only ~1/N of the
    /// captured audio.
    func pushAudio(_ samples: [Float]) throws

    /// End an in-flight capture by signaling end-of-input. The engine
    /// drains remaining frames, transcribes, cleans, and emits a
    /// `result` event. Idempotent.
    func stopCapture() async throws

    /// Aborts the in-flight capture (if any). The Go core emits a
    /// `cancelled` event and runs no LLM cleanup. Idempotent.
    func cancelCapture()

    /// Drain at most one event from the C ABI's event queue. Returns
    /// nil when the queue is empty. Caller polls on a timer.
    func pollEvent() -> EngineEvent?

    /// Compute and persist a voice enrollment from a single recorded buffer.
    /// `samples` must be 48 kHz mono Float32. The engine decimates to 16 kHz
    /// internally, runs the encoder, and writes enrollment.wav,
    /// enrollment.emb, speaker.json into `profileDir`. The directory is
    /// created if missing. Throws if the engine is not configured with
    /// `speakerEncoderPath` and `onnxLibPath` set, or if compute fails.
    func computeEnrollment(samples: [Float], sampleRate: Int, profileDir: String) async throws

    /// The last error message set by the engine, if any.
    func lastError() -> String?

    /// Tear down the engine (idempotent).
    func shutdown()

    /// Returns the JSON array of session manifests from libvkb, or nil
    /// when the engine is not initialized. nil is distinct from the
    /// empty list case (which returns "[]").
    func sessionsListJSON() async -> String?

    /// Returns the JSON manifest for a single session, or nil when the
    /// session does not exist or its manifest is unreadable.
    func sessionGetJSON(_ id: String) async -> String?

    /// Deletes a session folder. Returns the C ABI return code
    /// (0 = success, 1 = engine not init, 5 = invalid id, 6 = fs err).
    func sessionDelete(_ id: String) async -> Int32

    /// Clears every session folder. Same return-code convention.
    func sessionsClear() async -> Int32

    /// Returns the JSON array of presets (bundled + user) from libvkb,
    /// or nil if the engine is not initialized.
    func presetsListJSON() async -> String?

    /// Returns the JSON-encoded Preset for the given name, or nil if
    /// the preset doesn't exist.
    func presetGetJSON(_ name: String) async -> String?

    /// Persists a user preset. body is a JSON-encoded Preset.
    /// Returns the C ABI return code (0 = ok, 5 = invalid/reserved name,
    /// 6 = filesystem error, 2 = parse error).
    func presetSaveJSON(name: String, description: String, body: String) async -> Int32

    /// Removes a user preset. Idempotent. Returns the C ABI return code.
    func presetDelete(_ name: String) async -> Int32

    /// Drive a Compare run. Returns the JSON array body from
    /// vkb_replay (or {"error": "..."} envelope on top-level failure),
    /// or nil if the engine is not initialized.
    func replayJSON(sourceID: String, presetsCSV: String) async -> String?
}
