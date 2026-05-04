// mac/Packages/VoiceKeyboardCore/Sources/VoiceKeyboardCore/Editor/StageRef.swift
import Foundation

/// Lane + stage name pair — the editor's identifier for "this stage in
/// this lane". Stage names are unique within a lane today.
///
/// Lives in VoiceKeyboardCore (not the app target) so internal helpers
/// + tests can reach it. Earlier slices made it Transferable for
/// drag-drop reorder; the editor is now read-only-ordering, so the
/// Transferable conformance was dropped.
public struct StageRef: Hashable, Equatable, Codable, Sendable {
    public enum Lane: String, Hashable, Codable, Sendable { case frame, chunk }
    public let lane: Lane
    public let name: String

    public init(lane: Lane, name: String) {
        self.lane = lane
        self.name = name
    }
}
