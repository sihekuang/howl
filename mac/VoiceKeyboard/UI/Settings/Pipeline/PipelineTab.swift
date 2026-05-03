// mac/VoiceKeyboard/UI/Settings/Pipeline/PipelineTab.swift
import SwiftUI
import VoiceKeyboardCore

/// Container for the Pipeline page. Hosts the preset Editor only —
/// the captured-session Inspector lives under Playground (when
/// Developer mode is on) so dictate → refresh → review is one flow.
struct PipelineTab: View {
    let engine: any CoreEngine
    let sessions: any SessionsClient
    let presets: any PresetsClient

    var body: some View {
        SettingsPane {
            EditorView(presets: presets, sessions: sessions)
        }
    }
}
