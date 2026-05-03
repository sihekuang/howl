// mac/VoiceKeyboard/UI/Settings/Pipeline/PipelineTab.swift
import SwiftUI
import VoiceKeyboardCore

/// Container for the Pipeline page. Hosts a segmented control between
/// the Inspector (live + captured-session view) and the Editor (preset
/// picker + per-stage detail). Slice 4 adds a Compare sub-view.
struct PipelineTab: View {
    let engine: any CoreEngine
    let sessions: any SessionsClient
    let presets: any PresetsClient

    @State private var selectedView: SubView = .inspector

    enum SubView: String, CaseIterable, Identifiable {
        case inspector = "Inspector"
        case editor = "Editor"
        var id: String { rawValue }
    }

    var body: some View {
        SettingsPane {
            Picker("", selection: $selectedView) {
                ForEach(SubView.allCases) { v in
                    Text(v.rawValue).tag(v)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.bottom, 8)

            Divider()

            switch selectedView {
            case .inspector:
                InspectorView(sessions: sessions)
            case .editor:
                EditorView(presets: presets, sessions: sessions)
            }
        }
    }
}
