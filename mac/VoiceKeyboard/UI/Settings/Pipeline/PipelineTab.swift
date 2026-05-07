// mac/VoiceKeyboard/UI/Settings/Pipeline/PipelineTab.swift
import SwiftUI
import VoiceKeyboardCore

/// Container for the Pipeline page. Hosts a segmented control between
/// the Editor (preset picker + drag-drop graph) and Compare (A/B
/// replay through N presets). The captured-session Inspector lives
/// under Playground so dictate → refresh → review is one flow.
struct PipelineTab: View {
    let engine: any CoreEngine
    let sessions: any SessionsClient
    let presets: any PresetsClient
    let replay: any ReplayClient
    @Binding var settings: UserSettings
    let navigateTo: (SettingsPage) -> Void

    @State private var selectedView: SubView = .editor

    enum SubView: String, CaseIterable, Identifiable {
        case editor = "Editor"
        case compare = "Compare"
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
            case .editor:
                EditorView(
                    presets: presets,
                    sessions: sessions,
                    settings: $settings,
                    navigateTo: navigateTo
                )
            case .compare:
                CompareView(sessions: sessions, presets: presets, replay: replay)
            }
        }
    }
}
