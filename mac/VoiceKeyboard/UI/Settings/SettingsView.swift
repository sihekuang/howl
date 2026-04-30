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
                onRecordingStart: {
                    composition.coordinator.pauseHotkeyForRecording()
                },
                onRecordingEnd: {
                    Task { @MainActor in await composition.coordinator.resumeHotkeyAfterRecording() }
                },
                conflictChecker: composition.conflictChecker,
                permissions: composition.permissions,
                audioCapture: composition.audioCapture
            )
                .tabItem { Label("Hotkey", systemImage: "keyboard") }
            ProviderTab(settings: $settings, onSave: save, secrets: composition.secrets)
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
        Task { @MainActor in
            // Clear the recording pause before reapplyConfig so it restarts the hotkey.
            composition.coordinator.clearHotkeyPause()
            await composition.coordinator.reapplyConfig()
        }
    }
}
