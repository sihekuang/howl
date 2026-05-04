// mac/VoiceKeyboard/UI/Settings/Pipeline/CompareView.swift
import SwiftUI
import VoiceKeyboardCore

/// Compare view: pick a captured session as audio source, pick N
/// presets to replay through, hit Run, see results side by side.
struct CompareView: View {
    let sessions: any SessionsClient
    let presets: any PresetsClient
    let replay: any ReplayClient

    @State private var sessionList: [SessionManifest] = []
    @State private var presetList: [Preset] = []
    @State private var selectedSourceID: String? = nil
    @State private var selectedPresetNames: Set<String> = []
    @State private var results: [ReplayResult] = []
    @State private var running = false
    @State private var loadError: String? = nil
    @State private var runError: String? = nil
    @State private var player = WAVPlayer()

    private var canRun: Bool {
        selectedSourceID != nil && !selectedPresetNames.isEmpty && !running
    }

    /// The original session's cleaned-text transcript, used as the
    /// reference for the "closest match" badge.
    private var sourceTranscript: String? {
        guard let id = selectedSourceID else { return nil }
        return SessionPreview.load(in: id, maxChars: .max)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            toolbar
            Divider()
            if let err = loadError {
                Text(err).font(.callout).foregroundStyle(.red)
            } else if results.isEmpty && runError == nil {
                Text("Pick a source session and one or more presets, then click Run.")
                    .font(.callout).foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
            if let err = runError {
                Text(err).font(.callout).foregroundStyle(.red)
            }
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(results) { r in
                        CompareCard(
                            result: r,
                            isClosestMatch: r.preset == closestMatchPreset,
                            onPlayTSE: { playTSE(for: r) }
                        )
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .task { await refresh() }
    }

    @ViewBuilder
    private var toolbar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Source:").foregroundStyle(.secondary).font(.callout)
                Picker("Source", selection: Binding(
                    get: { selectedSourceID ?? sessionList.first?.id ?? "" },
                    set: { if !$0.isEmpty { selectedSourceID = $0 } }
                )) {
                    if sessionList.isEmpty {
                        Text("(no sessions)").tag("")
                    } else {
                        ForEach(sessionList) { s in
                            Text("\(relativeTime(s.id)) · \(s.preset)").tag(s.id)
                        }
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 280)
                Spacer()
                Button {
                    Task { await runReplay() }
                } label: {
                    if running {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Run", systemImage: "play.fill")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canRun)
            }
            HStack(alignment: .center, spacing: 6) {
                Text("Presets:").foregroundStyle(.secondary).font(.callout)
                FlowLayout(spacing: 6) {
                    ForEach(presetList) { p in
                        Toggle(p.name, isOn: Binding(
                            get: { selectedPresetNames.contains(p.name) },
                            set: { on in
                                if on { selectedPresetNames.insert(p.name) }
                                else  { selectedPresetNames.remove(p.name) }
                            }
                        ))
                        .toggleStyle(.button)
                        .controlSize(.small)
                    }
                }
            }
        }
    }

    private var closestMatchPreset: String? {
        guard let ref = sourceTranscript, !results.isEmpty else { return nil }
        let scored: [(String, Int)] = results
            .compactMap { $0.error == nil ? ($0.preset, Levenshtein.distance(ref, $0.cleaned)) : nil }
        return scored.min(by: { $0.1 < $1.1 })?.0
    }

    private func relativeTime(_ id: String) -> String {
        guard let d = RelativeTime.parse(id) else { return id }
        return RelativeTime.string(now: Date(), then: d)
    }

    private func refresh() async {
        do {
            async let s = sessions.list()
            async let p = presets.list()
            self.sessionList = try await s
            self.presetList = try await p
            if selectedSourceID == nil { selectedSourceID = sessionList.first?.id }
            if selectedPresetNames.isEmpty,
               let def = presetList.first(where: { $0.name == "default" }) {
                selectedPresetNames.insert(def.name)
            }
        } catch {
            self.loadError = "Failed to load: \(error)"
        }
    }

    private func runReplay() async {
        guard let id = selectedSourceID else { return }
        running = true
        runError = nil
        let names = presetList.map(\.name).filter { selectedPresetNames.contains($0) }
        defer { running = false }
        do {
            let got = try await replay.run(sourceID: id, presets: names)
            await MainActor.run { self.results = got }
        } catch {
            await MainActor.run {
                self.runError = "Replay failed: \(error)"
                self.results = []
            }
        }
    }

    private func playTSE(for r: ReplayResult) {
        guard let dir = r.replayDir else { return }
        let url = URL(fileURLWithPath: dir).appendingPathComponent("tse.wav")
        player.toggle(url: url)
    }
}

/// Minimal flow-layout that wraps button-style toggles to multiple
/// rows when the row width is exceeded. SwiftUI's HStack doesn't wrap.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, totalWidth: CGFloat = 0
        for sub in subviews {
            let s = sub.sizeThatFits(.unspecified)
            if x + s.width > maxWidth {
                y += rowHeight + spacing
                x = 0; rowHeight = 0
            }
            x += s.width + spacing
            rowHeight = max(rowHeight, s.height)
            totalWidth = max(totalWidth, x)
        }
        return CGSize(width: totalWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = bounds.width
        var x: CGFloat = bounds.minX, y: CGFloat = bounds.minY, rowHeight: CGFloat = 0
        for sub in subviews {
            let s = sub.sizeThatFits(.unspecified)
            if x + s.width > bounds.minX + maxWidth {
                y += rowHeight + spacing
                x = bounds.minX; rowHeight = 0
            }
            sub.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: s.width, height: s.height))
            x += s.width + spacing
            rowHeight = max(rowHeight, s.height)
        }
    }
}
