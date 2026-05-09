// mac/VoiceKeyboard/UI/Settings/Pipeline/OverwriteConfirmSheet.swift
import SwiftUI

/// Modal sheet shown before overwriting a user preset's saved JSON via
/// the Save button. The destructive action (Overwrite) is on the right
/// matching macOS convention for "this discards the saved version".
struct OverwriteConfirmSheet: View {
    let presetName: String
    let saving: Bool
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Overwrite '\(presetName)'?").font(.headline)
            Text("This replaces the saved preset with your current edits.")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                Button("Cancel", role: .cancel) { onCancel() }
                Spacer()
                Button(role: .destructive) {
                    onConfirm()
                } label: {
                    Text(saving ? "Saving…" : "Overwrite")
                }
                .keyboardShortcut(.defaultAction)
                .disabled(saving)
            }
        }
        .padding(16)
        .frame(width: 360)
    }
}
