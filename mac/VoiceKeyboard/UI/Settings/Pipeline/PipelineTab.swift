// mac/VoiceKeyboard/UI/Settings/Pipeline/PipelineTab.swift
import SwiftUI
import VoiceKeyboardCore

/// Container for the Pipeline page. Today: just the Inspector (Slice 1
/// foundation). Slice 2 adds an Editor sub-view; Slice 4 adds a Compare
/// sub-view. The tab will gain a top-level segmented control to switch
/// between them once there's more than one.
struct PipelineTab: View {
    let engine: any CoreEngine
    let sessions: any SessionsClient

    var body: some View {
        SettingsPane {
            InspectorView(sessions: sessions)
        }
    }
}
