import Foundation
import Observation
import HowlCore

@MainActor
@Observable
public final class AppState {
    public enum EngineState: Equatable {
        case idle
        case recording
        case processing
    }

    public enum SetupGate: Equatable {
        case ready
        case needsAccessibility
        case needsModel
        case needsAPIKey
    }

    public var engineState: EngineState = .idle
    public var setupGate: SetupGate = .ready
    public var liveRMS: Float = 0
    public var transientWarning: String?
    /// Non-nil when global hotkey registration failed and didn't recover
    /// after retries. Distinct from `transientWarning` because it must
    /// stay visible until either (a) registration eventually succeeds or
    /// (b) the user takes action — e.g. opens System Settings to verify
    /// Accessibility permission. Cleared on the next successful
    /// `composition.hotkey.start(...)`.
    public var hotkeyRegistrationError: String?

    public init() {}
}
