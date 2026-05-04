// mac/Packages/VoiceKeyboardCore/Sources/VoiceKeyboardCore/Editor/StageDropPlanner.swift
import Foundation

/// Pure state-machine for "drop stage X onto position of stage Y in
/// the same lane". Plans the resulting array; runs the optional
/// validator; returns whether the plan is acceptable + the new array
/// (which equals the input when refused). No SwiftUI / no draft
/// mutation — testable in isolation.
public enum StageDropPlanner {
    public struct Result: Equatable {
        public let accepted: Bool
        public let newStages: [Preset.StageSpec]
        public let validationError: String?

        public init(accepted: Bool, newStages: [Preset.StageSpec], validationError: String?) {
            self.accepted = accepted
            self.newStages = newStages
            self.validationError = validationError
        }
    }

    /// Plan a within-lane move. Caller passes the current lane array,
    /// the source + dest stage names (typed by StageRef in the UI but
    /// names suffice here), and an optional validator that returns
    /// validation errors for a candidate ordering. The validator is
    /// nil for lanes with no rate constraints (e.g. the chunk lane,
    /// which only contains tse today).
    ///
    /// Refused when:
    /// - sourceName == destName (no-op move)
    /// - either name not present
    /// - validator returns at least one error (the new array is the
    ///   refused candidate; the result's `validationError` is the
    ///   first error's message)
    public static func planMove(
        in current: [Preset.StageSpec],
        sourceName: String,
        destName: String,
        validate: (([Preset.StageSpec]) -> [StageConstraintValidator.ValidationError])?
    ) -> Result {
        guard let s = current.firstIndex(where: { $0.name == sourceName }),
              let d = current.firstIndex(where: { $0.name == destName }),
              s != d else {
            return Result(accepted: false, newStages: current, validationError: nil)
        }
        // Drop-on-row swap semantic: source and dest exchange positions.
        // Intuitive for the small lanes we have today (2-3 items each)
        // and produces a clear "the row I dropped on is where I am now"
        // mental model regardless of which direction the user dragged.
        var test = current
        test.swapAt(s, d)
        if let validate, let first = validate(test).first {
            return Result(accepted: false, newStages: current, validationError: first.message)
        }
        return Result(accepted: true, newStages: test, validationError: nil)
    }
}
