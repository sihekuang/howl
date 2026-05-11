import Foundation
import HowlCore

@MainActor
public final class CompositionRoot {
    public let appState: AppState
    public let engine: any CoreEngine
    public let audioCapture: any AudioCapture
    public let hotkey: any HotkeyMonitor
    public let injector: any TextInjector
    public let streamTyper: any StreamingTextInjector
    public let settings: any SettingsStore
    public let secrets: any SecretStore
    public let permissions: any AccessibilityPermissions
    public let cancelKeyMonitor: CancelKeyMonitor

    public init() {
        self.appState = AppState()
        self.engine = LibhowlEngine()
        self.audioCapture = AVAudioInputCapture()
        self.hotkey = CarbonHotkeyMonitor()
        self.injector = ClipboardPasteInjector(
            pasteboard: SystemPasteboard(),
            keystroke: CGEventKeystrokeSender()
        )
        self.streamTyper = CGEventTextTyper()
        self.settings = UserDefaultsSettingsStore()
        self.secrets = KeychainSecretStore()
        self.permissions = DefaultAccessibilityPermissions()
        let eng = self.engine
        self.cancelKeyMonitor = CancelKeyMonitor {
            eng.cancelCapture()
        }
    }

    public lazy var overlay = RecordingOverlayController(appState: appState)
    public lazy var coordinator = EngineCoordinator(composition: self)

    public lazy var conflictChecker: any SymbolicHotkeyChecker = DefaultSymbolicHotkeyChecker()
}
