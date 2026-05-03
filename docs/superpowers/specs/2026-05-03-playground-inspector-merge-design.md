# Playground + Inspector Merge — Design

## Overview

Merge the standalone **Playground** tab (scratch text editor + Record button) with the **Pipeline Inspector** (captured-session viewer) into one tab so the user can dictate, refresh, and inspect what the pipeline produced — all in the same place. Speeds up the iterate-and-tune loop because no tab-switching breaks attention between "I dictated something" and "let me see what each stage of the pipeline produced for that thing."

## Audience and scope

This is a **Mac UI refactor**. No Go-side changes, no C ABI changes, no schema changes. Everything underneath stays the same.

**In scope:**
- Combined "Playground" tab with always-visible recording controls + (when Developer mode is on) a sessions sidebar + detail pane.
- Refresh button on the sessions list (manual; no auto-poll).
- Session list rows show preview text (first ~80 chars of cleaned transcript) + relative timestamp ("2 min ago").
- Pipeline tab loses its Inspector half — keeps only the Editor (the segmented control goes away).
- Inline audio playback (already shipped in PR #17) carries over unchanged into the merged tab.

**Out of scope:**
- Any auto-refresh or push notification when a new session lands. Manual refresh only.
- Any change to the Editor (Slice 3 / PR #16).
- Any change to the session manifest schema.
- Compare view (Slice 4) or CLI parity (Slice 5).

## Architecture

```
mac/VoiceKeyboard/UI/Settings/
├── PlaygroundTab.swift           MODIFIED — extends to host the sessions sidebar + detail pane
├── SettingsView.swift            MODIFIED — passes sessions client + presets client through to Playground
├── Pipeline/
│   ├── PipelineTab.swift         MODIFIED — drops the segmented control; renders EditorView only
│   ├── InspectorView.swift       DELETED — content split into SessionList + SessionDetail
│   ├── SessionList.swift         NEW — vertical sidebar (rows: relative time + preset + preview)
│   ├── SessionDetail.swift       NEW — right-pane detail for the selected session
│   ├── RelativeTime.swift        NEW — pure helper: "2 min ago" / "3 hours ago" formatter
│   ├── SessionPreview.swift      NEW — pure helper: load cleaned.txt + truncate to N chars
│   ├── WAVPlayer.swift           UNCHANGED (PR #17)
│   ├── SessionPaths.swift        UNCHANGED
│   ├── EditorView.swift          UNCHANGED (Slice 3)
│   ├── StageGraph.swift          UNCHANGED (Slice 3)
│   ├── StageDetailPanel.swift    UNCHANGED (Slice 3)
│   └── SaveAsPresetSheet.swift   UNCHANGED (Slice 3)
```

## Layout

```
┌─────────────────────────────────────────────────────────────────────┐
│ Playground tab                                                       │
├──────────────────┬──────────────────────────────────────────────────┤
│ SESSIONS    [↻]  │ PLAYGROUND                                        │
│ ──────────────── │ ──────────────────────────────────────────────── │
│ ▣ 2 min ago      │ Hold ⌃⌥⌘V to dictate                            │
│   default        │ [● Record]  [▮▮▮▯▯] (RMS)                        │
│   "Hey, can you  │ ┌──────────────────────────────────────────────┐ │
│    schedule a 30 │ │ scratch text editor (multiline) — cleaned    │ │
│    minute …"     │ │ text from your dictation appears here        │ │
│   3.4s · 16 kHz  │ │                                              │ │
│                  │ │                                              │ │
│ ☐ 15 min ago     │ └──────────────────────────────────────────────┘ │
│   paranoid       │                          [Reset]    [Clear]      │
│   "Quick test of │                                                   │
│    the new …"    │ DETAIL — session 2026-05-03T01:08:42.123Z         │
│   5.1s           │ ──────────────────────────────────────────────── │
│                  │ ▶ tse.wav      [scrubber]    0:01 / 0:03         │
│ ☐ 42 min ago     │ ──────────────────────────────────────────────── │
│   minimal        │ STAGES                                            │
│   "Ok so I think │   denoise   (frame)            48000 Hz   [▶]    │
│    we should …"  │   decimate3 (frame)            16000 Hz   [▶]    │
│   2.8s           │   tse 🔊    (chunk)  sim 0.71  16000 Hz   [⏸]    │
│                  │ TRANSCRIPTS                                       │
│ … 9 more         │   raw.txt   "hey can you …"           [📄 Open] │
│                  │   cleaned   "Hey, can you schedule…"  [📄 Open] │
│ [📂] [🗑 Clear]  │                                                   │
└──────────────────┴──────────────────────────────────────────────────┘
```

When **Developer mode is OFF**: the sessions sidebar, the detail pane, and the inline player are all hidden. The tab degrades to today's Playground (status banner + record + scratch + RMS meter). Casual users see no change.

When **Developer mode is ON**: the sidebar appears, populated from `SessionsClient.list()`. The detail pane shows whatever session is selected (latest by default). The recording controls stay where they are at the top of the right column.

The **Pipeline tab** in the sidebar still exists and is still Developer-mode-gated, but it now shows only the Editor (preset picker + StageGraph + StageDetailPanel + Save/Reset toolbar). The segmented Inspector/Editor switch goes away — the Inspector content lives under Playground now.

## Components

### `SessionList`

The sidebar. Loads `[SessionManifest]` via `SessionsClient.list()`. Each row renders:
- **Relative timestamp** ("2 min ago") computed from `manifest.id` (RFC3339 timestamp string) using the `RelativeTime` helper.
- **Preset name** as a small caption.
- **Preview text** — first ~80 chars of `cleaned.txt`, loaded via `SessionPreview.load(in: id)`. Loaded once at row construction and cached on the row's `@State`. If the file isn't readable yet (manifest written but transcript file missing), shows "(no transcript)" in muted gray.
- **Duration + final-stage rate** in a smaller line.
- **Selected highlight** — accent-colored background, white text.

The list header has the count of captured sessions, a "refreshed just now" / "refreshed Xm ago" caption (so stale data is visible), and a refresh button (↻). Clicking refresh re-runs `SessionsClient.list()`, updates the cached load timestamp, and re-renders.

The list footer has Reveal-in-Finder (opens the session folder for the selected row) and Clear-all (alert-confirmed delete of every session).

### `SessionDetail`

The right pane. Shows the selected session's stages + transcripts inline (same content as today's Inspector body), plus the transport bar from PR #17. No structural changes to this content — just lifted out of `InspectorView` so `PlaygroundTab` can compose it next to the playground bar.

### `RelativeTime`

Pure formatter helper:

```
diff < 60s            → "just now"
diff < 60m            → "X min ago"
diff < 24h            → "X hour(s) ago"
diff < 7d             → "X day(s) ago"
otherwise             → date stamp like "May 3"
```

Lives in `VoiceKeyboardCore` (with the editor helpers) so it can be unit-tested.

### `SessionPreview`

Pure helper to load + truncate a session's cleaned text:

```swift
static func load(in id: String, maxChars: Int = 80) -> String?
```

Reads `SessionPaths.file(in: id, rel: "cleaned.txt")`, returns the first `maxChars` (Unicode-aware), trims whitespace, returns `nil` if the file doesn't exist or can't be read. The truncation appends `"…"` when the underlying text is longer.

Lives in the app target (not VoiceKeyboardCore) since it depends on `SessionPaths` which is app-target.

### `PlaygroundTab` (modified)

Today's PlaygroundTab is one column. The new shape: an `HSplitView` with:
- **Left column**: `SessionList`, only when `settings.developerMode == true`. Width clamped to ~240pt; user can drag the divider.
- **Right column**: top section is the existing playground (status banner + record + RMS + scratch text editor + Clear), bottom section is `SessionDetail` for the selected session — also only when developer mode is on.

When developer mode is OFF, the right column fills the whole tab and shows just the playground (today's behavior). The `HSplitView` collapses to a single pane.

Because the playground's record controls drive the engine and a successful dictation produces a new session, the user's natural flow is: dictate → tap ↻ → see new session at top → click → review.

### `PipelineTab` (modified)

Drops the segmented control. Body becomes:

```swift
SettingsPane {
    EditorView(presets: presets, sessions: sessions)
}
```

The `sessions` parameter still threads through (needed by `EditorView`'s detail panel for the recent-similarity readout from Slice 3) — that doesn't change.

## Data flow

1. **Initial load**: `PlaygroundTab.task` calls `SessionList.refresh()` if developer mode is on. `SessionList` calls `sessions.list()`, sets `manifests`, and triggers `selectedID = manifests.first?.id` to auto-select the latest.
2. **Manual refresh**: Refresh button calls `SessionList.refresh()` again. The selection is preserved if the previously-selected ID is still present, otherwise resets to the new latest.
3. **Selection change**: `SessionDetail` re-renders for the new selected session; `WAVPlayer` is `.stop()`ed to drop any in-flight playback from the prior session (matches PR #17 behavior).
4. **Recording** (Playground bar): unchanged — calls into `coordinator.manualPress() / .manualRelease()`. When the engine emits `result`, the user sees text in the scratch editor and (if developer mode) can hit ↻ to see the new session.

## Error handling

- **`SessionsClient.list()` throws**: shown in the sidebar header as "Failed to load sessions: <error>" in red. Refresh button still clickable.
- **`SessionPreview.load(...)` returns nil**: row shows `"(no transcript)"` in muted gray. Common during a fresh session before the cleanup transcript has been flushed; refreshing usually fixes it.
- **`WAVPlayer.lastError` set**: the transport bar already surfaces this (PR #17).
- **`RelativeTime` given an unparseable timestamp**: falls back to displaying the raw `id` string. Defensive — manifest IDs are always RFC3339 today.

## Testing

- **`RelativeTimeTests`** (SwiftPM, in VoiceKeyboardCore tests): covers each branch of the formatter — `just now`, `5 min ago`, `1 hour ago`, `3 hours ago`, `2 days ago`, far past → date stamp. Uses a fixed `now` Date so the tests are deterministic.
- **`SessionPreviewTests`** (SwiftPM): covers load-success (truncation + ellipsis), file-missing → nil, empty file → nil-or-empty, unicode-aware truncation. Writes fixtures to a `t.TempDir()`-equivalent temp folder.
- **No SwiftUI snapshot tests** — matches the testing baseline of Slices 1–3.

Manual smoke test:
- Toggle Developer mode off → Playground shows only the scratch editor; no sidebar.
- Toggle Developer mode on → sidebar appears, latest session auto-selected.
- Dictate something → click ↻ → new session at the top of the list with the correct preview + "just now".
- Click an older session → detail pane updates; transport bar resets.
- Click ↻ during playback → list re-renders, playback continues if selection didn't change.

## Migration

Pure UI refactor. No data migration. No persistence changes. No CLI impact. The "Pipeline" tab still exists in the sidebar with its existing icon — just leaner content.

## Risks

- **Casual users opening Settings → Playground** see no change unless Developer mode is on. The sidebar appearing the moment they flip the toggle is the only visible "magic" — handled by a normal SwiftUI conditional, no animation surgery needed.
- **Sidebar width**: `HSplitView` defaults can squish on narrow Settings windows. Set a sensible `idealWidth: 240, minWidth: 180` on the sidebar so the right column always has room for the transport bar + stage rows.
- **Refresh button feel**: with no auto-poll, a user who dictates then doesn't refresh sees stale data. Caption under the sidebar header ("12 captured · refreshed just now") + a subtle "click ↻ to load new" hint mitigates this. We can add live auto-refresh later if it becomes painful.
