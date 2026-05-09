// mac/VoiceKeyboard/UI/Settings/Pipeline/PresetDraft.swift
import Foundation
import Observation
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
    /// Per-preset LLM model. When the preset's source had `llm.model = nil`,
    /// the draft initializes this from the global default for the
    /// provider via LLMProviderCatalog.defaultModel(for:); save will
    /// then emit a non-nil model in the JSON.
    var llmModel: String
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
        self.llmModel = Self.resolvedLLMModel(from: source)
        self.timeoutSec = source.timeoutSec ?? 10
    }

    /// Returns the model `Preset` would resolve to at this moment: the
    /// preset's pinned `llm.model` when set, otherwise the catalog's
    /// default for the preset's provider. Centralises the fallback so
    /// `init`, `isDirty`, and `resetTo` agree on a single rule.
    private static func resolvedLLMModel(from preset: Preset) -> String {
        preset.llm.model ?? LLMProviderCatalog.defaultModel(for: preset.llm.provider)
    }

    /// True when any draft field diverges from the source. Drives the
    /// "edited" badge in the toolbar.
    var isDirty: Bool {
        if frameStages != source.frameStages { return true }
        if chunkStages != source.chunkStages { return true }
        if transcribeModelSize != source.transcribe.modelSize { return true }
        if llmProvider != source.llm.provider { return true }
        if llmModel != Self.resolvedLLMModel(from: source) { return true }
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
        llmModel = Self.resolvedLLMModel(from: preset)
        timeoutSec = preset.timeoutSec ?? 10
        selectedStage = nil
    }

    /// Re-anchor the source baseline to a freshly-saved preset, clearing
    /// the dirty state without touching any draft fields or the user's
    /// selected stage. Use this from the Save (overwrite) path: the
    /// edits the user just persisted become the new "clean" baseline.
    /// Unlike `resetTo`, this preserves `selectedStage` so the right
    /// pane keeps showing whatever was being edited.
    func markSaved(as saved: Preset) {
        source = saved
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
            llm: .init(provider: llmProvider, model: llmModel),
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
        case .terminal:
            return  // terminal stages don't have toggles
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

    /// Set the LLM provider. If the current model doesn't belong to the
    /// new provider (per LLMProviderCatalog.modelBelongs) the model is
    /// reset to that provider's default. Mirrors LLMProviderTab's
    /// provider-switch behavior so editor and tab agree.
    func setLLMProvider(_ provider: String) {
        llmProvider = provider
        if !LLMProviderCatalog.modelBelongs(llmModel, to: provider) {
            llmModel = LLMProviderCatalog.defaultModel(for: provider)
        }
    }

    func setLLMModel(_ model: String) {
        llmModel = model
    }

    /// Look up a stage by ref. nil if not found.
    func stage(for ref: StageRef) -> Preset.StageSpec? {
        switch ref.lane {
        case .frame: return frameStages.first(where: { $0.name == ref.name })
        case .chunk: return chunkStages.first(where: { $0.name == ref.name })
        case .terminal: return nil  // terminal stages don't have a StageSpec entry
        }
    }
}

// StageRef + Transferable conformance live in VoiceKeyboardCore so
// the SwiftPM test target can reach them (drag-drop logic +
// round-trip tests live alongside StageDropPlanner).
