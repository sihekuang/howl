import HowlCore
import SwiftUI

/// Screen-context controls: the master toggle and the per-app denylist.
///
/// Rendered directly inside `GeneralTab`'s `SettingsPane` — a plain
/// `VStack`, not a `Form`/`List` (see `SettingsComponents.swift`) — so
/// this deliberately follows the same pattern every other pane uses
/// (`VoiceTab`, `DictionaryTab`): a `SettingsGroupHeader` in place of a
/// SwiftUI `Section` header (which SwiftUI only actually draws inside a
/// `List`/`Form` — the container draws it, and `SettingsPane` doesn't),
/// and plain `HStack`/`Text` rows in place of `LabeledContent` (which
/// `HotkeyTab.permissionRow`'s doc comment notes "only laid out cleanly
/// inside a `Form { … }.formStyle(.grouped)` container").
struct ScreenContextSection: View {
    @Binding var enabled: Bool
    @Binding var denylist: [String]
    let engine: any CoreEngine
    var activityStore: ScreenContextActivityStore

    var body: some View {
        Group {
            // No group header: this now lives on its own settings
            // page, whose title already reads "Screen Context".
            Toggle("Use what's on screen to improve recognition", isOn: $enabled)
            // This paragraph is a privacy disclosure, not marketing
            // copy: it is the only place the user is told that a
            // picture of their focused window leaves the machine. Keep
            // it accurate if the capture path changes again.
            Text("""
                 Howl takes a screenshot of your focused window and sends it to your \
                 configured LLM provider, which reads it for names and jargon that bias \
                 Whisper toward the right spellings. This needs Screen Recording \
                 permission. Providers whose model can't read images fall back to the \
                 window's accessibility text instead. Password managers are never \
                 captured or read.
                 """)
                .font(.caption)
                .foregroundStyle(.secondary)

            if enabled {
                ScreenContextDenylistEditor(denylist: $denylist)

                Divider().padding(.vertical, 4)
                ScreenContextInspectorView(engine: engine, activityStore: activityStore)
            }
        }
    }
}
