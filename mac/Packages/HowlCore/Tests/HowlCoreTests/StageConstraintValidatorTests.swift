import Foundation
import Testing
@testable import HowlCore

@Suite("StageConstraintValidator")
struct StageConstraintValidatorTests {
    @Test func defaultOrderingIsValid() {
        let stages = [
            Preset.StageSpec(name: "denoise",   enabled: true),
            Preset.StageSpec(name: "decimate3", enabled: true),
        ]
        let errs = StageConstraintValidator.validate(frameStages: stages)
        #expect(errs.isEmpty)
    }

    @Test func decimateBeforeDenoiseIsInvalid() {
        // decimate3 outputs 16k; denoise expects 48k. Order matters.
        let stages = [
            Preset.StageSpec(name: "decimate3", enabled: true),
            Preset.StageSpec(name: "denoise",   enabled: true),
        ]
        let errs = StageConstraintValidator.validate(frameStages: stages)
        #expect(errs.count == 1)
        #expect(errs[0].index == 1)
        #expect(errs[0].message.contains("denoise") && errs[0].message.contains("48"))
    }

    @Test func disabledStagesAreSkippedForValidation() {
        // A disabled decimate3 doesn't change the running rate — denoise
        // after it is fine.
        let stages = [
            Preset.StageSpec(name: "decimate3", enabled: false),
            Preset.StageSpec(name: "denoise",   enabled: true),
        ]
        let errs = StageConstraintValidator.validate(frameStages: stages)
        #expect(errs.isEmpty)
    }

    @Test func unknownStageIsValidByDefault() {
        // A stage we don't have rate metadata for is treated as
        // sample-rate-preserving (input rate == output rate).
        let stages = [
            Preset.StageSpec(name: "futurestage", enabled: true),
            Preset.StageSpec(name: "denoise",     enabled: true),
        ]
        let errs = StageConstraintValidator.validate(frameStages: stages)
        #expect(errs.isEmpty)
    }
}
