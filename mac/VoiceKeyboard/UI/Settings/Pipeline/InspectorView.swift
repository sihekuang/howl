// mac/VoiceKeyboard/UI/Settings/Pipeline/InspectorView.swift
import SwiftUI
import VoiceKeyboardCore
#if canImport(AppKit)
import AppKit
#endif

/// Slice 1 Inspector: session picker + per-row breakdown of the latest
/// captured dictation. Live status indicator + ▶ Play / 📄 View buttons
/// for each stage row. Editing the active pipeline arrives in Slice 3.
struct InspectorView: View {
    let sessions: any SessionsClient

    @State private var sessionList: [SessionManifest] = []
    @State private var selectedID: String? = nil
    @State private var loadError: String? = nil
    @State private var clearConfirmShown = false

    private var selectedSession: SessionManifest? {
        guard let id = selectedID else { return sessionList.first }
        return sessionList.first(where: { $0.id == id })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            sessionBar
            Divider()
            if let s = selectedSession {
                sessionDetail(s)
            } else if let err = loadError {
                Text(err).foregroundStyle(.red).font(.callout)
            } else {
                Text("No captured sessions yet. Dictate something with Developer mode on, then come back.")
                    .foregroundStyle(.secondary).font(.callout)
            }
        }
        .task { await refresh() }
        .alert("Clear all sessions?", isPresented: $clearConfirmShown) {
            Button("Clear all", role: .destructive) { Task { await clearAll() } }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This deletes every captured session under /tmp/voicekeyboard/sessions. The /tmp folder isn't user-visible storage, so this is a quick reset.")
        }
    }

    @ViewBuilder
    private var sessionBar: some View {
        HStack(spacing: 8) {
            Text("Session:").foregroundStyle(.secondary).font(.callout)
            Picker("Session", selection: Binding(
                get: { selectedID ?? sessionList.first?.id ?? "" },
                set: { if !$0.isEmpty { selectedID = $0 } }
            )) {
                if sessionList.isEmpty {
                    Text("(none)").tag("")
                } else {
                    ForEach(sessionList) { s in
                        Text(label(for: s)).tag(s.id)
                    }
                }
            }
            .labelsHidden()
            .frame(maxWidth: 360)

            Button {
                Task { await refresh() }
            } label: { Image(systemName: "arrow.clockwise") }
            .help("Refresh session list")

            if let s = selectedSession {
                Button {
                    revealInFinder(s)
                } label: { Image(systemName: "folder") }
                .help("Reveal in Finder")
            }

            Spacer()

            Button(role: .destructive) {
                clearConfirmShown = true
            } label: { Image(systemName: "trash") }
            .help("Clear all sessions")
            .disabled(sessionList.isEmpty)
        }
    }

    private func label(for s: SessionManifest) -> String {
        let preset = s.preset.isEmpty ? "—" : s.preset
        return "\(s.id) · \(preset) · \(String(format: "%.1fs", s.durationSec))"
    }

    @ViewBuilder
    private func sessionDetail(_ s: SessionManifest) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(s.stages.enumerated()), id: \.offset) { _, stage in
                stageRow(s, stage: stage)
            }
            Divider().padding(.vertical, 4)
            transcriptRow(label: "raw.txt",     rel: s.transcripts.raw,     in: s)
            transcriptRow(label: "dict.txt",    rel: s.transcripts.dict,    in: s)
            transcriptRow(label: "cleaned.txt", rel: s.transcripts.cleaned, in: s)
        }
    }

    @ViewBuilder
    private func stageRow(_ s: SessionManifest, stage: SessionManifest.Stage) -> some View {
        HStack {
            Text(stage.name).font(.callout).bold()
            Text("(\(stage.kind))").foregroundStyle(.secondary).font(.caption)
            Spacer()
            Text("\(stage.rateHz) Hz").foregroundStyle(.secondary).font(.caption.monospaced())
            Button {
                openInPlayer(sessionID: s.id, relPath: stage.wav)
            } label: { Label("Play", systemImage: "play") }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    @ViewBuilder
    private func transcriptRow(label: String, rel: String, in s: SessionManifest) -> some View {
        HStack {
            Text(label).font(.caption.monospaced()).foregroundStyle(.secondary)
            Spacer()
            Button {
                openInPlayer(sessionID: s.id, relPath: rel)
            } label: { Label("Open", systemImage: "doc.text") }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private func sessionURL(_ id: String, _ rel: String) -> URL {
        URL(fileURLWithPath: "/tmp/voicekeyboard/sessions/\(id)/\(rel)")
    }

    private func openInPlayer(sessionID: String, relPath: String) {
        let url = sessionURL(sessionID, relPath)
        #if canImport(AppKit)
        NSWorkspace.shared.open(url)
        #endif
    }

    private func revealInFinder(_ s: SessionManifest) {
        let url = URL(fileURLWithPath: "/tmp/voicekeyboard/sessions/\(s.id)")
        #if canImport(AppKit)
        NSWorkspace.shared.activateFileViewerSelecting([url])
        #endif
    }

    private func refresh() async {
        do {
            let list = try await sessions.list()
            await MainActor.run {
                self.sessionList = list
                self.loadError = nil
                if let id = selectedID, !list.contains(where: { $0.id == id }) {
                    selectedID = nil
                }
            }
        } catch {
            await MainActor.run {
                self.loadError = "Failed to load sessions: \(error)"
            }
        }
    }

    private func clearAll() async {
        do {
            try await sessions.clear()
            await MainActor.run {
                selectedID = nil
            }
            await refresh()
        } catch {
            await MainActor.run {
                self.loadError = "Clear failed: \(error)"
            }
        }
    }
}
