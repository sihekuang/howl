# Compare side-by-side Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Refactor `CompareView` from a horizontal-scroll of multi-preset cards into a fixed two-pane layout — source on the left, one selected preset's replay on the right — both reusing the existing `SessionDetail` component.

**Architecture:** Pure Mac UI refactor. State narrows from `selectedPresetNames: Set<String>` + `results: [ReplayResult]` to `selectedPresetName: String?` + `result: ReplayResult?` + `replayManifest: SessionManifest?`. New pure helper `CompareSourceLoader` reads the replay session's `session.json` from disk so the right pane can render `SessionDetail`. No Go-side changes, no schema changes, no new dependencies.

**Tech Stack:** SwiftUI (`HStack`, `@Bindable`), Foundation (`JSONDecoder` for the manifest read). `SessionDetail`, `WAVPlayer`, `SessionPaths`, `RelativeTime` all reused.

---

## File Structure

### New

- `mac/VoiceKeyboard/UI/Settings/Pipeline/CompareSourceLoader.swift` — pure helper that loads a replay session's manifest off disk.
- `mac/Packages/VoiceKeyboardCore/Tests/VoiceKeyboardCoreTests/CompareSourceLoaderTests.swift` — round-trip + missing-file + corrupt-JSON tests.
- `mac/VoiceKeyboard/UI/Settings/Pipeline/ComparePane.swift` — small generic wrapper view (label badge + subtitle + content), private to the Pipeline directory but in its own file for readability.

### Modified

- `mac/VoiceKeyboard/UI/Settings/Pipeline/CompareView.swift` — body rewritten. State narrows; toolbar uses single preset picker; body is `HStack { leftPane; rightPane }`; right pane has empty/running/error/loaded states. The "Source audio" disclosure from PR #26 is removed (replaced by the always-visible left pane).

### Deleted

- `mac/VoiceKeyboard/UI/Settings/Pipeline/CompareCard.swift` — no longer needed; replays render via reused `SessionDetail`.

### Stays untouched

- `mac/Packages/VoiceKeyboardCore/Sources/VoiceKeyboardCore/Editor/Levenshtein.swift` + tests — harmless and tested. The closest-match badge UI that consumed it is gone, but the helper itself stays.
- All Slice 4 Go-side: `replay` package, `vkb_replay`, `ReplayClient` bridge.

### Note on file location for `CompareSourceLoader`

The helper depends on `SessionPaths` (app target), so it goes in the app target alongside `SessionPreview.swift`. **But** its tests live in `VoiceKeyboardCoreTests` alongside the existing `RecentSimilarityProbeTests` for parity. Test reaches a temp directory directly via the helper's `loadFrom(url:)` overload — no `SessionPaths` dependency in the test path.

---

## Phase A — Pure helper

### Task 1: `CompareSourceLoader` — load a replay session's manifest

**Files:**
- Create: `mac/VoiceKeyboard/UI/Settings/Pipeline/CompareSourceLoader.swift`
- Create: `mac/Packages/VoiceKeyboardCore/Tests/VoiceKeyboardCoreTests/CompareSourceLoaderTests.swift`

The replay package writes `session.json` for each replay session at `<base>/<sourceID>/replay-<presetName>/session.json`. This helper reads that file and returns the `SessionManifest`. Returns nil for missing-file or corrupt-JSON — the right pane treats either case as "show a hint" rather than crash.

The helper exposes two entry points: `loadReplayManifest(sourceID:presetName:)` for production use (uses `SessionPaths`), and `loadFrom(url:)` for tests (skips `SessionPaths`, takes a direct URL).

- [ ] **Step 1: Write the failing tests**

```swift
// mac/Packages/VoiceKeyboardCore/Tests/VoiceKeyboardCoreTests/CompareSourceLoaderTests.swift
//
// CompareSourceLoader is in the app target (depends on SessionPaths).
// To test it from the SwiftPM test target, we test the URL-taking
// overload that lives in VoiceKeyboardCore alongside the rest of the
// session-manifest plumbing. The app-target wrapper is a one-liner
// that just builds the URL and forwards.
import Foundation
import Testing
@testable import VoiceKeyboardCore

@Suite("CompareSourceLoader")
struct CompareSourceLoaderTests {
    private func writeManifest(at url: URL, _ json: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try json.data(using: .utf8)!.write(to: url)
    }

    private let validJSON = """
    {
      "version": 1,
      "id": "2026-05-06T18:00:00Z",
      "preset": "paranoid",
      "duration_sec": 4.2,
      "stages": [
        {"name": "denoise", "kind": "frame", "wav": "denoise.wav", "rate_hz": 48000}
      ],
      "transcripts": {"raw": "raw.txt", "dict": "dict.txt", "cleaned": "cleaned.txt"}
    }
    """

    @Test func loadFrom_validJSON_returnsManifest() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vkb-test-\(UUID().uuidString)")
        let url = dir.appendingPathComponent("session.json")
        try writeManifest(at: url, validJSON)
        defer { try? FileManager.default.removeItem(at: dir) }

        let m = CompareSourceLoader.loadFrom(url: url)
        #expect(m != nil)
        #expect(m?.preset == "paranoid")
        #expect(m?.durationSec == 4.2)
        #expect(m?.stages.count == 1)
    }

    @Test func loadFrom_missingFile_returnsNil() {
        let url = URL(fileURLWithPath: "/no/such/path/session.json")
        #expect(CompareSourceLoader.loadFrom(url: url) == nil)
    }

    @Test func loadFrom_corruptJSON_returnsNil() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vkb-test-\(UUID().uuidString)")
        let url = dir.appendingPathComponent("session.json")
        try writeManifest(at: url, "{not json")
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(CompareSourceLoader.loadFrom(url: url) == nil)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `cd mac && make test 2>&1 | grep -E 'CompareSourceLoader|cannot find'`
Expected: errors about `CompareSourceLoader` not found.

- [ ] **Step 3: Implement the URL-taking helper in VoiceKeyboardCore**

Reasoning: the URL-taking entry point doesn't depend on `SessionPaths` (app target), so it can live in `VoiceKeyboardCore` and be reachable from the SwiftPM test target. The app-target wrapper just builds the URL.

Create `mac/Packages/VoiceKeyboardCore/Sources/VoiceKeyboardCore/Editor/CompareSourceLoader.swift`:

```swift
// mac/Packages/VoiceKeyboardCore/Sources/VoiceKeyboardCore/Editor/CompareSourceLoader.swift
import Foundation

/// Reads a session's manifest off disk. Used by the Compare view's
/// right pane to render SessionDetail for a just-finished replay,
/// and by tests as a pure URL-taking entry point.
public enum CompareSourceLoader {
    /// Load a SessionManifest from an explicit session.json URL.
    /// Returns nil for missing file, unreadable file, or invalid JSON.
    public static func loadFrom(url: URL) -> SessionManifest? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SessionManifest.self, from: data)
    }
}
```

- [ ] **Step 4: Run tests**

Run: `cd mac && make test 2>&1 | grep -E 'CompareSourceLoader|Test run'`
Expected: 3 new tests pass.

- [ ] **Step 5: Add the app-target convenience wrapper**

Create `mac/VoiceKeyboard/UI/Settings/Pipeline/CompareSourceLoader.swift`:

```swift
// mac/VoiceKeyboard/UI/Settings/Pipeline/CompareSourceLoader.swift
import Foundation
import VoiceKeyboardCore

/// App-target convenience: build the session.json URL for a replay
/// session and delegate to VoiceKeyboardCore's CompareSourceLoader.
/// Lives here because it depends on SessionPaths (app target).
extension CompareSourceLoader {
    /// Load the replay session's manifest at
    /// <base>/<sourceID>/replay-<presetName>/session.json. Returns nil
    /// when the file isn't present (replay wasn't run yet, or the
    /// folder was cleared) or its JSON is invalid.
    static func loadReplayManifest(sourceID: String, presetName: String) -> SessionManifest? {
        let url = SessionPaths.dir(for: sourceID)
            .appendingPathComponent("replay-\(presetName)")
            .appendingPathComponent("session.json")
        return loadFrom(url: url)
    }
}
```

- [ ] **Step 6: Build to verify**

Run: `cd mac && rm -rf VoiceKeyboard.xcodeproj && make project && make build 2>&1 | tail -3`
Expected: BUILD SUCCEEDED.

- [ ] **Step 7: Commit**

```bash
git add mac/Packages/VoiceKeyboardCore/Sources/VoiceKeyboardCore/Editor/CompareSourceLoader.swift \
        mac/Packages/VoiceKeyboardCore/Tests/VoiceKeyboardCoreTests/CompareSourceLoaderTests.swift \
        mac/VoiceKeyboard/UI/Settings/Pipeline/CompareSourceLoader.swift \
        mac/VoiceKeyboard.xcodeproj/project.pbxproj
git commit -m "feat(mac): CompareSourceLoader — read replay session manifest off disk"
```

---

## Phase B — `ComparePane` wrapper view

### Task 2: `ComparePane` — generic boxed pane with label + subtitle

**Files:**
- Create: `mac/VoiceKeyboard/UI/Settings/Pipeline/ComparePane.swift`

Small visual chrome — wraps a generic content view with a header strip (badge + subtitle) and a rounded background. Just layout; no behavior. Keeps the body of `CompareView` readable.

- [ ] **Step 1: Create the file**

```swift
// mac/VoiceKeyboard/UI/Settings/Pipeline/ComparePane.swift
import SwiftUI

/// Generic two-row pane for the Compare view: a header strip with a
/// label badge + subtitle, then the content (a SessionDetail in
/// production, but unconstrained at the type level so the pane stays
/// reusable for empty/error/running states too).
struct ComparePane<Content: View>: View {
    let label: String
    let labelColor: Color
    let subtitle: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(label)
                    .font(.caption2.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(labelColor)
                    .clipShape(Capsule())
                Text(subtitle)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Spacer()
            }
            content()
        }
        .padding(10)
        .background(Color.secondary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(.secondary.opacity(0.25), lineWidth: 1)
        )
    }
}
```

- [ ] **Step 2: Build**

Run: `cd mac && rm -rf VoiceKeyboard.xcodeproj && make project && make build 2>&1 | tail -3`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add mac/VoiceKeyboard/UI/Settings/Pipeline/ComparePane.swift mac/VoiceKeyboard.xcodeproj/project.pbxproj
git commit -m "feat(mac): ComparePane — boxed pane wrapper for Compare view"
```

---

## Phase C — Rewrite `CompareView`

### Task 3: Rewrite `CompareView` body to two-pane layout

**Files:**
- Modify: `mac/VoiceKeyboard/UI/Settings/Pipeline/CompareView.swift`

Big single edit — body, state, and toolbar all change in one shot. The old multi-preset toggles, horizontal-scroll cards, closest-match badge, and source-audio disclosure all go away in this pass.

- [ ] **Step 1: Replace `CompareView.swift` entirely**

```swift
// mac/VoiceKeyboard/UI/Settings/Pipeline/CompareView.swift
import SwiftUI
import VoiceKeyboardCore

/// Compare view: pick a captured session as the audio source, pick
/// one preset to replay it through, click Run, see source on the
/// left and the preset's replay on the right.
///
/// Both panes reuse SessionDetail (per-stage Play buttons + transport
/// bar + transcript Open buttons). Single shared WAVPlayer across both
/// panes — playing audio in one stops audio in the other.
struct CompareView: View {
    let sessions: any SessionsClient
    let presets: any PresetsClient
    let replay: any ReplayClient

    @State private var sessionList: [SessionManifest] = []
    @State private var presetList: [Preset] = []
    @State private var selectedSourceID: String? = nil
    @State private var selectedPresetName: String? = nil
    @State private var result: ReplayResult? = nil
    @State private var replayManifest: SessionManifest? = nil
    @State private var running = false
    @State private var loadError: String? = nil
    @State private var runError: String? = nil
    @State private var player = WAVPlayer()

    private var canRun: Bool {
        selectedSourceID != nil && selectedPresetName != nil && !running
    }

    private var sourceManifest: SessionManifest? {
        guard let id = selectedSourceID else { return nil }
        return sessionList.first(where: { $0.id == id })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            toolbar
            Divider()
            if let err = loadError {
                Text(err).font(.callout).foregroundStyle(.red)
            }
            HStack(alignment: .top, spacing: 10) {
                leftPane.frame(minWidth: 320, maxWidth: .infinity)
                rightPane.frame(minWidth: 320, maxWidth: .infinity)
            }
        }
        .task { await refresh() }
        .onChange(of: selectedSourceID) { _, _ in
            // Switching sources stops playback and clears the right
            // pane back to its empty state — the prior replay's
            // manifest belongs to a different source.
            player.stop()
            result = nil
            replayManifest = nil
            // Default the preset picker to the new source's preset
            // when the new source has one we recognize.
            if let sourcePreset = sourceManifest?.preset,
               presetList.contains(where: { $0.name == sourcePreset }) {
                selectedPresetName = sourcePreset
            }
        }
        .onChange(of: selectedPresetName) { _, _ in
            // Same teardown — comparing against a different preset
            // means the prior replay isn't relevant anymore.
            player.stop()
            result = nil
            replayManifest = nil
        }
    }

    // MARK: - Toolbar

    @ViewBuilder
    private var toolbar: some View {
        HStack(spacing: 10) {
            Text("Source:").foregroundStyle(.secondary).font(.callout)
            Picker("Source", selection: Binding(
                get: { selectedSourceID ?? sessionList.first?.id ?? "" },
                set: { if !$0.isEmpty { selectedSourceID = $0 } }
            )) {
                if sessionList.isEmpty {
                    Text("(no sessions)").tag("")
                } else {
                    ForEach(sessionList) { s in
                        Text("\(relativeTime(s.id)) · \(s.preset.isEmpty ? "—" : s.preset)")
                            .tag(s.id)
                    }
                }
            }
            .labelsHidden()
            .frame(maxWidth: 260)

            Text("Preset:").foregroundStyle(.secondary).font(.callout)
            Picker("Preset", selection: Binding(
                get: { selectedPresetName ?? "" },
                set: { if !$0.isEmpty { selectedPresetName = $0 } }
            )) {
                if presetList.isEmpty {
                    Text("(no presets)").tag("")
                } else {
                    ForEach(presetList) { p in
                        Text(p.name).tag(p.name)
                    }
                }
            }
            .labelsHidden()
            .frame(maxWidth: 200)

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
    }

    // MARK: - Panes

    @ViewBuilder
    private var leftPane: some View {
        if let source = sourceManifest {
            ComparePane(
                label: "ORIGINAL",
                labelColor: Color.secondary,
                subtitle: paneSubtitle(for: source)
            ) {
                SessionDetail(manifest: source, player: player)
            }
        } else {
            ComparePane(
                label: "ORIGINAL",
                labelColor: Color.secondary,
                subtitle: "(no source selected)"
            ) {
                Text("Pick a captured session above.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var rightPane: some View {
        if let replay = replayManifest, let preset = selectedPresetName {
            ComparePane(
                label: preset.uppercased(),
                labelColor: Color.accentColor,
                subtitle: paneSubtitle(for: replay)
            ) {
                SessionDetail(manifest: replay, player: player)
            }
        } else if running {
            ComparePane(
                label: (selectedPresetName ?? "PRESET").uppercased(),
                labelColor: Color.accentColor,
                subtitle: "running…"
            ) {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .padding(.vertical, 20)
            }
        } else if let err = runError {
            ComparePane(
                label: (selectedPresetName ?? "PRESET").uppercased(),
                labelColor: Color.accentColor,
                subtitle: "error"
            ) {
                Text(err).font(.callout).foregroundStyle(.red)
            }
        } else if let r = result, let errString = r.error {
            // Replay returned but this preset's run failed; surface its error.
            ComparePane(
                label: r.preset.uppercased(),
                labelColor: Color.accentColor,
                subtitle: "error"
            ) {
                Text(errString).font(.callout).foregroundStyle(.red)
            }
        } else {
            ComparePane(
                label: (selectedPresetName ?? "PRESET").uppercased(),
                labelColor: Color.accentColor.opacity(0.4),
                subtitle: "not run yet"
            ) {
                Text("Pick a preset and click Run.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Helpers

    private func paneSubtitle(for m: SessionManifest) -> String {
        let preset = m.preset.isEmpty ? "—" : m.preset
        return "\(preset) · \(String(format: "%.1fs", m.durationSec))"
    }

    private func relativeTime(_ id: String) -> String {
        guard let d = RelativeTime.parse(id) else { return id }
        return RelativeTime.string(now: Date(), then: d)
    }

    // MARK: - Actions

    private func refresh() async {
        do {
            async let s = sessions.list()
            async let p = presets.list()
            self.sessionList = try await s
            self.presetList = try await p
            if selectedSourceID == nil { selectedSourceID = sessionList.first?.id }
            if selectedPresetName == nil {
                // Default to the source's own preset if it's known,
                // else "default", else first available.
                let sourcePreset = sourceManifest?.preset ?? ""
                if presetList.contains(where: { $0.name == sourcePreset }) {
                    selectedPresetName = sourcePreset
                } else if presetList.contains(where: { $0.name == "default" }) {
                    selectedPresetName = "default"
                } else {
                    selectedPresetName = presetList.first?.name
                }
            }
        } catch {
            self.loadError = "Failed to load: \(error)"
        }
    }

    private func runReplay() async {
        guard let id = selectedSourceID, let preset = selectedPresetName else { return }
        running = true
        runError = nil
        result = nil
        replayManifest = nil
        defer { running = false }
        do {
            let got = try await replay.run(sourceID: id, presets: [preset])
            await MainActor.run {
                self.result = got.first
                self.replayManifest = CompareSourceLoader.loadReplayManifest(
                    sourceID: id,
                    presetName: preset
                )
            }
        } catch {
            await MainActor.run {
                self.runError = "Replay failed: \(error)"
            }
        }
    }
}
```

- [ ] **Step 2: Build to verify the rewrite compiles**

Run: `cd mac && make build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED.

(`CompareCard.swift` is still on disk at this point — the rewrite no longer references it but the file is harmless. Deletion happens in the next task.)

- [ ] **Step 3: Run tests**

Run: `cd mac && make test 2>&1 | tail -3`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add mac/VoiceKeyboard/UI/Settings/Pipeline/CompareView.swift
git commit -m "feat(mac): two-pane Compare view — source vs selected preset"
```

---

## Phase D — Cleanup

### Task 4: Delete `CompareCard.swift`

**Files:**
- Delete: `mac/VoiceKeyboard/UI/Settings/Pipeline/CompareCard.swift`

`CompareView` no longer references it. Delete + regenerate the project file so the source is no longer compiled into the build.

- [ ] **Step 1: Delete the file**

Run: `rm mac/VoiceKeyboard/UI/Settings/Pipeline/CompareCard.swift`

- [ ] **Step 2: Regenerate project + build + test**

Run: `cd mac && rm -rf VoiceKeyboard.xcodeproj && make project && make build 2>&1 | tail -3 && make test 2>&1 | tail -3`
Expected: BUILD SUCCEEDED + tests pass.

- [ ] **Step 3: Commit**

```bash
git add mac/VoiceKeyboard/UI/Settings/Pipeline/CompareCard.swift mac/VoiceKeyboard.xcodeproj/project.pbxproj
git commit -m "refactor(mac): drop CompareCard — replay rendering moved to SessionDetail"
```

---

## Phase E — Final integration

### Task 5: Final integration check + PR

- [ ] **Step 1: Full test suite**

Run: `cd mac && make test 2>&1 | tail -3`
Expected: PASS — total includes 3 new CompareSourceLoader tests on top of the existing baseline.

Run: `cd core && go test ./... && go test -tags=whispercpp ./cmd/libvkb/... ./internal/replay/...`
Expected: PASS — no Go-side changes; sanity check that the dylib still works.

- [ ] **Step 2: Clean Debug build**

Run: `cd mac && make clean && make build 2>&1 | tail -3`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Manual smoke test**

- Toggle Developer mode on. Pipeline → Compare. Toolbar shows Source picker + Preset picker + Run button (no multi-toggle).
- Body shows two side-by-side panes. Left: ORIGINAL badge + source's SessionDetail. Right: empty state ("Pick a preset and click Run.")
- Click Run. Right pane shows ProgressView while running, then renders the replay's SessionDetail with the preset's badge.
- Click ▶ on left pane's `denoise.wav` → plays. Click ▶ on right pane's `tse.wav` → left's stops, right's plays.
- Switch source via picker → right pane goes back to empty state; preset picker auto-defaults to the new source's preset if it's known.
- Switch preset → right pane goes back to empty state. Run again → re-fills.

- [ ] **Step 4: Push + open PR**

```bash
git push -u origin feat/compare-side-by-side
gh pr create --base main --title "feat(mac): Compare view two-pane layout — original vs selected preset" \
  --body "Replaces the horizontal-scroll multi-preset cards with a fixed two-pane layout: source on the left, one selected preset's replay on the right. Both reuse the existing SessionDetail. Single shared WAVPlayer across both panes.

## Summary

- New \`CompareSourceLoader\` reads a replay's session.json off disk so the right pane has a SessionManifest to feed SessionDetail.
- New \`ComparePane\` wraps content in a label-badged box.
- \`CompareView\` rewritten: state narrows from multi-preset Set/array to single preset / single result; body becomes HStack of two panes; right pane has empty/running/error/loaded states.
- \`CompareCard.swift\` deleted (replays now render via reused SessionDetail).
- The PR #26 source-audio disclosure is gone — the new permanent left pane subsumes it.
- Default preset picker = the source session's own preset, falling back to default.

## Notable tradeoffs

- Single-preset Run loses Slice 4's within-call Whisper-cache speedup. Acceptable; if back-to-back compares get painful, the optimization is engine-level cache caching across vkb_replay calls (~30 LOC, separate effort).
- closest-match Levenshtein badge is gone (no longer meaningful with one preset). Levenshtein helper + tests stay in VoiceKeyboardCore — harmless, may be useful for future surfaces.

## Test plan

- [x] \`cd mac && make test\` — 3 new CompareSourceLoader tests pass on top of baseline.
- [x] \`cd mac && make clean && make build\` — clean.
- [x] \`cd core && go test ./... && go test -tags=whispercpp ./cmd/libvkb/... ./internal/replay/...\` — green (no Go-side changes; sanity check).
- [ ] Manual: source picker + preset picker + Run → both panes render. Switching either picker resets the right pane. Single-source playback across panes.

🤖 Generated with [Claude Code](https://claude.com/claude-code)"
```

---

## Summary

**5 tasks across 5 phases. Estimated ~250 LOC.**

- Pure helpers: `CompareSourceLoader` (Task 1) + `ComparePane` (Task 2)
- Body rewrite: `CompareView` (Task 3)
- Cleanup: delete `CompareCard` (Task 4)
- Final: integration check + PR (Task 5)

---

## Test plan

- [ ] `cd mac && make test`
- [ ] `cd core && go test ./... && go test -tags=whispercpp ./cmd/libvkb/... ./internal/replay/...`
- [ ] `cd mac && make clean && make build`
- [ ] Manual smoke (Task 5 Step 3)

---

## Self-Review

### Spec coverage

| Spec section / requirement | Implementing task |
|---|---|
| Two-pane HStack layout | Task 3 |
| Single preset picker | Task 3 (toolbar) |
| Source on left always; replay on right always | Task 3 (leftPane / rightPane) |
| Source's SessionDetail reused | Task 3 (leftPane) |
| Replay's SessionDetail reused | Task 3 (rightPane, fed by replayManifest from CompareSourceLoader) |
| Empty / running / error / loaded right-pane states | Task 3 (rightPane @ViewBuilder branches) |
| Shared WAVPlayer across panes | Task 3 (single @State, passed to both SessionDetails) |
| Default preset = source's preset, fallback to default | Task 3 (refresh + onChange of selectedSourceID) |
| Switching source/preset stops player + clears right pane | Task 3 (onChange handlers) |
| `CompareSourceLoader.loadReplayManifest(sourceID:presetName:)` + URL overload for tests | Task 1 |
| `ComparePane` generic wrapper | Task 2 |
| `CompareCard.swift` deleted | Task 4 |
| `Levenshtein.swift` + tests stay | (no task — file untouched) |
| Source-audio disclosure from PR #26 removed | Task 3 (replaced by permanent left pane) |
| Min pane width 320 | Task 3 (`.frame(minWidth: 320)`) |

All spec requirements mapped.

### Placeholder scan

No "TBD" / "implement later" / "add validation" hand-waves. Every step has either complete code or a concrete shell command with expected output.

### Type consistency

- `CompareSourceLoader.loadFrom(url:)` defined Task 1 step 3, called in tests Task 1 step 1, called by app-target wrapper Task 1 step 5.
- `CompareSourceLoader.loadReplayManifest(sourceID:presetName:)` defined Task 1 step 5, called in `runReplay()` Task 3.
- `ComparePane(label:labelColor:subtitle:content:)` defined Task 2 step 1, used in `leftPane` and `rightPane` Task 3.
- `SessionDetail(manifest:player:)` — existing signature, reused.
- `ReplayResult.error` — existing field on the Codable type.
- `SessionManifest.preset`, `.durationSec`, `.id` — existing fields.

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-05-06-compare-side-by-side.md`. Two execution options:

**1. Subagent-Driven (recommended)** — Dispatch a fresh subagent per task, review between tasks, fast iteration.

**2. Inline Execution** — Execute tasks here, batch with checkpoints.
