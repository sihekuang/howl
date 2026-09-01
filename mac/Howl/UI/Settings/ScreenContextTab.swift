import SwiftUI
import HowlCore

/// Settings page for screen context: the toggle, its privacy
/// disclosure, the never-read list, and the activity inspector.
///
/// Split out of `GeneralTab`, which had grown to own the preset picker,
/// the microphone picker, model downloads, launch-at-login AND this.
/// Screen context earns its own page for the same reason `Dictionary`
/// has one: both are recognition-biasing features whose settings need
/// room to explain themselves, and this one carries a privacy
/// disclosure plus a multi-row inspector that reads badly wedged under
/// unrelated controls.
struct ScreenContextTab: View {
    @Binding var settings: UserSettings
    let onSave: (UserSettings) -> Void
    /// Passed through to `ScreenContextSection`'s inspector, which
    /// calls `engine.screenContextPreview()` to show the live
    /// whisper-prompt composition.
    let engine: any CoreEngine
    /// Recent screen-context activity, likewise passed through to the
    /// inspector.
    let screenContextActivity: ScreenContextActivityStore

    var body: some View {
        SettingsPane {
            ScreenContextSection(
                enabled: $settings.screenContextEnabled,
                denylist: $settings.screenContextDenylist,
                engine: engine,
                activityStore: screenContextActivity
            )
        }
        // Matches every other settings page: mutate the binding, persist
        // on change. Without this the toggle and the never-read list
        // would look editable and silently fail to save.
        .onChange(of: settings) { _, new in onSave(new) }
    }
}
