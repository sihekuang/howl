// mac/Howl/UI/Settings/PresetBanner.swift
import SwiftUI
import HowlCore

/// Playground's preset row. Two responsibilities:
///   1. Display the user's active preset (set in General → Active preset)
///      with a deep-link to General for changing it.
///   2. Let the user pick a *different* preset for testing in this
///      Playground tab session. Picking does NOT change the active
///      preset — it only reconfigures the engine for the duration of
///      the Playground session. The parent reverts on tab leave by
///      calling `coordinator.reapplyConfig()`, which re-reads the
///      stored UserSettings.
struct PresetBanner: View {
    let presets: any PresetsClient
    /// The user's active preset name, sourced from UserSettings.
    /// Read-only here — change it via General.
    let activePresetName: String?
    /// Session-local override. nil = "use active". Bound to PlaygroundTab.
    @Binding var overrideName: String?
    /// Apply the picked preset to the engine without persisting. PlaygroundTab
    /// builds an override UserSettings via `settings.applying(_:)` and
    /// hands it to `coordinator.applyOverride(_:)`.
    let onApplyOverride: (Preset) -> Void
    /// Revert engine config back to the user's active preset by re-reading
    /// the persistent settings store.
    let onRevertToActive: () -> Void
    /// Deep-link to General → Active preset. nil hides the button.
    let onChangeActive: (() -> Void)?

    @State private var presetList: [Preset] = []
    @State private var loadError: String? = nil

    /// What the picker is currently bound to. Falls back to the active
    /// preset name when there's no override (so the picker shows
    /// something sensible even before the user touches it).
    private var pickerSelection: String {
        overrideName ?? activePresetName ?? ""
    }

    private var isOverriding: Bool {
        guard let override = overrideName else { return false }
        return override != activePresetName
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 8) {
                Text("Test with")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                presetPicker

                if isOverriding {
                    Button("Revert to active") {
                        overrideName = nil
                        onRevertToActive()
                    }
                    .controlSize(.small)
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
            statusLine
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .task { await refresh() }
    }

    @ViewBuilder
    private var presetPicker: some View {
        if presetList.isEmpty {
            Text(activePresetName ?? "(loading…)")
                .font(.callout).bold()
        } else {
            Picker("", selection: Binding(
                get: { pickerSelection },
                set: { name in
                    guard !name.isEmpty,
                          let p = presetList.first(where: { $0.name == name })
                    else { return }
                    if name == activePresetName {
                        overrideName = nil
                        onRevertToActive()
                    } else {
                        overrideName = name
                        onApplyOverride(p)
                    }
                }
            )) {
                if !presetList.contains(where: { $0.name == pickerSelection }), !pickerSelection.isEmpty {
                    Text(pickerSelection).tag(pickerSelection)
                }
                ForEach(presetList) { p in
                    Text(p.isBundled ? "\(p.name) (default)" : p.name).tag(p.name)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 220)
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        if let err = loadError {
            Text(err).font(.caption).foregroundStyle(.red).lineLimit(1)
        } else if isOverriding {
            Text("Override active for this Playground session — your active preset is **\(activePresetName ?? "—")**.")
                .font(.caption)
                .foregroundStyle(.orange)
        } else if let active = activePresetName {
            Text("Active preset: \(active). Switch in General to change what runs everywhere else.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Text("No active preset set. Pick one in General.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
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
