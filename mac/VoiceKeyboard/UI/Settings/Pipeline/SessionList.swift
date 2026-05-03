// mac/VoiceKeyboard/UI/Settings/Pipeline/SessionList.swift
import SwiftUI
import VoiceKeyboardCore
#if canImport(AppKit)
import AppKit
#endif

/// Vertical sidebar of captured sessions. Rows show a relative
/// timestamp, the originating preset, and a preview snippet of the
/// cleaned transcript. The header has a manual refresh button + a
/// "refreshed Xm ago" caption so stale data is visible. The footer
/// has Reveal-in-Finder + Clear-all.
///
/// Selection is bound externally so PlaygroundTab (or InspectorView)
/// can render the matching SessionDetail next to it.
struct SessionList: View {
    let sessions: any SessionsClient
    @Binding var selectedID: String?

    @State private var sessionList: [SessionManifest] = []
    @State private var loadError: String? = nil
    @State private var clearConfirmShown = false
    @State private var lastRefreshedAt: Date = .distantPast

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            list
            Divider()
            footer
        }
        .task { await refresh() }
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("SESSIONS").font(.caption2).bold().foregroundStyle(.secondary)
                Text(headerCaption).font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
            Button {
                Task { await refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Refresh session list")
        }
        .padding(8)
    }

    private var headerCaption: String {
        let count = sessionList.count
        let countLabel = "\(count) captured"
        if lastRefreshedAt == .distantPast { return countLabel }
        return "\(countLabel) · refreshed \(RelativeTime.string(now: Date(), then: lastRefreshedAt))"
    }

    // MARK: - List

    @ViewBuilder
    private var list: some View {
        if let err = loadError {
            Text(err).font(.caption).foregroundStyle(.red).padding(8)
        } else if sessionList.isEmpty {
            Text("No sessions captured yet. Dictate something with Developer mode on, then click ↻.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(8)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(sessionList) { s in
                        SessionRow(
                            manifest: s,
                            isSelected: selectedID == s.id,
                            onTap: { selectedID = s.id }
                        )
                        Divider()
                    }
                }
            }
        }
    }

    // MARK: - Footer

    @ViewBuilder
    private var footer: some View {
        HStack {
            Button {
                if let id = selectedID { revealInFinder(id) }
            } label: {
                Label("Reveal", systemImage: "folder")
            }
            .controlSize(.small)
            .disabled(selectedID == nil)

            Spacer()

            Button(role: .destructive) {
                clearConfirmShown = true
            } label: {
                Label("Clear all", systemImage: "trash")
            }
            .controlSize(.small)
            .disabled(sessionList.isEmpty)
        }
        .padding(8)
        .alert("Clear all sessions?", isPresented: $clearConfirmShown) {
            Button("Clear all", role: .destructive) { Task { await clearAll() } }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This deletes every captured session under /tmp/voicekeyboard/sessions. The /tmp folder isn't user-visible storage, so this is a quick reset.")
        }
    }

    // MARK: - Actions

    private func refresh() async {
        do {
            let list = try await sessions.list()
            await MainActor.run {
                self.sessionList = list
                self.loadError = nil
                self.lastRefreshedAt = Date()
                if let id = selectedID, !list.contains(where: { $0.id == id }) {
                    selectedID = list.first?.id
                } else if selectedID == nil {
                    selectedID = list.first?.id
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
            await MainActor.run { selectedID = nil }
            await refresh()
        } catch {
            await MainActor.run { self.loadError = "Clear failed: \(error)" }
        }
    }

    private func revealInFinder(_ id: String) {
        let url = SessionPaths.dir(for: id)
        #if canImport(AppKit)
        NSWorkspace.shared.activateFileViewerSelecting([url])
        #endif
    }
}

/// One row in SessionList. Loads its own preview text once on first
/// render and caches it; the parent's selection binding drives the
/// highlighted state.
private struct SessionRow: View {
    let manifest: SessionManifest
    let isSelected: Bool
    let onTap: () -> Void

    @State private var preview: String? = nil
    @State private var previewLoaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(relativeTime).font(.caption.bold())
                Spacer()
                Text(manifest.preset.isEmpty ? "—" : manifest.preset)
                    .font(.caption2.monospaced())
                    .foregroundStyle(isSelected ? .white.opacity(0.8) : .secondary)
            }
            Text(previewText)
                .font(.callout)
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .lineLimit(2)
            Text(String(format: "%.1fs", manifest.durationSec))
                .font(.caption2)
                .foregroundStyle(isSelected ? AnyShapeStyle(Color.white.opacity(0.7)) : AnyShapeStyle(HierarchicalShapeStyle.tertiary))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Color.accentColor : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
        .task(id: manifest.id) {
            if !previewLoaded {
                preview = SessionPreview.load(in: manifest.id)
                previewLoaded = true
            }
        }
    }

    private var relativeTime: String {
        guard let d = RelativeTime.parse(manifest.id) else { return manifest.id }
        return RelativeTime.string(now: Date(), then: d)
    }

    private var previewText: String {
        if let p = preview { return "\"\(p)\"" }
        if previewLoaded { return "(no transcript)" }
        return "…"
    }
}
