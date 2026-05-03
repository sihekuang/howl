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

/// Thin Swift wrapper over the libvkb C ABI.
///
/// The Go core supports exactly one engine per process. LibvkbEngine
/// enforces that with actor isolation — all C calls go through the
/// actor's serialized executor since the C functions are not
/// concurrent-safe.
public actor LibvkbEngine: CoreEngine {
    public init() {}

    public func configure(_ config: EngineConfig) async throws {
        // Initialize on first configure (idempotent on the C side).
        let initRC = vkb_init()
        if initRC != 0 {
            throw LibvkbError.configureFailed("vkb_init failed: \(initRC)")
        }
        let json = try JSONEncoder().encode(config)
        guard let cString = String(data: json, encoding: .utf8) else {
            throw LibvkbError.configureFailed("could not encode config as UTF-8")
        }
        let rc = cString.withCString { ptr in
            vkb_configure(UnsafeMutablePointer(mutating: ptr))
        }
        switch rc {
        case 0: return
        case 4: throw LibvkbError.busy
        default:
            let msg = readLastError() ?? "vkb_configure rc=\(rc)"
            throw LibvkbError.configureFailed(msg)
        }
    }

    public func startCapture() async throws {
        let rc = vkb_start_capture()
        switch rc {
        case 0: return
        case 1: throw LibvkbError.notInitialized
        case 2: throw LibvkbError.busy
        default:
            let msg = readLastError() ?? "vkb_start_capture rc=\(rc)"
            throw LibvkbError.startFailed(msg)
        }
    }

    public nonisolated func pushAudio(_ samples: [Float]) throws {
        guard !samples.isEmpty else { return }
        let rc = samples.withUnsafeBufferPointer { buf -> Int32 in
            guard let base = buf.baseAddress else { return 0 }
            return vkb_push_audio(base, Int32(buf.count))
        }
        switch rc {
        case 0: return
        case 1: throw LibvkbError.notInitialized
        case 2: throw LibvkbError.pushFailed("no capture in flight")
        default:
            throw LibvkbError.pushFailed("vkb_push_audio rc=\(rc)")
        }
    }

    public func stopCapture() async throws {
        let rc = vkb_stop_capture()
        if rc != 0 {
            let msg = readLastError() ?? "vkb_stop_capture rc=\(rc)"
            throw LibvkbError.stopFailed(msg)
        }
    }

    public nonisolated func cancelCapture() {
        vkb_cancel_capture()
    }

    public nonisolated func pollEvent() -> EngineEvent? {
        guard let cstr = vkb_poll_event() else { return nil }
        defer { vkb_free_string(cstr) }
        let json = String(cString: cstr)
        return try? JSONDecoder().decode(EngineEvent.self, from: Data(json.utf8))
    }

    public nonisolated func lastError() -> String? {
        readLastError()
    }

    public nonisolated func shutdown() {
        vkb_destroy()
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
                return vkb_enroll_compute(base, Int32(sampleBuf.count), Int32(sampleRate), dirCStr)
            }
        }

        switch rc {
        case 0: return
        case 1: throw LibvkbError.notInitialized
        case 5:
            let msg = readLastError() ?? "vkb_enroll_compute: invalid argument"
            throw LibvkbError.enrollInvalidArgument(msg)
        default:
            let msg = readLastError() ?? "vkb_enroll_compute rc=\(rc)"
            throw LibvkbError.enrollFailed(msg)
        }
    }

    public func sessionsListJSON() -> String? {
        guard let cstr = vkb_list_sessions() else { return nil }
        defer { vkb_free_string(cstr) }
        return String(cString: cstr)
    }

    public func sessionGetJSON(_ id: String) -> String? {
        return id.withCString { cid -> String? in
            guard let cstr = vkb_get_session(cid) else { return nil }
            defer { vkb_free_string(cstr) }
            return String(cString: cstr)
        }
    }

    public func sessionDelete(_ id: String) -> Int32 {
        return id.withCString { cid in vkb_delete_session(cid) }
    }

    public func sessionsClear() -> Int32 {
        return vkb_clear_sessions()
    }

    private nonisolated func readLastError() -> String? {
        guard let cstr = vkb_last_error() else { return nil }
        defer { vkb_free_string(cstr) }
        return String(cString: cstr)
    }
}
