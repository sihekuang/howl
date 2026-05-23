// mac/Howl/UI/Settings/Pipeline/ManageElsewhereButton.swift
import SwiftUI

/// Small chevron button used in the Pipeline editor's terminal-stage
/// bodies to deep-link the user to the source-of-truth Settings page
/// (General for whisper, Dictionary for dict, LLM Provider for llm).
///
/// Mirrors the visual style of PresetBanner's "Configure…" button:
/// `Label + systemImage` at small control size.
struct ManageElsewhereButton: View {
    let target: SettingsPage
    let label: String
    let navigateTo: (SettingsPage) -> Void

    var body: some View {
        Button {
            navigateTo(target)
        } label: {
            Label(label, systemImage: "arrow.up.right.square")
        }
        .controlSize(.small)
    }
}
