# Playground + Inspector Merge Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Merge the captured-session sidebar + detail pane (currently in `Pipeline → Inspector`) into the `Playground` tab when Developer mode is on; trim the `Pipeline` tab to just the Editor; add session-list polish (refresh button, "X min ago" timestamps, cleaned-text preview rows).

**Architecture:** Pure Mac UI refactor (no Go-side, ABI, or schema changes). Split today's `InspectorView` into reusable `SessionList` + `SessionDetail` views. New pure helpers `RelativeTime` (formats "2 min ago" / "3 hours ago") + `SessionPreview` (loads `cleaned.txt` + truncates). `PlaygroundTab` composes them via `HSplitView` when `settings.developerMode == true`; `PipelineTab` drops its segmented control.

**Tech Stack:** SwiftUI (`HSplitView`, `@Observable`), AVFoundation (existing `WAVPlayer`), Foundation (`DateFormatter`, `ISO8601DateFormatter`). No new external dependencies.

---

## File Structure

### Mac UI (new)

- `mac/Packages/VoiceKeyboardCore/Sources/VoiceKeyboardCore/Editor/RelativeTime.swift` — pure formatter: `(now: Date, then: Date) -> String`. Lives in VoiceKeyboardCore for testability.
- `mac/Packages/VoiceKeyboardCore/Tests/VoiceKeyboardCoreTests/RelativeTimeTests.swift` — covers each branch with a fixed `now`.
- `mac/VoiceKeyboard/UI/Settings/Pipeline/SessionPreview.swift` — pure helper: `load(in id: String, maxChars: Int = 80) -> String?`. App target (depends on `SessionPaths`).
- `mac/VoiceKeyboard/UI/Settings/Pipeline/SessionList.swift` — sidebar view. Sessions, refresh button, footer (Reveal/Clear). Reads `[SessionManifest]` via injected `SessionsClient`.
- `mac/VoiceKeyboard/UI/Settings/Pipeline/SessionDetail.swift` — right-pane view. Transport bar + stage rows + transcript rows. Same content as today's `InspectorView` body, lifted into its own view.

### Mac UI (modified)

- `mac/VoiceKeyboard/UI/Settings/PlaygroundTab.swift` — extends to host `SessionList` + `SessionDetail` via `HSplitView` when `developerMode` is on. Threads `SessionsClient` + reuses the existing `WAVPlayer`.
- `mac/VoiceKeyboard/UI/Settings/SettingsView.swift` — passes `SessionsClient` + `developerMode` into `PlaygroundTab`.
- `mac/VoiceKeyboard/UI/Settings/Pipeline/PipelineTab.swift` — drops the segmented control; renders `EditorView` directly.

### Mac UI (deleted)

- `mac/VoiceKeyboard/UI/Settings/Pipeline/InspectorView.swift` — content split into `SessionList` + `SessionDetail`. Deleted in the final integration task to keep intermediate commits compilable.

---

## Phase A — Pure helpers (test-first)

### Task 1: `RelativeTime` formatter

**Files:**
- Create: `mac/Packages/VoiceKeyboardCore/Sources/VoiceKeyboardCore/Editor/RelativeTime.swift`
- Create: `mac/Packages/VoiceKeyboardCore/Tests/VoiceKeyboardCoreTests/RelativeTimeTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
// mac/Packages/VoiceKeyboardCore/Tests/VoiceKeyboardCoreTests/RelativeTimeTests.swift
import Foundation
import Testing
@testable import VoiceKeyboardCore

@Suite("RelativeTime")
struct RelativeTimeTests {
    private let now = Date(timeIntervalSince1970: 1_777_900_000) // arbitrary fixed reference

    @Test func underAMinuteIsJustNow() {
        let then = now.addingTimeInterval(-30)
        #expect(RelativeTime.string(now: now, then: then) == "just now")
    }

    @Test func minutesAgo() {
        let then = now.addingTimeInterval(-5 * 60)
        #expect(RelativeTime.string(now: now, then: then) == "5 min ago")
    }

    @Test func oneMinute_singular() {
        let then = now.addingTimeInterval(-60)
        #expect(RelativeTime.string(now: now, then: then) == "1 min ago")
    }

    @Test func oneHour_singular() {
        let then = now.addingTimeInterval(-3600)
        #expect(RelativeTime.string(now: now, then: then) == "1 hour ago")
    }

    @Test func multipleHours() {
        let then = now.addingTimeInterval(-3 * 3600)
        #expect(RelativeTime.string(now: now, then: then) == "3 hours ago")
    }

    @Test func oneDay_singular() {
        let then = now.addingTimeInterval(-24 * 3600)
        #expect(RelativeTime.string(now: now, then: then) == "1 day ago")
    }

    @Test func multipleDays() {
        let then = now.addingTimeInterval(-3 * 24 * 3600)
        #expect(RelativeTime.string(now: now, then: then) == "3 days ago")
    }

    @Test func farPastFallsBackToDateStamp() {
        // 30 days ago → date stamp like "Apr 3"
        let then = now.addingTimeInterval(-30 * 24 * 3600)
        let got = RelativeTime.string(now: now, then: then)
        #expect(!got.contains("ago"))
        #expect(!got.contains("just now"))
    }

    @Test func parseISO8601_validRoundTrip() {
        let id = "2026-05-03T01:08:42.123Z"
        let got = RelativeTime.parse(id)
        #expect(got != nil)
    }

    @Test func parseISO8601_invalidReturnsNil() {
        #expect(RelativeTime.parse("not a date") == nil)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `cd mac && make test 2>&1 | grep -E 'RelativeTime|cannot find'`
Expected: errors about `RelativeTime` not found.

- [ ] **Step 3: Implement the helper**

```swift
// mac/Packages/VoiceKeyboardCore/Sources/VoiceKeyboardCore/Editor/RelativeTime.swift
import Foundation

/// Pure formatter that turns "time since X" into a human label like
/// "just now" / "5 min ago" / "3 hours ago" / "May 3". Used by the
/// session list to surface staleness at a glance.
public enum RelativeTime {
    /// Build a relative label from a known `now` and a past instant.
    /// `now` is injected for testability; production callers pass `Date()`.
    public static func string(now: Date, then: Date) -> String {
        let diff = now.timeIntervalSince(then)
        if diff < 60 { return "just now" }
        if diff < 3600 {
            let m = Int(diff / 60)
            return "\(m) min ago"
        }
        if diff < 24 * 3600 {
            let h = Int(diff / 3600)
            return "\(h) \(h == 1 ? "hour" : "hours") ago"
        }
        if diff < 7 * 24 * 3600 {
            let d = Int(diff / (24 * 3600))
            return "\(d) \(d == 1 ? "day" : "days") ago"
        }
        // Far past — fall back to a fixed date stamp.
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f.string(from: then)
    }

    /// Parse a session manifest's RFC3339 id (`2026-05-03T01:08:42.123Z`)
    /// to a Date. Returns nil for unparseable input.
    public static func parse(_ id: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: id) { return d }
        // Manifests without sub-second precision fall through to the
        // version without fractional seconds.
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: id)
    }
}
```

- [ ] **Step 4: Run tests**

Run: `cd mac && make test 2>&1 | grep -E 'RelativeTime|Test run'`
Expected: 10 RelativeTime tests pass.

- [ ] **Step 5: Commit**

```bash
git add mac/Packages/VoiceKeyboardCore/Sources/VoiceKeyboardCore/Editor/RelativeTime.swift \
        mac/Packages/VoiceKeyboardCore/Tests/VoiceKeyboardCoreTests/RelativeTimeTests.swift
git commit -m "feat(mac): RelativeTime formatter for session-list timestamps"
```

---

### Task 2: `SessionPreview` helper

**Files:**
- Create: `mac/VoiceKeyboard/UI/Settings/Pipeline/SessionPreview.swift`

`SessionPreview` lives in the app target (not VoiceKeyboardCore) because it depends on `SessionPaths`, which is also app-target. We don't unit-test it directly — its single responsibility (read file, truncate string) is exercised manually via the SessionList rows.

- [ ] **Step 1: Create the file**

```swift
// mac/VoiceKeyboard/UI/Settings/Pipeline/SessionPreview.swift
import Foundation

/// Loads the cleaned transcript for a captured session and returns the
/// first N characters so the SessionList row can show a content preview.
/// Returns nil when the file is missing/unreadable — the row should
/// render "(no transcript)" in that case.
enum SessionPreview {
    static func load(in id: String, maxChars: Int = 80) -> String? {
        let url = SessionPaths.file(in: id, rel: "cleaned.txt")
        guard let data = try? Data(contentsOf: url) else { return nil }
        let text = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return nil }
        if text.count <= maxChars { return text }
        // Unicode-aware truncation: take the first maxChars Characters,
        // append a single-char ellipsis.
        let prefix = String(text.prefix(maxChars))
        return prefix + "…"
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `cd mac && make build 2>&1 | tail -3`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add mac/VoiceKeyboard/UI/Settings/Pipeline/SessionPreview.swift mac/VoiceKeyboard.xcodeproj/project.pbxproj
git commit -m "feat(mac): SessionPreview helper for session-list content snippets"
```

---

## Phase B — Split InspectorView into SessionList + SessionDetail

The plan: copy the body of today's `InspectorView` into two new view files (`SessionList`, `SessionDetail`), keep `InspectorView` working as a thin composer that wraps the two so PipelineTab still compiles, then in Phase D delete `InspectorView` once `PlaygroundTab` consumes the parts directly.

### Task 3: `SessionList` (sidebar)

**Files:**
- Create: `mac/VoiceKeyboard/UI/Settings/Pipeline/SessionList.swift`

- [ ] **Step 1: Create the view**

```swift
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
                .foregroundStyle(isSelected ? .white.opacity(0.7) : .tertiary)
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
```

- [ ] **Step 2: Build**

Run: `cd mac && rm -rf VoiceKeyboard.xcodeproj && make project && make build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add mac/VoiceKeyboard/UI/Settings/Pipeline/SessionList.swift mac/VoiceKeyboard.xcodeproj/project.pbxproj
git commit -m "feat(mac): SessionList sidebar with refresh, preview, and relative time"
```

---

### Task 4: `SessionDetail` (right pane)

**Files:**
- Create: `mac/VoiceKeyboard/UI/Settings/Pipeline/SessionDetail.swift`

The body is lifted from today's `InspectorView.sessionDetail(_:)` + `transportBar` + `stageRow` + `transcriptRow` (PR #17 added the transport bar). No behavioral change — this task is structural so PlaygroundTab can compose it without re-importing the whole Inspector.

- [ ] **Step 1: Create the view**

```swift
// mac/VoiceKeyboard/UI/Settings/Pipeline/SessionDetail.swift
import SwiftUI
import VoiceKeyboardCore
#if canImport(AppKit)
import AppKit
#endif

/// Right pane for the selected captured session. Shows the inline
/// transport bar (from the shared WAVPlayer), per-stage rows with
/// Play/Pause buttons, and transcript rows that open externally.
///
/// The WAVPlayer is owned by the parent (PlaygroundTab) so that a
/// session selection change can stop playback before the new session
/// renders.
struct SessionDetail: View {
    let manifest: SessionManifest
    @Bindable var player: WAVPlayer

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            transportBar
            ForEach(Array(manifest.stages.enumerated()), id: \.offset) { _, stage in
                stageRow(stage)
            }
            Divider().padding(.vertical, 4)
            transcriptRow(label: "raw.txt",     rel: manifest.transcripts.raw)
            transcriptRow(label: "dict.txt",    rel: manifest.transcripts.dict)
            transcriptRow(label: "cleaned.txt", rel: manifest.transcripts.cleaned)
        }
    }

    // MARK: - Transport bar

    @ViewBuilder
    private var transportBar: some View {
        if let url = player.currentURL {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Button {
                        if player.isPlaying { player.pause() } else { player.play(url: url) }
                    } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)

                    Text(url.lastPathComponent)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Slider(
                        value: Binding(
                            get: { player.currentTime },
                            set: { player.seek(to: $0) }
                        ),
                        in: 0...max(player.duration, 0.001)
                    )
                    .controlSize(.mini)

                    Text("\(formatTime(player.currentTime)) / \(formatTime(player.duration))")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .frame(width: 80, alignment: .trailing)
                }
                if let err = player.lastError {
                    Text(err).font(.caption).foregroundStyle(.red)
                }
            }
            .padding(8)
            .background(Color.secondary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        } else if let err = player.lastError {
            Text(err).font(.caption).foregroundStyle(.red)
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func stageRow(_ stage: SessionManifest.Stage) -> some View {
        let url = SessionPaths.file(in: manifest.id, rel: stage.wav)
        let isCurrent = player.currentURL == url
        HStack {
            Text(stage.name).font(.callout).bold()
            Text("(\(stage.kind))").foregroundStyle(.secondary).font(.caption)
            if isCurrent {
                Image(systemName: player.isPlaying ? "speaker.wave.2.fill" : "speaker.fill")
                    .foregroundStyle(Color.accentColor)
                    .font(.caption)
            }
            Spacer()
            Text("\(stage.rateHz) Hz").foregroundStyle(.secondary).font(.caption.monospaced())
            if let sim = stage.tseSimilarity {
                Text("sim \(String(format: "%.2f", sim))")
                    .foregroundStyle(.secondary).font(.caption.monospaced())
            }
            Button {
                player.toggle(url: url)
            } label: {
                Label(
                    isCurrent && player.isPlaying ? "Pause" : "Play",
                    systemImage: isCurrent && player.isPlaying ? "pause" : "play"
                )
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    @ViewBuilder
    private func transcriptRow(label: String, rel: String) -> some View {
        HStack {
            Text(label).font(.caption.monospaced()).foregroundStyle(.secondary)
            Spacer()
            Button {
                openExternal(rel: rel)
            } label: { Label("Open", systemImage: "doc.text") }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private func openExternal(rel: String) {
        let url = SessionPaths.file(in: manifest.id, rel: rel)
        #if canImport(AppKit)
        NSWorkspace.shared.open(url)
        #endif
    }

    private func formatTime(_ t: TimeInterval) -> String {
        let total = Int(t.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
```

- [ ] **Step 2: Build**

Run: `cd mac && rm -rf VoiceKeyboard.xcodeproj && make project && make build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add mac/VoiceKeyboard/UI/Settings/Pipeline/SessionDetail.swift mac/VoiceKeyboard.xcodeproj/project.pbxproj
git commit -m "feat(mac): SessionDetail right-pane lifted from InspectorView"
```

---

## Phase C — Wire into PlaygroundTab

### Task 5: Extend `PlaygroundTab` to host the sidebar + detail

**Files:**
- Modify: `mac/VoiceKeyboard/UI/Settings/PlaygroundTab.swift`
- Modify: `mac/VoiceKeyboard/UI/Settings/SettingsView.swift` (thread sessions client + developerMode through)

`PlaygroundTab` gains three new properties: `developerMode: Bool`, `sessions: any SessionsClient`, and an internal `@State var player = WAVPlayer()`. When developer mode is on, the body renders an `HSplitView` with `SessionList` on the left and `(playgroundColumn / SessionDetail)` stacked on the right.

- [ ] **Step 1: Update `SettingsView.swift` to pass the new params**

In `mac/VoiceKeyboard/UI/Settings/SettingsView.swift`, find the `case .playground:` block. Replace:

```swift
        case .playground:
            PlaygroundTab(
                appState: composition.appState,
                hotkey: settings.hotkey,
                coordinator: composition.coordinator
            )
```

With:

```swift
        case .playground:
            PlaygroundTab(
                appState: composition.appState,
                hotkey: settings.hotkey,
                coordinator: composition.coordinator,
                developerMode: settings.developerMode,
                sessions: LibVKBSessionsClient(engine: composition.engine)
            )
```

- [ ] **Step 2: Rewrite `PlaygroundTab.swift`**

Replace `mac/VoiceKeyboard/UI/Settings/PlaygroundTab.swift` with:

```swift
import SwiftUI
import VoiceKeyboardCore

/// A scratch text field where the user can try the full dictation flow
/// without leaving the app, plus (when Developer mode is on) a sidebar
/// of captured sessions and a detail pane for the selected one. The
/// recording controls stay at the top of the right column so dictate →
/// refresh → review is one continuous loop.
struct PlaygroundTab: View {
    let appState: AppState
    let hotkey: VoiceKeyboardCore.KeyboardShortcut
    let coordinator: EngineCoordinator
    let developerMode: Bool
    let sessions: any SessionsClient

    @State private var scratch: String = ""
    @State private var selectedID: String? = nil
    @State private var player = WAVPlayer()
    @State private var sessionList: [SessionManifest] = []

    var body: some View {
        SettingsPane {
            if developerMode {
                HSplitView {
                    SessionList(sessions: sessions, selectedID: $selectedID)
                        .frame(idealWidth: 240, minWidth: 200)
                    rightColumn
                        .frame(minWidth: 320)
                }
            } else {
                playgroundColumn
            }
        }
        .onChange(of: selectedID) { _, _ in
            // Switching sessions invalidates the currently-loaded source.
            player.stop()
            Task { await refreshSelectedManifest() }
        }
        .task {
            if developerMode { await refreshSelectedManifest() }
        }
    }

    @ViewBuilder
    private var rightColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            playgroundColumn
            Divider()
            if let m = selectedManifest {
                SessionDetail(manifest: m, player: player)
            } else {
                Text("Select a session on the left.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var playgroundColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            statusBanner
            Text("Click into the box below, then hold \(Text(hotkey.displayString).font(.system(.body, design: .monospaced).bold())) and speak. Release to transcribe — the cleaned text appears here.")
                .font(.callout)
                .foregroundStyle(.secondary)
            TextEditor(text: $scratch)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(nsColor: .textBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(.secondary.opacity(0.3))
                )
                .frame(minHeight: developerMode ? 120 : 200)
            HStack {
                Button {
                    Task { @MainActor in
                        switch appState.engineState {
                        case .idle:
                            await coordinator.manualPress()
                        case .recording:
                            await coordinator.manualRelease()
                        case .processing:
                            break
                        }
                    }
                } label: {
                    Label(recordButtonTitle, systemImage: recordButtonIcon)
                        .frame(minWidth: 140)
                }
                .buttonStyle(.borderedProminent)
                .tint(appState.engineState == .recording ? .red : .accentColor)
                .disabled(appState.engineState == .processing)

                if appState.engineState == .recording {
                    rmsMeter
                }
                if appState.engineState != .idle {
                    Button("Reset") {
                        Task { @MainActor in await coordinator.manualReset() }
                    }
                }
                Spacer()
                Button("Clear") { scratch = "" }
                    .disabled(scratch.isEmpty)
            }
        }
    }

    @ViewBuilder
    private var statusBanner: some View {
        switch appState.engineState {
        case .idle:
            Label("Ready — hold \(hotkey.displayString) to dictate", systemImage: "mic")
                .foregroundStyle(.secondary)
        case .recording:
            Label("Listening…", systemImage: "waveform.circle.fill")
                .foregroundStyle(.red)
        case .processing:
            Label("Processing…", systemImage: "ellipsis.circle.fill")
                .foregroundStyle(.orange)
        }
    }

    private var recordButtonTitle: String {
        switch appState.engineState {
        case .idle: return "Record"
        case .recording: return "Stop"
        case .processing: return "Processing…"
        }
    }

    private var recordButtonIcon: String {
        switch appState.engineState {
        case .idle: return "mic.fill"
        case .recording: return "stop.fill"
        case .processing: return "ellipsis"
        }
    }

    private var rmsMeter: some View {
        let level = CGFloat(min(max(appState.liveRMS * 6, 0), 1))
        return HStack(spacing: 4) {
            ForEach(0..<10) { i in
                let threshold = CGFloat(i) / 10.0
                RoundedRectangle(cornerRadius: 2)
                    .fill(level > threshold ? Color.red : Color.secondary.opacity(0.25))
                    .frame(width: 6, height: 14)
            }
        }
    }

    /// Manifest for the currently-selected session. Re-fetched on every
    /// selection change so the detail pane always sees fresh data
    /// (e.g. when a recently-captured session's manifest is updated).
    private var selectedManifest: SessionManifest? {
        guard let id = selectedID else { return nil }
        return sessionList.first(where: { $0.id == id })
    }

    private func refreshSelectedManifest() async {
        do {
            let list = try await sessions.list()
            await MainActor.run { self.sessionList = list }
        } catch {
            // Swallow — SessionList shows the error in its own header.
        }
    }
}
```

- [ ] **Step 3: Build**

Run: `cd mac && rm -rf VoiceKeyboard.xcodeproj && make project && make build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Run tests**

Run: `cd mac && make test 2>&1 | tail -3`
Expected: PASS — total test count is the Slice 2 baseline (74) + Task 1's 10 RelativeTime tests = 84.

- [ ] **Step 5: Commit**

```bash
git add mac/VoiceKeyboard/UI/Settings/PlaygroundTab.swift \
        mac/VoiceKeyboard/UI/Settings/SettingsView.swift \
        mac/VoiceKeyboard.xcodeproj/project.pbxproj
git commit -m "feat(mac): PlaygroundTab hosts SessionList + SessionDetail in dev mode"
```

---

## Phase D — Trim PipelineTab + delete InspectorView

### Task 6: Drop the segmented control + delete `InspectorView`

**Files:**
- Modify: `mac/VoiceKeyboard/UI/Settings/Pipeline/PipelineTab.swift`
- Delete: `mac/VoiceKeyboard/UI/Settings/Pipeline/InspectorView.swift`

`PipelineTab` becomes a thin wrapper around `EditorView`. `InspectorView` is dead code now that `PlaygroundTab` consumes `SessionList` + `SessionDetail` directly.

- [ ] **Step 1: Rewrite `PipelineTab.swift`**

Replace `mac/VoiceKeyboard/UI/Settings/Pipeline/PipelineTab.swift` with:

```swift
// mac/VoiceKeyboard/UI/Settings/Pipeline/PipelineTab.swift
import SwiftUI
import VoiceKeyboardCore

/// Container for the Pipeline page. Hosts the preset Editor only —
/// the captured-session Inspector lives under Playground (when
/// Developer mode is on) so dictate → refresh → review is one flow.
struct PipelineTab: View {
    let engine: any CoreEngine
    let sessions: any SessionsClient
    let presets: any PresetsClient

    var body: some View {
        SettingsPane {
            EditorView(presets: presets, sessions: sessions)
        }
    }
}
```

- [ ] **Step 2: Delete `InspectorView.swift`**

Run: `rm mac/VoiceKeyboard/UI/Settings/Pipeline/InspectorView.swift`

- [ ] **Step 3: Regen project + build**

Run: `cd mac && rm -rf VoiceKeyboard.xcodeproj && make project && make build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Run tests**

Run: `cd mac && make test 2>&1 | tail -3`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add mac/VoiceKeyboard/UI/Settings/Pipeline/PipelineTab.swift \
        mac/VoiceKeyboard/UI/Settings/Pipeline/InspectorView.swift \
        mac/VoiceKeyboard.xcodeproj/project.pbxproj
git commit -m "refactor(mac): drop Pipeline → Inspector segment; delete InspectorView"
```

(`git rm` is implied by `git add` of a deleted file.)

---

## Phase E — Final integration

### Task 7: Final integration check + push to PR #17

- [ ] **Step 1: Full test suite**

Run: `cd mac && make test 2>&1 | tail -3`
Expected: PASS — tests = 74 baseline + 10 RelativeTime = ~84.

Run: `cd core && go test ./... && go test -tags=whispercpp ./cmd/libvkb/...`
Expected: PASS — no Go-side changes in this slice.

- [ ] **Step 2: Clean Debug build**

Run: `cd mac && make clean && make build 2>&1 | tail -3`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Manual smoke test**

- Toggle Developer mode OFF → open Playground → see only the scratch editor + Record button (today's behavior).
- Toggle Developer mode ON → open Playground → sidebar appears on the left with the latest session selected.
- Dictate a sentence; click ↻ in the sidebar header → new session at the top with "just now" + the cleaned-text preview.
- Click an older session → the detail pane updates; transport bar resets; the previously-selected row loses its highlight.
- Click Play on `tse.wav` in the detail pane → transport bar populates; speaker icon appears on the row; click again to pause.
- Click Reveal in Finder → the session folder opens.
- Open Pipeline tab → only the Editor renders (no segmented control).

- [ ] **Step 4: Push to PR #17**

```bash
git push origin feat/inspector-inline-playback
```

PR #17 picks up the new commits automatically. Update the PR title + body in GitHub to reflect the broader scope:

- New title: `feat(mac): Inspector overhaul — in-app playback + Playground+Inspector merge`
- Body: extend with a "Merge" section covering the new `SessionList` / `SessionDetail` / `RelativeTime` / `SessionPreview`, the `PlaygroundTab` host, and the trimmed `PipelineTab`.

```bash
gh pr edit 17 --title "feat(mac): Inspector overhaul — in-app playback + Playground+Inspector merge"
```

(Body update can be done in the GitHub UI to preserve formatting.)

---

## Summary

Total: **7 tasks across 5 phases.** Estimated ~500 LOC.

**By area:**
- Pure helpers (Tasks 1-2): ~80 LOC + tests.
- View split (Tasks 3-4): ~300 LOC (SessionList + SessionDetail).
- Integration (Task 5): ~150 LOC modified PlaygroundTab + 5 LOC SettingsView.
- Cleanup (Task 6): ~30 LOC PipelineTab + delete ~250 LOC InspectorView.
- Final integration (Task 7): zero LOC.

---

## Test plan

- [ ] `cd mac && make test` — including 10 new RelativeTime tests.
- [ ] `cd mac && make build` (clean).
- [ ] Manual smoke (see Task 7 Step 3).

---

## Self-Review

### Spec coverage

| Spec section / requirement | Implementing task |
|---|---|
| Combined Playground + sidebar + detail when Developer mode is on | Task 5 |
| Sessions sidebar (vertical list) | Task 3 |
| Refresh button (manual; no auto-poll) | Task 3 |
| Preview text (first ~80 chars of cleaned.txt) | Tasks 2, 3 |
| Relative timestamp ("X min ago") in row + header | Tasks 1, 3 |
| Detail pane lifted from InspectorView | Task 4 |
| Inline transport bar (PR #17) carries over | Task 4 |
| Playground bar above detail in right column | Task 5 |
| Casual users (Developer mode off) see no change | Task 5 (conditional `HSplitView`) |
| Pipeline tab loses Inspector half | Task 6 |
| InspectorView deleted | Task 6 |
| Sidebar width: idealWidth 240, minWidth 200 | Task 5 |
| Header caption: "12 captured · refreshed just now" | Task 3 (`headerCaption`) |
| Footer: Reveal in Finder + Clear all | Task 3 |
| Multiline scratch editor (TextEditor) | Task 5 (carried over from current PlaygroundTab) |
| RelativeTime in VoiceKeyboardCore for testability | Task 1 |
| SessionPreview in app target (depends on SessionPaths) | Task 2 |

All spec requirements mapped. No gaps found.

### Placeholder scan

No "TBD" / "implement later" / "add validation" hand-waves. Every step has either complete code or a concrete shell command with expected output.

### Type consistency

- `SessionList(sessions:selectedID:)` signature matches the call site in PlaygroundTab Task 5.
- `SessionDetail(manifest:player:)` signature matches the call site in PlaygroundTab Task 5.
- `WAVPlayer` (from PR #17) is owned by `PlaygroundTab` (`@State`) and passed as `@Bindable var` into `SessionDetail` — consistent with the `@Observable` final-class pattern WAVPlayer uses.
- `RelativeTime.string(now:then:)` + `.parse(_:)` signatures are used consistently in tests (Task 1) and SessionList SessionRow (Task 3).
- `SessionPreview.load(in:maxChars:)` signature (Task 2) matches the call site in SessionRow (Task 3).

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-05-03-playground-inspector-merge.md`. Two execution options:

**1. Subagent-Driven (recommended)** — Dispatch a fresh subagent per task, review between tasks, fast iteration.

**2. Inline Execution** — Execute tasks in this session using `superpowers:executing-plans`, batch execution with checkpoints.
