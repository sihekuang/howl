import HowlCore
import SwiftUI

/// Screen-context controls: the master toggle and the per-app denylist.
struct ScreenContextSection: View {
    @Binding var enabled: Bool
    @Binding var denylist: [String]
    @State private var newBundleID: String = ""

    var body: some View {
        Section("Screen Context") {
            Toggle("Use on-screen text to improve recognition", isOn: $enabled)
            Text("""
                 Howl reads the text of your focused window and sends it to your \
                 configured LLM provider to pull out names and jargon, which bias \
                 Whisper toward the right spellings. Password managers are never read.
                 """)
                .font(.caption)
                .foregroundStyle(.secondary)

            if enabled {
                LabeledContent("Never read") {
                    VStack(alignment: .leading, spacing: 6) {
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
                    }
                }
            }
        }
    }
}
