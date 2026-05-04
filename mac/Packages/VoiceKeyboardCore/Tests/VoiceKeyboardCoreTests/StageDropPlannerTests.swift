import Foundation
import Testing
@testable import VoiceKeyboardCore

@Suite("StageDropPlanner")
struct StageDropPlannerTests {
    private let denoise = Preset.StageSpec(name: "denoise", enabled: true)
    private let decimate = Preset.StageSpec(name: "decimate3", enabled: true)
    private let tse = Preset.StageSpec(name: "tse", enabled: true, backend: "ecapa")

    @Test func chunkLaneNoValidator_acceptsReorder() {
        let result = StageDropPlanner.planMove(
            in: [tse],
            sourceName: "tse",
            destName: "tse",
            validate: nil
        )
        // Self-move is a no-op refusal.
        #expect(result.accepted == false)
        #expect(result.newStages.map(\.name) == ["tse"])
        #expect(result.validationError == nil)
    }

    @Test func frameLane_invalidOrderingRefused() {
        let result = StageDropPlanner.planMove(
            in: [denoise, decimate],
            sourceName: "denoise",
            destName: "decimate3",
            validate: { StageConstraintValidator.validate(frameStages: $0) }
        )
        // Move denoise after decimate3 → denoise sees 16 kHz input, fails.
        #expect(result.accepted == false)
        #expect(result.newStages.map(\.name) == ["denoise", "decimate3"]) // unchanged
        #expect(result.validationError?.contains("denoise") == true)
        #expect(result.validationError?.contains("48000") == true)
    }

    @Test func frameLane_validReorderAccepted() {
        // Construct a 3-stage frame lane where reordering is rate-safe.
        // denoise (48→48) + a-passthrough (unknown, treated as passthrough)
        // + decimate3 (48→16). Swap positions 0 and 1: rate stays 48 throughout.
        let pass = Preset.StageSpec(name: "passthrough", enabled: true)
        let result = StageDropPlanner.planMove(
            in: [denoise, pass, decimate],
            sourceName: "passthrough",
            destName: "denoise",
            validate: { StageConstraintValidator.validate(frameStages: $0) }
        )
        #expect(result.accepted == true)
        #expect(result.newStages.map(\.name) == ["passthrough", "denoise", "decimate3"])
        #expect(result.validationError == nil)
    }

    @Test func unknownSource_refused() {
        let result = StageDropPlanner.planMove(
            in: [denoise, decimate],
            sourceName: "ghost",
            destName: "decimate3",
            validate: nil
        )
        #expect(result.accepted == false)
        #expect(result.newStages.map(\.name) == ["denoise", "decimate3"])
    }

    @Test func unknownDest_refused() {
        let result = StageDropPlanner.planMove(
            in: [denoise, decimate],
            sourceName: "denoise",
            destName: "ghost",
            validate: nil
        )
        #expect(result.accepted == false)
    }

    @Test func sameNameSourceAndDest_refused() {
        let result = StageDropPlanner.planMove(
            in: [denoise, decimate],
            sourceName: "denoise",
            destName: "denoise",
            validate: nil
        )
        #expect(result.accepted == false)
        #expect(result.newStages.map(\.name) == ["denoise", "decimate3"])
    }

    @Test func chunkLaneSwap_acceptedWithoutValidator() {
        // Two-element chunk lane simulating a future where multiple
        // chunk stages exist; verifies the planner handles size-2
        // arrays correctly.
        let alt = Preset.StageSpec(name: "alt", enabled: true)
        let result = StageDropPlanner.planMove(
            in: [tse, alt],
            sourceName: "alt",
            destName: "tse",
            validate: nil
        )
        #expect(result.accepted == true)
        #expect(result.newStages.map(\.name) == ["alt", "tse"])
    }
}
