// mac/Howl/UI/Settings/Pipeline/PipelineEditorState.swift
import SwiftUI

/// Session-scoped state for the Pipeline editor's preset picker.
///
/// `EditorView` is torn down and recreated as the user moves around the
/// app — switching the Editor/Compare/TSE Lab segment, navigating the
/// Settings sidebar, or reopening the Settings window all recreate it,
/// resetting any view-local `@State`. To make a manual preset choice
/// "stick" for the rest of the app run we hold the selection here
/// instead, on a single instance owned by `CompositionRoot`
/// (app-lifetime, in-memory).
///
/// `nil` means "not chosen yet" — the editor seeds it from the active
/// preset (`UserSettings.selectedPresetName`) the first time it appears.
/// Because this lives in memory only, it resets on relaunch by design:
/// every new app run re-defaults to the active preset.
@MainActor
final class PipelineEditorState: ObservableObject {
    @Published var selectedPresetName: String?
}
