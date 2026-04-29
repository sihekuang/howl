import SwiftUI
import VoiceKeyboardCore

struct SettingsView: View {
    let composition: CompositionRoot
    @State private var settings: UserSettings = UserSettings()

    var body: some View {
        TabView {
            GeneralTab(settings: $settings, onSave: save)
                .tabItem { Label("General", systemImage: "gearshape") }
            HotkeyTab(
                settings: $settings,
                onSave: save,
                conflictChecker: composition.conflictChecker,
                permissions: composition.permissions
            )
                .tabItem { Label("Hotkey", systemImage: "keyboard") }
            ProviderTab(secrets: composition.secrets)
                .tabItem { Label("Provider", systemImage: "key") }
            DictionaryTab(settings: $settings, onSave: save)
                .tabItem { Label("Dictionary", systemImage: "books.vertical") }
        }
        .frame(width: 540, height: 360)
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
