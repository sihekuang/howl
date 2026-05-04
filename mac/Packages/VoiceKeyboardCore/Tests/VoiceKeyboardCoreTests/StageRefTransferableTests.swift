import Foundation
import Testing
@testable import VoiceKeyboardCore

@Suite("StageRef Transferable round-trip")
struct StageRefTransferableTests {
    /// JSON+base64 round-trip mirrors the path the system uses when
    /// `.draggable(StageRef)` exports + `.dropDestination(for:)` imports.
    /// We don't go through the system pasteboard here — that's
    /// XCUITest territory — but we verify the encoder/decoder pair
    /// the ProxyRepresentation uses is lossless.
    private func roundTrip(_ ref: StageRef) throws -> StageRef {
        let data = try JSONEncoder().encode(ref)
        let s = data.base64EncodedString()
        guard let back = Data(base64Encoded: s) else {
            throw NSError(domain: "test", code: 1)
        }
        return try JSONDecoder().decode(StageRef.self, from: back)
    }

    @Test func frameLane_roundTrips() throws {
        let ref = StageRef(lane: .frame, name: "denoise")
        #expect(try roundTrip(ref) == ref)
    }

    @Test func chunkLane_roundTrips() throws {
        let ref = StageRef(lane: .chunk, name: "tse")
        #expect(try roundTrip(ref) == ref)
    }

    @Test func arbitraryName_roundTrips() throws {
        let ref = StageRef(lane: .frame, name: "user-defined-stage_42")
        #expect(try roundTrip(ref) == ref)
    }

    @Test func laneSerializesAsString() throws {
        let ref = StageRef(lane: .frame, name: "x")
        let json = try JSONEncoder().encode(ref)
        let s = String(decoding: json, as: UTF8.self)
        // Lane is a String-backed RawRepresentable enum, so it should
        // serialize as the bare string "frame", not as an int.
        #expect(s.contains("\"frame\""))
    }
}
