// mac/VoiceKeyboard/UI/Settings/Pipeline/SaveAsPresetSheet.swift
import SwiftUI
import VoiceKeyboardCore

/// Modal naming sheet for saving the current pipeline configuration as
/// a user preset. Validates the name client-side; the C ABI rejects
/// invalid/reserved names with rc=5 if validation slips through.
struct SaveAsPresetSheet: View {
    let draft: PresetDraft
    let presets: any PresetsClient
    let onSaved: () -> Void
    let onCancel: () -> Void

    @State private var name: String = ""
    @State private var description: String = ""
    @State private var saveError: String? = nil
    @State private var saving = false

    private var nameValid: Bool {
        let pattern = "^[a-z0-9_-]{1,40}$"
        return name.range(of: pattern, options: .regularExpression) != nil
    }

    private var nameAvailable: Bool {
        let reserved: Set<String> = ["default", "minimal", "aggressive", "paranoid"]
        return !reserved.contains(name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Save current pipeline as preset")
                .font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                TextField("Name (lowercase letters, digits, dash, underscore)", text: $name)
                    .textFieldStyle(.roundedBorder)
                if !name.isEmpty && !nameValid {
                    Text("Name must be 1–40 chars: a-z, 0-9, dash, underscore")
                        .font(.caption).foregroundStyle(.red)
                } else if !name.isEmpty && !nameAvailable {
                    Text("\(name) is a reserved bundled preset name")
                        .font(.caption).foregroundStyle(.red)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                TextField("Description", text: $description, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...3)
            }

            if let err = saveError {
                Text(err).font(.caption).foregroundStyle(.red)
            }

            HStack {
                Button("Cancel", role: .cancel) { onCancel() }
                Spacer()
                Button("Save") {
                    Task { await save() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!nameValid || !nameAvailable || saving)
            }
        }
        .padding(16)
        .frame(width: 420)
    }

    private func save() async {
        saving = true
        defer { saving = false }
        let p = draft.toPreset(
            name: name,
            description: description.isEmpty ? "User preset" : description
        )
        do {
            try await presets.save(p)
            await MainActor.run { onSaved() }
        } catch {
            await MainActor.run { saveError = "Save failed: \(error)" }
        }
    }
}
