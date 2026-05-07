# Compare side-by-side (Original vs Selected Preset) — Design

## Overview

Restructure the Pipeline → Compare view from a horizontal-scroll of replay cards into a fixed two-pane layout: **source session on the left, one selected preset's replay on the right**. Both panes reuse the existing `SessionDetail` component, so the user gets full per-stage audio playback + raw/dict/cleaned transcripts on both sides for direct A/B inspection.

The single-preset-at-a-time model is deliberate: pairwise comparison ("does paranoid handle my noisy room better than default?") is the dominant Compare workflow. Switching presets to compare against a different one is one click + one Run.

## Audience and scope

This is a **Mac UI refactor of `CompareView` only**. No Go-side changes, no C ABI changes, no schema changes. The replay package still produces full per-preset session folders on disk (`<source>/replay-<preset>/`); the change is purely how the Compare pane renders them.

**In scope**:
- Two-pane side-by-side layout (`HStack` of two `SessionDetail` instances)
- Single-preset picker replacing the multi-preset toggles
- Source session always shown on the left; replay always on the right
- Empty-state message on the right pane before first Run
- Per-pane status (preset name, duration) in a small header strip
- Shared `WAVPlayer` across both panes (single audio source at a time)

**Out of scope**:
- Multi-preset comparison (was Slice 4 territory; collapsed to single-preset for clarity).
- Synchronized scrubbing / playback ("play denoise.wav from both panes from the same offset"). Future polish if it becomes useful.
- The closest-match Levenshtein badge — irrelevant with one preset. Levenshtein helper stays in `VoiceKeyboardCore` (it's harmless and tested) but the badge UI goes away.
- Run-and-display-the-other-N-results state machine (the multi-toggle path).

## Architecture

```
mac/VoiceKeyboard/UI/Settings/Pipeline/
├── CompareView.swift            MODIFIED — toolbar with single preset picker;
│                                  HStack of two SessionDetails; empty-state
├── CompareCard.swift            DELETED — replaced by SessionDetail reuse
├── CompareSourceLoader.swift    NEW — loads the replay's SessionManifest from
│                                  disk so the right pane can render the
│                                  reused SessionDetail. Pure helper, no UI.
└── (rest unchanged)
```

`Levenshtein.swift` and its tests remain in `VoiceKeyboardCore`. `CompareCard.swift` and its closest-match logic go away.

## Components

### `CompareView` (rewritten body)

State:
- `selectedSourceID: String?`
- `selectedPresetName: String?` — replaces the old `selectedPresetNames: Set<String>`
- `result: ReplayResult?` — replaces `results: [ReplayResult]`. Single result, since we only run one preset.
- `replayManifest: SessionManifest?` — the manifest of the just-finished replay session, loaded from disk so the right pane can render `SessionDetail` (which takes a manifest, not a `ReplayResult`).
- `running`, `loadError`, `runError`, `player` — same as today.

Body shape:
```
SettingsPane {
  toolbar          // source picker + preset picker + Run
  Divider
  HStack {
    leftPane       // source's SessionDetail
    rightPane      // replay's SessionDetail OR empty-state
  }
}
```

Toolbar (single row, compact):
- Source picker — same dropdown listing captured sessions, newest first.
- Preset picker — `default`/`minimal`/`aggressive`/`paranoid` (+ user presets), single selection. Default selection: the source session's own preset (`source.preset` from its manifest) if it's still in `presetList`; otherwise `"default"`.
- Run button — `Label("Run", systemImage: "play.fill")` while idle, `ProgressView` while running. Disabled when `selectedSourceID == nil`, `selectedPresetName == nil`, or `running`.

The "Source audio" disclosure shipped in PR #26 goes away — the new layout puts source detail in a permanent left pane, no disclosure needed.

### `CompareSourceLoader` (new)

```swift
enum CompareSourceLoader {
    /// Read the on-disk session.json for a replay session.
    /// Returns nil when the file isn't present (replay wasn't run yet,
    /// or the folder was cleared).
    static func loadReplayManifest(sourceID: String, presetName: String) -> SessionManifest?
}
```

The replay package writes `session.json` for each replay session at `<base>/<sourceID>/replay-<presetName>/session.json`. This helper reads that file via `JSONDecoder` and returns the manifest. Lives in the app target (depends on `SessionPaths`).

### Left pane

```swift
@ViewBuilder
private var leftPane: some View {
    if let source = sourceManifest {
        ComparePane(
            label: "ORIGINAL",
            labelColor: .secondary,
            subtitle: paneSubtitle(for: source)
        ) {
            SessionDetail(manifest: source, player: player)
        }
    }
}
```

`ComparePane` is a small generic layout wrapper (private to `CompareView`) that boxes the content with the badge header + subtitle. Just visual chrome — no behavior. Its subtitle line for either pane is built from the manifest's existing fields:

```swift
private func paneSubtitle(for m: SessionManifest) -> String {
    "\(m.preset.isEmpty ? "—" : m.preset) · \(String(format: "%.1fs", m.durationSec))"
}
```

No new fields on `SessionManifest` needed.

### Right pane

```swift
@ViewBuilder
private var rightPane: some View {
    if let replay = replayManifest, let preset = selectedPresetName {
        ComparePane(
            label: preset.uppercased(),
            labelColor: .accentColor,
            subtitle: paneSubtitle(for: replay)
        ) {
            SessionDetail(manifest: replay, player: player)
        }
    } else if running {
        VStack { ProgressView(); Text("Running…").font(.caption).foregroundStyle(.secondary) }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else if let err = runError {
        Text(err).foregroundStyle(.red).font(.callout).padding()
    } else {
        Text("Pick a preset and click Run.")
            .font(.callout).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
```

## Data flow

1. **Initial load**: `refresh()` (existing) populates `sessionList` + `presetList`. Defaults: `selectedSourceID = sessionList.first?.id`, `selectedPresetName = "default"`.
2. **Run**: `runReplay()` calls `replay.run(sourceID:, presets: [selectedPresetName])`. On success: `result = response.first`. Then `replayManifest = CompareSourceLoader.loadReplayManifest(sourceID:, presetName:)`.
3. **Switching source or preset**: stops `player`, clears `result` + `replayManifest`. The right pane reverts to the empty state until the user clicks Run again. (Source pane updates immediately because it's bound to `sourceManifest` derived from `selectedSourceID`.)
4. **Playback**: shared `WAVPlayer`. Clicking ▶ on a left-pane stage row stops any right-pane playback, and vice versa.

## Error handling

- **`replay.run` throws**: surfaced as `runError`; right pane shows the error in red. Same as today.
- **Replay completes but `session.json` is missing**: `replayManifest == nil`; right pane shows `"Replay completed but its manifest couldn't be loaded — try Run again."` in red. Indicates a recorder failure on the Go side; rare but possible (e.g., disk full mid-run).
- **`result.error` set** (per-preset failure inside the run): same surface as the missing-manifest case — show `result.error` in the right pane instead of trying to render a (probably non-existent) manifest.

## Testing

- `CompareView` is SwiftUI; no unit-test surface (matches the rest of the Pipeline tab).
- `CompareSourceLoader.loadReplayManifest` is a pure helper. Unit-test in `VoiceKeyboardCoreTests`:
  - happy path: write a manifest to a temp dir, read it back, assert equality.
  - missing file: returns nil.
  - corrupted JSON: returns nil.
- Existing tests for `replay.Run`, `ReplayClient`, `Levenshtein`, etc. unchanged.

Manual smoke test:
- Pick a source, pick `default`, click Run → both panes populate. Click ▶ on left's `denoise.wav` → plays. Click ▶ on right's `tse.wav` → left's stops, right's plays.
- Switch source → right pane goes back to empty state. Run again → right pane re-fills.
- Switch preset → same behavior.
- Run with a preset whose name was deleted (race condition): right pane shows the error string from `result.error`.

## Migration

Pure UI refactor, no schema or persistence change. Slice 4's `replay` package + C ABI + `ReplayClient` bridge unchanged. The on-disk replay folder layout (`<source>/replay-<preset>/`) is identical.

## Risks

- **Two `SessionDetail` columns at narrow Settings window widths**: each `SessionDetail` includes the transport bar (slider) which can squish. Set `minWidth: 320` per pane (matches the existing `CompareCard` width).
- **Single-preset Run loses the Whisper-cache speedup that Slice 4 introduced**: only matters if the user runs sequential comparisons against the same source with a fixed model size. The cache lives only within one `replay.Run` call; sequential calls each pay the cold-start. Acceptable tradeoff — the user gains pairwise clarity, loses some speed for back-to-back compares. If this becomes painful, the optimization is to keep an engine-level Whisper instance cached across `vkb_replay` calls (separate effort, ~30 LOC).
