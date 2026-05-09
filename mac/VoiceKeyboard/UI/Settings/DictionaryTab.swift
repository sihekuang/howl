import SwiftUI
import AppKit
import UniformTypeIdentifiers
import VoiceKeyboardCore

struct DictionaryTab: View {
    @Binding var settings: UserSettings
    let onSave: (UserSettings) -> Void
    @State private var newTerm: String = ""
    @State private var selectedPackID: String = OccupationPacks.all.first?.id ?? ""
    /// Transient confirmation banner — last action's outcome (preset add,
    /// import result, etc.). Surface feedback without a blocking dialog.
    @State private var banner: BannerKind? = nil
    @State private var confirmingClear = false
    @State private var pendingImport: [String]? = nil
    @State private var importChoiceVisible = false

    enum BannerKind: Equatable {
        case added(Int)
        case alreadyAdded
        case cleared(Int)
        case imported(added: Int, skipped: Int)
        case replaced(Int)
        case importFailed(String)
        case exportFailed(String)
        case exported(Int)

        var text: String {
            switch self {
            case .added(let n): return "Added \(n) term\(n == 1 ? "" : "s")"
            case .alreadyAdded: return "Already added"
            case .cleared(let n): return "Cleared \(n) term\(n == 1 ? "" : "s")"
            case .imported(let a, let s):
                return s == 0 ? "Imported \(a) term\(a == 1 ? "" : "s")"
                              : "Imported \(a) (skipped \(s) duplicate\(s == 1 ? "" : "s"))"
            case .replaced(let n): return "Replaced with \(n) term\(n == 1 ? "" : "s")"
            case .importFailed(let m): return "Import failed: \(m)"
            case .exportFailed(let m): return "Export failed: \(m)"
            case .exported(let n): return "Exported \(n) term\(n == 1 ? "" : "s")"
            }
        }

        var isError: Bool {
            switch self {
            case .importFailed, .exportFailed: return true
            default: return false
            }
        }

        var isMuted: Bool {
            self == .alreadyAdded
        }
    }

    var body: some View {
        SettingsPane {
            presetSection
            Divider()
            HStack {
                TextField("Add term", text: $newTerm)
                Button("Add") { addManualTerm() }
                    .disabled(newTerm.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            termsCard
        }
        .confirmationDialog(
            "Clear all \(settings.customDict.count) term\(settings.customDict.count == 1 ? "" : "s")?",
            isPresented: $confirmingClear,
            titleVisibility: .visible
        ) {
            Button("Clear all", role: .destructive) { clearAll() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This can't be undone. Export first if you want a backup.")
        }
        .confirmationDialog(
            "Import \(pendingImport?.count ?? 0) term\((pendingImport?.count ?? 0) == 1 ? "" : "s")",
            isPresented: $importChoiceVisible,
            titleVisibility: .visible
        ) {
            Button("Replace existing list") { applyImport(replace: true) }
            Button("Merge into existing list") { applyImport(replace: false) }
            Button("Cancel", role: .cancel) { pendingImport = nil }
        } message: {
            Text("Replace overwrites your current list. Merge appends without duplicates.")
        }
    }

    @ViewBuilder
    private var presetSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SettingsGroupHeader("Quick add from preset")
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
                if let banner {
                    Text(banner.text)
                        .font(.caption)
                        .foregroundStyle(banner.isError ? Color.red
                                       : banner.isMuted ? Color.secondary
                                       : Color.green)
                        .transition(.opacity)
                }
                Spacer()
            }
        }
    }

    /// Bordered card grouping the term list with its stats + bulk-action
    /// header (Export / Import / Clear all). The header sits on top so
    /// counts and actions are visible regardless of how long the list
    /// gets — previously these lived as a footer below the list and got
    /// pushed off-screen once the user added a 50-term preset pack.
    @ViewBuilder
    private var termsCard: some View {
        VStack(spacing: 0) {
            manageSection
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color.secondary.opacity(0.10))
            Divider()
            termsBody
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(.secondary.opacity(0.25))
        )
    }

    /// Flat row list of dictionary terms (replaces a SwiftUI `List` —
    /// nested inside the Settings ScrollView the List collapsed to a
    /// ~250pt fixed inner-scroll, hiding most entries and making users
    /// think a preset pack hadn't been added). The outer ScrollView
    /// owns scrolling now, so every row is reachable by scrolling.
    @ViewBuilder
    private var termsBody: some View {
        if settings.customDict.isEmpty {
            Text("No dictionary terms yet. Add one above or pick a preset pack.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(spacing: 0) {
                ForEach(Array(settings.customDict.enumerated()), id: \.offset) { idx, term in
                    HStack {
                        Text(term)
                        Spacer()
                        Button("Remove") {
                            settings.customDict.removeAll { $0 == term }
                            onSave(settings)
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.red)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(idx.isMultiple(of: 2) ? Color.clear : Color.secondary.opacity(0.06))
                    if idx < settings.customDict.count - 1 {
                        Divider()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var manageSection: some View {
        HStack(spacing: 12) {
            statsView
            Spacer()
            Button("Export…") { exportToFile() }
                .disabled(settings.customDict.isEmpty)
            Button("Import…") { importFromFile() }
            Button(role: .destructive) {
                confirmingClear = true
            } label: {
                Text("Clear all")
            }
            .disabled(settings.customDict.isEmpty)
        }
    }

    /// Counts what this dictionary adds to the LLM cleanup prompt. The Go
    /// side renders `strings.Join(terms, ", ")` and slots it into the
    /// prompt template (see core/internal/llm/prompt.go), so we measure
    /// the same string the model sees.
    @ViewBuilder
    private var statsView: some View {
        let s = dictStats()
        VStack(alignment: .leading, spacing: 1) {
            Text("\(s.words) word\(s.words == 1 ? "" : "s") · ~\(s.tokens) token\(s.tokens == 1 ? "" : "s")")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.primary)
            Text("Added to every cleanup request")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .help("Approximate token count of the joined dictionary as it ships to the LLM. The prompt template adds another ~60 tokens regardless. Token estimate is char-count / 4; actual cost will vary slightly with the model's tokenizer.")
    }

    private func dictStats() -> DictStats.Snapshot {
        DictStats.compute(from: settings.customDict)
    }

    // MARK: - Actions

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
        flashBanner(fresh.isEmpty ? .alreadyAdded : .added(fresh.count))
    }

    private func clearAll() {
        let n = settings.customDict.count
        settings.customDict.removeAll()
        onSave(settings)
        flashBanner(.cleared(n))
    }

    private func exportToFile() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "vkb-dictionary-\(Self.dateStamp()).json"
        panel.title = "Export dictionary"
        panel.prompt = "Export"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try JSONEncoder.pretty.encode(settings.customDict)
            try data.write(to: url, options: .atomic)
            flashBanner(.exported(settings.customDict.count))
        } catch {
            flashBanner(.exportFailed(error.localizedDescription))
        }
    }

    private func importFromFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.title = "Import dictionary"
        panel.prompt = "Import"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            let terms = try JSONDecoder().decode([String].self, from: data)
            let cleaned = terms
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard !cleaned.isEmpty else {
                flashBanner(.importFailed("file is empty"))
                return
            }
            pendingImport = cleaned
            importChoiceVisible = true
        } catch DecodingError.dataCorrupted, DecodingError.typeMismatch {
            flashBanner(.importFailed("expected a JSON array of strings"))
        } catch {
            flashBanner(.importFailed(error.localizedDescription))
        }
    }

    private func applyImport(replace: Bool) {
        guard let incoming = pendingImport else { return }
        if replace {
            // Dedupe within the incoming list itself, preserving order.
            var seen = Set<String>()
            settings.customDict = incoming.filter { seen.insert($0).inserted }
            onSave(settings)
            flashBanner(.replaced(settings.customDict.count))
        } else {
            let existing = Set(settings.customDict)
            let fresh = incoming.filter { !existing.contains($0) }
            settings.customDict.append(contentsOf: fresh)
            onSave(settings)
            flashBanner(.imported(added: fresh.count, skipped: incoming.count - fresh.count))
        }
        pendingImport = nil
    }

    // MARK: - Helpers

    private func flashBanner(_ kind: BannerKind) {
        withAnimation { banner = kind }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            withAnimation { banner = nil }
        }
    }

    private static func dateStamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }
}

private extension JSONEncoder {
    static let pretty: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
}
