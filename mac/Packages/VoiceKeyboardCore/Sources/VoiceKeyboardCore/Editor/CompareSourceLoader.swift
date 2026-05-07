// mac/Packages/VoiceKeyboardCore/Sources/VoiceKeyboardCore/Editor/CompareSourceLoader.swift
import Foundation

/// Reads a session's manifest off disk. Used by the Compare view's
/// right pane to render SessionDetail for a just-finished replay,
/// and by tests as a pure URL-taking entry point.
public enum CompareSourceLoader {
    /// Load a SessionManifest from an explicit session.json URL.
    /// Returns nil for missing file, unreadable file, or invalid JSON.
    public static func loadFrom(url: URL) -> SessionManifest? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SessionManifest.self, from: data)
    }
}
