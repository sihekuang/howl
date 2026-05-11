// mac/Howl/UI/Settings/Pipeline/CompareSourceLoader.swift
import Foundation
import HowlCore

/// App-target convenience: build the session.json URL for a replay
/// session and delegate to HowlCore's CompareSourceLoader.
/// Lives here because it depends on SessionPaths (app target).
extension CompareSourceLoader {
    /// Load the replay session's manifest at
    /// <base>/<sourceID>/replay-<presetName>/session.json. Returns nil
    /// when the file isn't present (replay wasn't run yet, or the
    /// folder was cleared) or its JSON is invalid.
    static func loadReplayManifest(sourceID: String, presetName: String) -> SessionManifest? {
        let url = SessionPaths.dir(for: sourceID)
            .appendingPathComponent("replay-\(presetName)")
            .appendingPathComponent("session.json")
        return loadFrom(url: url)
    }
}
