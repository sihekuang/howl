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
    @State private var newBundleID: String = ""

    var body: some View {
        Group {
            SettingsGroupHeader("Screen Context")
            Toggle("Use on-screen text to improve recognition", isOn: $enabled)
            Text("""
                 Howl reads the text of your focused window and sends it to your \
                 configured LLM provider to pull out names and jargon, which bias \
                 Whisper toward the right spellings. Password managers are never read.
                 """)
                .font(.caption)
                .foregroundStyle(.secondary)

            if enabled {
                Text("Never read")
                    .font(.callout)
                ForEach(denylist, id: \.self) { id in
                    HStack {
                        Text(id).font(.system(.body, design: .monospaced))
                        Spacer()
                        Button("Remove") {
                            denylist.removeAll { $0 == id }
                        }
                        .buttonStyle(.borderless)
                    }
                }
                HStack {
                    TextField("com.example.app", text: $newBundleID)
                        .textFieldStyle(.roundedBorder)
                    Button("Add") {
                        let trimmed = newBundleID.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty, !denylist.contains(trimmed) else { return }
                        denylist.append(trimmed)
                        newBundleID = ""
                    }
                    .disabled(newBundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                Divider().padding(.vertical, 4)
                ScreenContextInspectorView(engine: engine, activityStore: activityStore)
            }
        }
    }
}
