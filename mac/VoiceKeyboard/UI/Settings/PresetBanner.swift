// mac/VoiceKeyboard/UI/Settings/PresetBanner.swift
import SwiftUI
import VoiceKeyboardCore

/// Compact pipeline-preset banner used in the Playground tab. Displays
/// the active preset, a picker to switch presets, a one-line summary
/// of the resolved settings (TSE on/threshold + Whisper model + LLM
/// provider), and a "Configure…" button that deep-links into
/// Pipeline → Editor for stage-level tweaks.
///
/// The picker writes back to UserSettings via the `apply` closure so
/// switching presets actually changes the live engine config. Reuses
/// PresetsClient + Preset from VoiceKeyboardCore — no duplicate
/// preset-loading state.
struct PresetBanner: View {
    let presets: any PresetsClient
    @Binding var selectedPresetName: String?
    /// Called when the user picks a different preset. Parent translates
    /// the Preset's stage specs into UserSettings fields and saves.
    let apply: (Preset) -> Void
    /// Called when the user clicks "Configure…". Parent flips the
    /// Settings page to Pipeline → Editor.
    let onConfigure: () -> Void

    @State private var presetList: [Preset] = []
    @State private var loadError: String? = nil

    private var activePreset: Preset? {
        guard let name = selectedPresetName else { return nil }
        return presetList.first(where: { $0.name == name })
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "slider.horizontal.3")
                .foregroundStyle(.tint)
                .font(.title3)

            VStack(alignment: .leading, spacing: 1) {
                Text("PRESET").font(.caption2).bold().foregroundStyle(.secondary)
                presetPicker
            }

            if let active = activePreset {
                Divider().frame(height: 24)
                Text(summary(for: active))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else if let err = loadError {
                Text(err).font(.caption).foregroundStyle(.red).lineLimit(1)
            }

            Spacer()

            Button {
                onConfigure()
            } label: {
                Label("Configure…", systemImage: "slider.horizontal.below.rectangle")
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .task { await refresh() }
    }

    @ViewBuilder
    private var presetPicker: some View {
        if presetList.isEmpty {
            Text(selectedPresetName ?? "(loading…)")
                .font(.callout).bold()
        } else {
            Picker("", selection: Binding(
                get: { selectedPresetName ?? "" },
                set: { name in
                    guard !name.isEmpty,
                          let p = presetList.first(where: { $0.name == name })
                    else { return }
                    selectedPresetName = name
                    apply(p)
                }
            )) {
                if selectedPresetName == nil || !presetList.contains(where: { $0.name == selectedPresetName }) {
                    Text(selectedPresetName ?? "(none)").tag(selectedPresetName ?? "")
                }
                ForEach(presetList) { p in
                    Text(p.name).tag(p.name)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 200)
        }
    }

    private func summary(for p: Preset) -> String {
        var parts: [String] = []
        if let tse = p.chunkStages.first(where: { $0.name == "tse" }), tse.enabled {
            if let t = tse.threshold, t > 0 {
                parts.append(String(format: "TSE @%.2f", t))
            } else {
                parts.append("TSE")
            }
        }
        parts.append("whisper:\(p.transcribe.modelSize)")
        parts.append(p.llm.provider)
        return parts.joined(separator: " · ")
    }

    private func refresh() async {
        do {
            let list = try await presets.list()
            await MainActor.run { self.presetList = list }
        } catch {
            await MainActor.run { self.loadError = "Failed to load presets" }
        }
    }
}
