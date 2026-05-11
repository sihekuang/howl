// mac/Howl/UI/Settings/Pipeline/PipelineTab.swift
import SwiftUI
import HowlCore

/// Container for the Pipeline page. Hosts a segmented control between
/// the Editor (preset picker + drag-drop graph), Compare (A/B replay
/// through N presets), and TSE Lab (run TSE on an arbitrary uploaded
/// WAV — debug aid for verifying speaker extraction works).
/// The captured-session Inspector lives under Playground so dictate
/// → refresh → review is one flow.
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
        case tseLab = "TSE Lab"
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
            case .tseLab:
                TSELabView(client: tseLabClient)
            }
        }
    }

    /// Construct the TSE Lab client lazily — it's a value type wrapping
    /// the engine + the canonical model/voice paths from AppDelegate.
    private var tseLabClient: any TSELabClient {
        LibVKBTSELabClient(
            engine: engine,
            modelsDir: ModelPaths.modelsDir,
            voiceDir: ModelPaths.voiceProfileDir,
            onnxLibPath: ModelPaths.onnxLib.path
        )
    }
}
