// mac/Packages/VoiceKeyboardCore/Sources/VoiceKeyboardCore/Editor/StageRef.swift
import Foundation
import CoreTransferable

/// Lane + stage name pair — the editor's identifier for "this stage in
/// this lane". Stage names are unique within a lane today.
///
/// Lives in VoiceKeyboardCore (not the app target) so the
/// StageDropPlanner tests + Transferable round-trip tests can reach it
/// from the SwiftPM test target.
///
/// Transferable representation uses a base64-encoded JSON string over
/// the public utf8-plain-text UTI. Custom UTTypes need an
/// `UTExportedTypeDeclarations` entry in Info.plist before the system
/// will route a drop typed `for: StageRef.self`; using a public UTI
/// avoids that registration step entirely. The encoded form
/// round-trips exactly through `JSONEncoder` / `JSONDecoder`, so
/// in-app drag-drop is lossless.
public struct StageRef: Hashable, Equatable, Codable, Transferable, Sendable {
    public enum Lane: String, Hashable, Codable, Sendable { case frame, chunk }
    public let lane: Lane
    public let name: String

    public init(lane: Lane, name: String) {
        self.lane = lane
        self.name = name
    }

    public static var transferRepresentation: some TransferRepresentation {
        ProxyRepresentation(exporting: { (ref: StageRef) -> String in
            guard let data = try? JSONEncoder().encode(ref) else { return "" }
            return data.base64EncodedString()
        }, importing: { (s: String) -> StageRef in
            guard let data = Data(base64Encoded: s) else {
                throw NSError(
                    domain: "StageRef",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "invalid base64"]
                )
            }
            return try JSONDecoder().decode(StageRef.self, from: data)
        })
    }
}
