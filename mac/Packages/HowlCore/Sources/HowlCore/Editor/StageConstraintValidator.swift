// mac/Packages/HowlCore/Sources/HowlCore/Editor/StageConstraintValidator.swift
import Foundation

/// Pure function: validates a frame-stage ordering against the
/// sample-rate compatibility of each stage. Returns one ValidationError
/// per stage that's incompatible with the running rate when it's reached.
///
/// The running rate starts at 48000 Hz (mic input). Each enabled stage
/// either preserves the rate or transforms it to a fixed output rate.
/// Disabled stages don't change the running rate.
public enum StageConstraintValidator {
    public struct ValidationError: Equatable {
        public let index: Int       // index in the input list
        public let stageName: String
        public let expectedHz: Int  // running rate at this point
        public let acceptedHz: Int  // rate this stage requires
        public let message: String
    }

    /// Per-stage rate metadata. Stages absent from this table are
    /// treated as rate-preserving (passthrough).
    private struct StageRate {
        let acceptedHz: Int   // rate this stage requires on its input
        let outputHz: Int     // rate this stage emits (== acceptedHz for passthrough)
    }

    private static let rateTable: [String: StageRate] = [
        "denoise":   StageRate(acceptedHz: 48000, outputHz: 48000),
        "decimate3": StageRate(acceptedHz: 48000, outputHz: 16000),
    ]

    public static func validate(frameStages: [Preset.StageSpec]) -> [ValidationError] {
        var rate = 48000
        var errors: [ValidationError] = []
        for (i, stage) in frameStages.enumerated() {
            guard stage.enabled, let meta = rateTable[stage.name] else {
                // Disabled or unknown: no rate change, no validation.
                continue
            }
            if meta.acceptedHz != rate {
                errors.append(ValidationError(
                    index: i,
                    stageName: stage.name,
                    expectedHz: rate,
                    acceptedHz: meta.acceptedHz,
                    message: "\(stage.name) expects \(meta.acceptedHz) Hz; running rate at this point is \(rate) Hz"
                ))
            }
            rate = meta.outputHz
        }
        return errors
    }
}
