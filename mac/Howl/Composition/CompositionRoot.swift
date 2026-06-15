import Foundation
import HowlCore

@MainActor
public final class CompositionRoot {
    public let appState: AppState
    public let engine: any CoreEngine
    public let audioCapture: any AudioCapture
    public let hotkey: any HotkeyMonitor
    public let hidTrigger: any HIDTriggerMonitor
    public let hidPermission: any HIDInputMonitoringPermission
    public let injector: any TextInjector
    public let streamTyper: any StreamingTextInjector
    public let settings: any SettingsStore
    public let secrets: any SecretStore
    public let permissions: any AccessibilityPermissions
    public var cancelKeyMonitor: CancelKeyMonitor { _cancelKeyMonitor }

    public init() {
        self.appState = AppState()
        self.engine = LibhowlEngine()
        self.audioCapture = AVAudioInputCapture()
        self.hotkey = CarbonHotkeyMonitor()
        self.hidTrigger = IOHIDTriggerMonitor()
        self.hidPermission = DefaultHIDInputMonitoringPermission()
        self.injector = ClipboardPasteInjector(
            pasteboard: SystemPasteboard(),
            keystroke: CGEventKeystrokeSender()
        )
        self.streamTyper = CGEventTextTyper()
        self.settings = UserDefaultsSettingsStore()
        self.secrets = KeychainSecretStore()
        self.permissions = DefaultAccessibilityPermissions()
    }

    // The global key-down monitor fires on the main thread. Hop onto the
    // MainActor synchronously (no Task round-trip) and route to the
    // coordinator so cancel teardown — stopping capture + mic and showing
    // the "Cancelled" pill — happens the instant a key is pressed, rather
    // than waiting for the Go `cancelled` event to come back.
    private lazy var _cancelKeyMonitor: CancelKeyMonitor = CancelKeyMonitor { [weak self] in
        // assumeIsolated asserts we're already on the MainActor. Global
        // key-down monitors are delivered on the main run loop, so this holds;
        // if that contract were ever violated it traps (a deterministic crash),
        // not silent corruption. We accept that over a Task hop, which would
        // defeat the "instant synchronous cancel" goal.
        MainActor.assumeIsolated {
            guard let self else { return }
            self.coordinator.cancelFromKey()
        }
    }

    public lazy var overlay = RecordingOverlayController(appState: appState)
    public lazy var coordinator = EngineCoordinator(composition: self)

    public lazy var conflictChecker: any SymbolicHotkeyChecker = DefaultSymbolicHotkeyChecker()
}
