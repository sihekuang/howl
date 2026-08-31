import Foundation
import CVKB

public enum LibvkbError: Error, Equatable {
    case notInitialized
    case busy            // configure during in-flight capture, etc.
    case configureFailed(String)
    case startFailed(String)
    case pushFailed(String)
    case stopFailed(String)
    case enrollFailed(String)
    case enrollInvalidArgument(String)
}

/// Thin Swift wrapper over the libhowl C ABI.
///
/// The Go core supports exactly one engine per process. LibhowlEngine
/// enforces that with actor isolation — all C calls go through the
/// actor's serialized executor since the C functions are not
/// concurrent-safe.
public actor LibhowlEngine: CoreEngine {
    public init() {}

    public func configure(_ config: EngineConfig) async throws {
        // Initialize on first configure (idempotent on the C side).
        let initRC = howl_init()
        if initRC != 0 {
            throw LibvkbError.configureFailed("howl_init failed: \(initRC)")
        }
        let json = try JSONEncoder().encode(config)
        guard let cString = String(data: json, encoding: .utf8) else {
            throw LibvkbError.configureFailed("could not encode config as UTF-8")
        }
        let rc = cString.withCString { ptr in
            howl_configure(UnsafeMutablePointer(mutating: ptr))
        }
        switch rc {
        case 0: return
        case 4: throw LibvkbError.busy
        default:
            let msg = readLastError() ?? "howl_configure rc=\(rc)"
            throw LibvkbError.configureFailed(msg)
        }
    }

    public func startCapture() async throws {
        let rc = howl_start_capture()
        switch rc {
        case 0: return
        case 1: throw LibvkbError.notInitialized
        case 2: throw LibvkbError.busy
        default:
            let msg = readLastError() ?? "howl_start_capture rc=\(rc)"
            throw LibvkbError.startFailed(msg)
        }
    }

    public nonisolated func pushAudio(_ samples: [Float]) throws {
        guard !samples.isEmpty else { return }
        let rc = samples.withUnsafeBufferPointer { buf -> Int32 in
            guard let base = buf.baseAddress else { return 0 }
            return howl_push_audio(base, Int32(buf.count))
        }
        switch rc {
        case 0: return
        case 1: throw LibvkbError.notInitialized
        case 2: throw LibvkbError.pushFailed("no capture in flight")
        default:
            throw LibvkbError.pushFailed("howl_push_audio rc=\(rc)")
        }
    }

    public func stopCapture() async throws {
        let rc = howl_stop_capture()
        if rc != 0 {
            let msg = readLastError() ?? "howl_stop_capture rc=\(rc)"
            throw LibvkbError.stopFailed(msg)
        }
    }

    public nonisolated func cancelCapture() {
        howl_cancel_capture()
    }

    public nonisolated func pollEvent() -> EngineEvent? {
        guard let cstr = howl_poll_event() else { return nil }
        defer { howl_free_string(cstr) }
        let json = String(cString: cstr)
        return try? JSONDecoder().decode(EngineEvent.self, from: Data(json.utf8))
    }

    public nonisolated func lastError() -> String? {
        readLastError()
    }

    public nonisolated func shutdown() {
        howl_destroy()
    }

    public func computeEnrollment(samples: [Float], sampleRate: Int, profileDir: String) async throws {
        guard !samples.isEmpty else {
            throw LibvkbError.enrollInvalidArgument("empty samples buffer")
        }
        guard sampleRate == 48000 else {
            throw LibvkbError.enrollInvalidArgument("sampleRate must be 48000, got \(sampleRate)")
        }

        let rc: Int32 = samples.withUnsafeBufferPointer { sampleBuf in
            profileDir.withCString { dirCStr in
                guard let base = sampleBuf.baseAddress else { return 5 }
                return howl_enroll_compute(base, Int32(sampleBuf.count), Int32(sampleRate), dirCStr)
            }
        }

        switch rc {
        case 0: return
        case 1: throw LibvkbError.notInitialized
        case 5:
            let msg = readLastError() ?? "howl_enroll_compute: invalid argument"
            throw LibvkbError.enrollInvalidArgument(msg)
        default:
            let msg = readLastError() ?? "howl_enroll_compute rc=\(rc)"
            throw LibvkbError.enrollFailed(msg)
        }
    }

    public func sessionsListJSON() -> String? {
        guard let cstr = howl_list_sessions() else { return nil }
        defer { howl_free_string(cstr) }
        return String(cString: cstr)
    }

    public func sessionGetJSON(_ id: String) -> String? {
        return id.withCString { cid -> String? in
            guard let cstr = howl_get_session(cid) else { return nil }
            defer { howl_free_string(cstr) }
            return String(cString: cstr)
        }
    }

    public func sessionDelete(_ id: String) -> Int32 {
        return id.withCString { cid in howl_delete_session(cid) }
    }

    public func sessionsClear() -> Int32 {
        return howl_clear_sessions()
    }

    public func presetsListJSON() -> String? {
        guard let cstr = howl_list_presets() else { return nil }
        defer { howl_free_string(cstr) }
        return String(cString: cstr)
    }

    public func presetGetJSON(_ name: String) -> String? {
        return name.withCString { cn -> String? in
            guard let cstr = howl_get_preset(cn) else { return nil }
            defer { howl_free_string(cstr) }
            return String(cString: cstr)
        }
    }

    public func presetSaveJSON(name: String, description: String, body: String) -> Int32 {
        return name.withCString { cn in
            description.withCString { cd in
                body.withCString { cb in
                    howl_save_preset(cn, cd, cb)
                }
            }
        }
    }

    public func presetDelete(_ name: String) -> Int32 {
        return name.withCString { cn in howl_delete_preset(cn) }
    }

    public func replayJSON(sourceID: String, presetsCSV: String) -> String? {
        return sourceID.withCString { csid -> String? in
            presetsCSV.withCString { ccsv -> String? in
                guard let cstr = howl_replay(csid, ccsv) else { return nil }
                defer { howl_free_string(cstr) }
                return String(cString: cstr)
            }
        }
    }

    public func tseExtractFile(inputPath: String, outputPath: String, modelsDir: String, voiceDir: String, onnxLibPath: String) -> Int32 {
        return inputPath.withCString { cIn in
            outputPath.withCString { cOut in
                modelsDir.withCString { cModels in
                    voiceDir.withCString { cVoice in
                        onnxLibPath.withCString { cLib in
                            howl_tse_extract_file(
                                UnsafeMutablePointer(mutating: cIn),
                                UnsafeMutablePointer(mutating: cOut),
                                UnsafeMutablePointer(mutating: cModels),
                                UnsafeMutablePointer(mutating: cVoice),
                                UnsafeMutablePointer(mutating: cLib)
                            )
                        }
                    }
                }
            }
        }
    }

    private nonisolated func readLastError() -> String? {
        guard let cstr = howl_last_error() else { return nil }
        defer { howl_free_string(cstr) }
        return String(cString: cstr)
    }

    // Dedicated queue for the blocking `howl_extract_keywords` C call.
    // See extractScreenKeywords's doc comment for why this bypasses the
    // actor's serialized executor.
    private static let screenContextQueue = DispatchQueue(
        label: "com.howl.app.screencontext-extract", qos: .userInitiated
    )

    /// `nonisolated`, unlike every other C call on this actor. The Go
    /// export is explicitly documented as blocking on a network call
    /// bounded by `screenctx.ExtractTimeout` (5s) and as NOT touching
    /// engine state — see `core/cmd/libhowl/screenctx_export.go`'s doc
    /// comment on `howl_extract_keywords`: "BLOCKING... Callers MUST
    /// invoke it off the main thread... does not hold e.mu across the
    /// network call." That contract is exactly what makes it safe to
    /// exempt from this type's normal "all C calls go through the
    /// actor's serialized executor" invariant (see the type header
    /// comment): nothing here can race with another engine call.
    ///
    /// `nonisolated` alone would still park a Swift-concurrency
    /// cooperative-pool thread for up to 5s (that pool is small and
    /// shared across the whole process), which is its own hazard, so
    /// the actual blocking call runs on a dedicated background
    /// `DispatchQueue` instead, resumed via a continuation. This keeps
    /// `startCapture()` (and everything else on the actor) from ever
    /// waiting behind an in-flight extraction.
    public nonisolated func extractScreenKeywords(text: String) async -> ScreenKeywordExtraction? {
        struct Request: Encodable { let text: String }
        struct DroppedWire: Decodable { let term: String; let reason: String }
        struct Response: Decodable {
            let raw: String?
            let keywords: [String]?
            let dropped: [DroppedWire]?
            let error: String?
        }
        guard let json = try? JSONEncoder().encode(Request(text: text)),
              let jsonString = String(data: json, encoding: .utf8) else { return nil }

        let raw: String? = await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            LibhowlEngine.screenContextQueue.async {
                let result = jsonString.withCString { cstr -> String? in
                    guard let out = howl_extract_keywords(UnsafeMutablePointer(mutating: cstr)) else { return nil }
                    defer { howl_free_string(out) }
                    return String(cString: out)
                }
                continuation.resume(returning: result)
            }
        }

        guard let raw,
              let data = raw.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(Response.self, from: data) else { return nil }
        // A non-nil `error` is a FAILURE signal (provider/network
        // problem), not "no keywords found" — the caller must treat
        // this as nil, not an empty extraction. Never log `decoded.error`
        // itself: it can embed an arbitrary HTTP response body from the
        // LLM provider (core/internal/llm/ollama.go:219, openai.go:307,
        // lmstudio.go:110). On this failure path there is no diagnostic
        // payload at all (the Go side returns only `{"error": "..."}"`),
        // so `raw`/`dropped` are never fabricated here.
        if decoded.error != nil { return nil }
        return ScreenKeywordExtraction(
            raw: decoded.raw ?? "",
            keywords: decoded.keywords ?? [],
            dropped: (decoded.dropped ?? []).map { ScreenContextDroppedTerm(term: $0.term, reason: $0.reason) }
        )
    }

    public func setScreenKeywords(_ keywords: [String]) async {
        struct Request: Encodable { let keywords: [String] }
        guard let json = try? JSONEncoder().encode(Request(keywords: keywords)),
              let jsonString = String(data: json, encoding: .utf8) else { return }
        _ = jsonString.withCString { cstr in
            howl_set_screen_keywords(UnsafeMutablePointer(mutating: cstr))
        }
    }

    /// `nonisolated`, for the same reason as `extractScreenKeywords`
    /// above, and routed through the same dedicated
    /// `screenContextQueue` for consistency even though
    /// `howl_screen_context_preview` is documented as instant and
    /// network-free: keeping every screen-context C call off the
    /// actor's serialized executor means none of them can ever queue
    /// behind (or make `startCapture()` queue behind) a slow one.
    public nonisolated func screenContextPreview() async -> ScreenContextPreview? {
        let raw: String? = await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            LibhowlEngine.screenContextQueue.async {
                guard let out = howl_screen_context_preview() else {
                    continuation.resume(returning: nil)
                    return
                }
                defer { howl_free_string(out) }
                continuation.resume(returning: String(cString: out))
            }
        }
        guard let raw, let data = raw.data(using: .utf8) else { return nil }
        // A failure response is `{"error": "..."}"`, which simply
        // doesn't decode against `ScreenContextPreview`'s required
        // fields — `try?` turns that into nil, matching "degrades
        // silently" rather than needing a second decode attempt to
        // detect it.
        return try? JSONDecoder().decode(ScreenContextPreview.self, from: data)
    }
}
