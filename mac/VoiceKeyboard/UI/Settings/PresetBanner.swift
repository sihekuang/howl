// mac/VoiceKeyboard/UI/Settings/PresetBanner.swift
import SwiftUI
import VoiceKeyboardCore

/// Read-only banner that displays the user's active preset alongside
/// a one-line summary (TSE on/threshold + Whisper model + LLM provider).
/// Used in the Playground tab. Switching the active preset is owned by
/// the General tab — this banner only shows it. A green checkmark next
/// to the name reinforces "this is what runs when you dictate."
///
/// `onChangeActive` is the deep-link target. nil hides the button (kept
/// for symmetry with the previous design; current Playground always
/// supplies one pointing at General).
struct PresetBanner: View {
    let presets: any PresetsClient
    let activePresetName: String?
    /// Called when the user clicks "Change in General…". Parent flips
    /// the Settings page to General. nil hides the button.
    let onChangeActive: (() -> Void)?

    @State private var presetList: [Preset] = []
    @State private var loadError: String? = nil

    private var activePreset: Preset? {
        guard let name = activePresetName else { return nil }
        return presetList.first(where: { $0.name == name })
    }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: "checkmark.seal.fill")
                .foregroundStyle(.green)
                .font(.callout)

            Text("Active preset")
                .font(.callout)
                .foregroundStyle(.secondary)

            if let active = activePreset {
                Text(active.isBundled ? "\(active.name) (default)" : active.name)
                    .font(.callout).bold()
                Text(summary(for: active))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .layoutPriority(-1)
            } else if let err = loadError {
                Text(err).font(.caption).foregroundStyle(.red).lineLimit(1)
            } else {
                Text(activePresetName ?? "(none)")
                    .font(.callout).bold()
            }

            Spacer()

            if let onChangeActive {
                Button {
                    onChangeActive()
                } label: {
                    Label("Change in General →", systemImage: "gearshape")
                }
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .task { await refresh() }
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
