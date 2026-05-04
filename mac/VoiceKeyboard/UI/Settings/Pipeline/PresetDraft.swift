// mac/VoiceKeyboard/UI/Settings/Pipeline/PresetDraft.swift
import Foundation
import Observation
import CoreTransferable
import UniformTypeIdentifiers
import VoiceKeyboardCore

/// Observable working copy of a Preset that the Editor mutates in
/// place. Created from a bundled or user preset; serialized into a new
/// Preset for save (see toPreset(name:description:)).
///
/// The bundled source is captured separately so Reset can restore it
/// without an extra round-trip to libvkb.
@Observable
final class PresetDraft {
    /// The original preset this draft was created from. Reset copies
    /// fields back from this; isDirty compares against it.
    private(set) var source: Preset

    var frameStages: [Preset.StageSpec]
    var chunkStages: [Preset.StageSpec]
    var transcribeModelSize: String
    var llmProvider: String
    var timeoutSec: Int

    /// User's currently-selected stage in the graph, if any. Drives the
    /// detail panel. nil means no selection.
    var selectedStage: StageRef? = nil

    init(_ source: Preset) {
        self.source = source
        self.frameStages = source.frameStages
        self.chunkStages = source.chunkStages
        self.transcribeModelSize = source.transcribe.modelSize
        self.llmProvider = source.llm.provider
        self.timeoutSec = source.timeoutSec ?? 10
    }

    /// True when any draft field diverges from the source. Drives the
    /// "edited" badge in the toolbar.
    var isDirty: Bool {
        if frameStages != source.frameStages { return true }
        if chunkStages != source.chunkStages { return true }
        if transcribeModelSize != source.transcribe.modelSize { return true }
        if llmProvider != source.llm.provider { return true }
        if timeoutSec != (source.timeoutSec ?? 10) { return true }
        return false
    }

    /// Replace the source and reset all fields to it.
    func resetTo(_ preset: Preset) {
        source = preset
        frameStages = preset.frameStages
        chunkStages = preset.chunkStages
        transcribeModelSize = preset.transcribe.modelSize
        llmProvider = preset.llm.provider
        timeoutSec = preset.timeoutSec ?? 10
        selectedStage = nil
    }

    /// Serialize the draft to a Preset for save. name + description are
    /// supplied by SaveAsPresetSheet; the draft itself doesn't track them.
    func toPreset(name: String, description: String) -> Preset {
        Preset(
            name: name,
            description: description,
            frameStages: frameStages,
            chunkStages: chunkStages,
            transcribe: .init(modelSize: transcribeModelSize),
            llm: .init(provider: llmProvider),
            timeoutSec: timeoutSec
        )
    }

    // MARK: - Mutators

    /// Reorder a frame stage. Validation is performed by the caller via
    /// StageConstraintValidator before commit.
    func moveFrameStage(from source: IndexSet, to destination: Int) {
        frameStages.move(fromOffsets: source, toOffset: destination)
    }

    func moveChunkStage(from source: IndexSet, to destination: Int) {
        chunkStages.move(fromOffsets: source, toOffset: destination)
    }

    /// Toggle the enabled flag for a stage in either lane. No-op if the
    /// stage isn't found (UI shouldn't allow that, defensive).
    func setEnabled(_ enabled: Bool, for ref: StageRef) {
        switch ref.lane {
        case .frame:
            guard let idx = frameStages.firstIndex(where: { $0.name == ref.name }) else { return }
            let st = frameStages[idx]
            frameStages[idx] = Preset.StageSpec(name: st.name, enabled: enabled, backend: st.backend, threshold: st.threshold)
        case .chunk:
            guard let idx = chunkStages.firstIndex(where: { $0.name == ref.name }) else { return }
            let st = chunkStages[idx]
            chunkStages[idx] = Preset.StageSpec(name: st.name, enabled: enabled, backend: st.backend, threshold: st.threshold)
        }
    }

    func setBackend(_ backend: String, for ref: StageRef) {
        guard ref.lane == .chunk else { return }
        guard let idx = chunkStages.firstIndex(where: { $0.name == ref.name }) else { return }
        let st = chunkStages[idx]
        chunkStages[idx] = Preset.StageSpec(name: st.name, enabled: st.enabled, backend: backend, threshold: st.threshold)
    }

    func setThreshold(_ threshold: Float, for ref: StageRef) {
        guard ref.lane == .chunk else { return }
        guard let idx = chunkStages.firstIndex(where: { $0.name == ref.name }) else { return }
        let st = chunkStages[idx]
        chunkStages[idx] = Preset.StageSpec(name: st.name, enabled: st.enabled, backend: st.backend, threshold: threshold)
    }

    /// Look up a stage by ref. nil if not found.
    func stage(for ref: StageRef) -> Preset.StageSpec? {
        switch ref.lane {
        case .frame: return frameStages.first(where: { $0.name == ref.name })
        case .chunk: return chunkStages.first(where: { $0.name == ref.name })
        }
    }
}

/// Lane + stage name pair — the editor's identifier for "this stage in
/// this lane". Stage names are unique within a lane today.
struct StageRef: Hashable, Equatable, Codable, Transferable {
    enum Lane: String, Hashable, Codable { case frame, chunk }
    let lane: Lane
    let name: String

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .vkbStageRef)
    }
}

extension UTType {
    /// Custom drag-drop type for reordering pipeline stages within a
    /// lane. Anchored to the bundle id to avoid clashing with any
    /// other app's UTType registry.
    static let vkbStageRef = UTType(exportedAs: "com.voicekeyboard.stage-ref")
}
