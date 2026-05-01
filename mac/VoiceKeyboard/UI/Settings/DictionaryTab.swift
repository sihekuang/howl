import SwiftUI
import VoiceKeyboardCore

struct DictionaryTab: View {
    @Binding var settings: UserSettings
    let onSave: (UserSettings) -> Void
    @State private var newTerm: String = ""
    @State private var selectedPackID: String = OccupationPacks.all.first?.id ?? ""
    /// Transient confirmation banner: how many words were freshly added by
    /// the last preset import. Shown briefly so the user gets feedback
    /// without a blocking dialog.
    @State private var lastAddedCount: Int? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            presetSection
            Divider()
            HStack {
                TextField("Add term", text: $newTerm)
                Button("Add") { addManualTerm() }
                    .disabled(newTerm.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            List {
                ForEach(settings.customDict, id: \.self) { term in
                    HStack {
                        Text(term)
                        Spacer()
                        Button("Remove") {
                            settings.customDict.removeAll { $0 == term }
                            onSave(settings)
                        }
                    }
                }
            }
        }
        .padding()
    }

    @ViewBuilder
    private var presetSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Quick add from preset").font(.callout).foregroundStyle(.secondary)
            HStack {
                Picker("", selection: $selectedPackID) {
                    ForEach(OccupationPacks.all) { pack in
                        Text(pack.name).tag(pack.id)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 240)
                Button("Add") { addSelectedPack() }
                    .disabled(selectedPackID.isEmpty)
                if let n = lastAddedCount {
                    Text(n == 0 ? "Already added" : "Added \(n) term\(n == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(n == 0 ? Color.secondary : Color.green)
                        .transition(.opacity)
                }
                Spacer()
            }
        }
    }

    private func addManualTerm() {
        let t = newTerm.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, !settings.customDict.contains(t) else { return }
        settings.customDict.append(t)
        newTerm = ""
        onSave(settings)
    }

    private func addSelectedPack() {
        guard let pack = OccupationPacks.all.first(where: { $0.id == selectedPackID }) else { return }
        let existing = Set(settings.customDict)
        let fresh = pack.terms.filter { !existing.contains($0) }
        if !fresh.isEmpty {
            settings.customDict.append(contentsOf: fresh)
            onSave(settings)
        }
        withAnimation { lastAddedCount = fresh.count }
        // Clear the banner after a few seconds.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            withAnimation { lastAddedCount = nil }
        }
    }
}
