// mac/Howl/UI/Settings/Pipeline/DeletePresetConfirmSheet.swift
import SwiftUI

/// Modal sheet shown before deleting a user preset. Mirrors
/// `OverwriteConfirmSheet`'s shape: Cancel left, destructive on the
/// right.
struct DeletePresetConfirmSheet: View {
    let presetName: String
    let deleting: Bool
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Delete '\(presetName)'?").font(.headline)
            Text("This permanently removes the saved preset from disk.")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                Button("Cancel", role: .cancel) { onCancel() }
                Spacer()
                Button(role: .destructive) {
                    onConfirm()
                } label: {
                    Text(deleting ? "Deleting…" : "Delete")
                }
                .keyboardShortcut(.defaultAction)
                .disabled(deleting)
            }
        }
        .padding(16)
        .frame(width: 360)
    }
}
