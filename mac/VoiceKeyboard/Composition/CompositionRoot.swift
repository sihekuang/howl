import Foundation
import VoiceKeyboardCore

@MainActor
public final class CompositionRoot {
    public let appState: AppState
    public let engine: any CoreEngine
    public let hotkey: any HotkeyMonitor
    public let injector: any TextInjector
    public let settings: any SettingsStore
    public let secrets: any SecretStore
    public let permissions: any AccessibilityPermissions

    public init() {
        self.appState = AppState()
        self.engine = LibvkbEngine()
        self.hotkey = CGEventHotkeyMonitor()
        self.injector = ClipboardPasteInjector(
            pasteboard: SystemPasteboard(),
            keystroke: CGEventKeystrokeSender()
        )
        self.settings = UserDefaultsSettingsStore()
        self.secrets = KeychainSecretStore()
        self.permissions = DefaultAccessibilityPermissions()
    }
}
