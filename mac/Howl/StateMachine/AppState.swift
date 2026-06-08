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
    /// True while the engine pipeline is being (re)built. Starts true on
    /// app launch and stays true until the initial `applyConfig` finishes
    /// loading the Whisper model — a multi-second cold start. The hotkey
    /// is already registered by then, so the menu bar and the press-time
    /// warning can tell the user "still loading" instead of pretending
    /// everything's ready and silently dropping presses.
    public var engineLoading: Bool = true
    /// True while waiting for the user to press a HID element in learn mode
    /// (Settings → Hotkey / menu bar). Drives the "press a button…" hint.
    public var hidLearning: Bool = false
    /// The currently-configured HID trigger binding, mirrored from the settings
    /// store so the UI reflects learn/clear immediately (the Settings view's
    /// own `settings` copy is otherwise stale to async learn/clear). The
    /// coordinator keeps this in sync.
    public var hidBinding: HIDBinding?

    public init() {}
}
