import Foundation
import Observation
import VoiceKeyboardCore

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

    public init() {}
}
