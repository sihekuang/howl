// mac/Howl/UI/Settings/Pipeline/SessionPaths.swift
import Foundation

/// Resolves on-disk paths for captured pipeline sessions. Single source
/// of truth for the directory layout the libhowl capture goroutine writes
/// to; UI code should never construct these paths inline.
///
/// Today the base is hardcoded `/tmp/voicekeyboard/sessions/`. If this
/// ever becomes user-configurable, swap the base for a dependency
/// without touching call sites.
enum SessionPaths {
    static let base: URL = URL(fileURLWithPath: "/tmp/voicekeyboard/sessions")

    /// Absolute folder path for a session id.
    static func dir(for id: String) -> URL {
        base.appendingPathComponent(id)
    }

    /// Absolute path for a file inside a session folder
    /// (e.g. `denoise.wav`, `transcripts/raw.txt`).
    static func file(in id: String, rel: String) -> URL {
        dir(for: id).appendingPathComponent(rel)
    }
}
