import SwiftUI
import VoiceKeyboardCore

struct SettingsView: View {
    let composition: CompositionRoot
    @State private var settings: UserSettings = UserSettings()

    var body: some View {
        TabView {
            GeneralTab(settings: $settings, onSave: save, audioCapture: composition.audioCapture)
                .tabItem { Label("General", systemImage: "gearshape") }
            HotkeyTab(
                settings: $settings,
                onSave: save,
                conflictChecker: composition.conflictChecker,
                permissions: composition.permissions,
                audioCapture: composition.audioCapture
            )
                .tabItem { Label("Hotkey", systemImage: "keyboard") }
            ProviderTab(secrets: composition.secrets)
                .tabItem { Label("Provider", systemImage: "key") }
            DictionaryTab(settings: $settings, onSave: save)
                .tabItem { Label("Dictionary", systemImage: "books.vertical") }
            PlaygroundTab(
                appState: composition.appState,
                hotkey: settings.hotkey,
                coordinator: composition.coordinator
            )
                .tabItem { Label("Playground", systemImage: "waveform") }
        }
        .frame(width: 560, height: 400)
        .task {
            settings = (try? composition.settings.get()) ?? UserSettings()
        }
    }

    private func save(_ s: UserSettings) {
        try? composition.settings.set(s)
        // Fix I1: reapply config so settings changes take effect immediately.
        Task { @MainActor in
            await composition.coordinator.reapplyConfig()
        }
    }
}
