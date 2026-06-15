# Any-key cancel — stop the whole pipeline with any keypress

**Date:** 2026-06-14
**Status:** Approved, pending implementation plan

## Problem

Today a dictation cycle can only be aborted by pressing **Escape**, and only
**while recording**. Once the push-to-talk (PTT) key is released and the engine
moves to *processing* (transcription → LLM cleanup → injection), there is no way
to bail out — the user must wait for the result to land.

We want: **hitting any key cancels the dictation and stops the entire pipeline**,
at any point from the moment recording starts until text injection completes.

## Goals

- Any key (not just Escape) cancels an in-flight dictation.
- Cancel works during **recording and during processing**, including
  **mid-stream** while streamed LLM text is being typed into the document.
- Cancelling aborts the whole pipeline: no further transcription, no LLM
  cleanup, no further injection. Whatever was already typed mid-stream stays in
  the document.
- Holding the PTT trigger itself must never self-cancel.
- Howl's own injected keystrokes must never self-cancel.

## Non-goals

- No changes to the Go core. The existing `howl_cancel_capture` already aborts
  the in-flight pipeline (drops buffered audio, cancels transcription + LLM via
  context cancellation, emits a `cancelled` event).
- No new UI surface required. Optional polish (a "Cancelled" toast, an overlay
  "press any key to cancel" hint) is explicitly out of scope for this change.
- Cancel remains keyboard-driven. The HID trigger (foot pedal/mouse) is a
  *start/stop* trigger, not a cancel surface.

## Current behavior (baseline)

- `CancelKeyMonitor` (`mac/Packages/HowlCore/Sources/HowlCore/Hotkey/CancelKeyMonitor.swift`)
  installs a global `NSEvent` `.keyDown` monitor that fires `onCancel` **only**
  for keyCode 53 (Escape).
- `EngineCoordinator` arms it in `onPress` (after `engine.startCapture()`
  succeeds) and **disarms it in `onRelease`** — so cancel is unavailable during
  processing. It is also stopped on terminal events (`.result`, `.cancelled`,
  `.error`) and in `manualReset`.
- `CompositionRoot` wires `onCancel` to `engine.cancelCapture()`, which calls
  `howl_cancel_capture()`.

## The crux: distinguishing real keypresses from Howl's own injection

Because cancel must work **mid-stream**, we cannot simply pause the monitor while
injecting — streaming posts keystrokes continuously, so the monitor would be
disarmed for most of processing, defeating the feature.

Both injection paths post synthetic `CGEvent`s that a global key-down monitor
will observe:

- `CGEventTextTyper.injectChunk` — streaming LLM deltas, posted as Unicode
  keyDown/keyUp pairs via `.cgAnnotatedSessionEventTap`.
- `CGEventKeystrokeSender.sendCmdV` — the non-streaming final ⌘V paste.

So Howl must be able to tell its **own** synthetic keystrokes apart from the
**user's** real keypresses.

### Chosen approach: tag & filter via `eventSourceUserData`

Howl stamps every synthetic keystroke it posts with a fixed sentinel value in
`CGEventField.eventSourceUserData`. The cancel monitor reads that field on each
observed event and **ignores** any event carrying the sentinel; everything else
is treated as a real user keypress and triggers cancel.

This is the standard macOS technique for "ignore my own synthetic input,"
robust, and unit-testable without posting events (construct a `CGEvent`,
set/read the field).

**Rejected alternatives:**

- *Suppress the monitor around each injection* — streaming posts constantly, so
  the monitor would be disarmed for most of processing (kills mid-stream
  cancel), and races would drop real keypresses landing in the suppression
  window.
- *Filter by hardware-vs-synthetic source state* (`eventSourceStateID`) — less
  explicit than an owned marker and can misclassify; the marker is strictly
  better.

## Design

### 1. Shared synthetic-event marker

A single shared constant identifies Howl-originated synthetic keystrokes, plus a
small `CGEvent` helper to apply/detect it. Lives in HowlCore (e.g. alongside the
injectors), so both injectors and the monitor reference one source of truth.

```swift
enum HowlSyntheticEvent {
    /// Sentinel written to CGEventField.eventSourceUserData on every
    /// synthetic keystroke Howl posts, so the cancel-key monitor can tell
    /// Howl's own injection apart from a real user keypress. Arbitrary but
    /// fixed and unique-enough to not collide with other apps' events.
    static let marker: Int64 = 0x484F_574C_0001  // "HOWL" + tag
}

extension CGEvent {
    func markAsHowlSynthetic() {
        setIntegerValueField(.eventSourceUserData, value: HowlSyntheticEvent.marker)
    }
    var isHowlSynthetic: Bool {
        getIntegerValueField(.eventSourceUserData) == HowlSyntheticEvent.marker
    }
}
```

### 2. Injectors stamp the marker

- `CGEventTextTyper.injectChunk` — call `down.markAsHowlSynthetic()` and
  `up.markAsHowlSynthetic()` before posting.
- `CGEventKeystrokeSender.sendCmdV` — same on its ⌘V down/up events.

### 3. `CancelKeyMonitor` fires on any key, filtering synthetics

- The global `.keyDown` handler fires `onCancel()` for **any** key, **unless**
  the event is Howl-synthetic (`event.cgEvent?.isHowlSynthetic == true`).
- Keep it to `.keyDown` only (not `.flagsChanged`) — pressing a bare modifier
  (Shift/Cmd) does not cancel; "hit a key" means an actual key.
- The cancel-decision logic is factored so it is unit-testable independent of
  the live `NSEvent` callback (e.g. a small `func shouldCancel(for:)` or reliance
  on the `isHowlSynthetic` helper).
- Remove the Escape-only `keyCode == 53` filter. Escape becomes just one of
  "any key."

### 4. `EngineCoordinator` keeps the monitor armed through processing

- Keep arming in `onPress` (after `startCapture()` succeeds).
- **Remove** the `cancelKeyMonitor.stop()` from `onRelease`, so the monitor
  stays armed into the processing phase.
- Disarm only on terminal events — `.result`, `.cancelled`, `.error` — and in
  `manualReset` (these stops already exist).
- On `.result`, the existing order (stop monitor → then inject final paste) is
  preserved; the paste is also marker-stamped as defense in depth.
- On `.chunk` (streaming), the monitor stays armed — synthetic keystrokes are
  ignored via the marker, so the user can still cancel mid-stream.

## Why the held PTT key won't self-cancel

- **Carbon `RegisterEventHotKey`** path (normal key+modifier shortcuts) consumes
  the hotkey and fires `kEventHotKeyPressed` once — no repeat key-downs reach
  the global monitor.
- **CGEventTap** paths (fn / fn+letter) either swallow the letter keyDown
  (active tap returns nil) or only watch modifiers (fn → `.flagsChanged`).
- The monitor is armed *after* `onPress` runs, so the triggering keystroke has
  already passed.

This is asserted by manual testing during implementation, not just by reasoning.

## Behavior notes / accepted trade-offs

- During processing the user is back in their own app; any real key they press
  cancels. If they release PTT and immediately start typing manually elsewhere,
  that cancels the dictation. This is the intended aggressive behavior.
- A chunk event already dispatched to the main actor may type a few more
  characters after cancel fires (best-effort). Acceptable: "whatever was typed
  so far stays."

## Testing

Unit (HowlCore):

- `CGEvent` marker round-trips: a marked event reports `isHowlSynthetic == true`;
  an unmarked event reports `false`.
- `CancelKeyMonitor`: cancels on a normal key; does **not** cancel on a
  Howl-synthetic key; Escape still cancels (it's just one of "any key").
- Update the existing `ignoresOtherKeys` test — non-Escape keys now *do* cancel
  (rename to reflect "cancels on any key").
- Injectors stamp the marker (test via the shared `markAsHowlSynthetic` helper /
  factored event construction).

Manual:

- Holding the PTT trigger and speaking does not self-cancel.
- Streaming a long result, then pressing a key mid-stream, stops further typing
  and leaves the already-typed text in place.
- Pressing a key during the transcription/LLM "thinking" window (before any
  text appears) cancels cleanly with no injection.

## Files touched

- `mac/Packages/HowlCore/Sources/HowlCore/Hotkey/CancelKeyMonitor.swift` —
  any-key + synthetic filter; updated test seams.
- `mac/Packages/HowlCore/Sources/HowlCore/Injection/CGEventTextTyper.swift` —
  stamp marker.
- `mac/Packages/HowlCore/Sources/HowlCore/Injection/ClipboardPasteInjector.swift`
  (`CGEventKeystrokeSender`) — stamp marker.
- New shared marker + `CGEvent` helper (small file in HowlCore, e.g.
  `Injection/HowlSyntheticEvent.swift`).
- `mac/Howl/Engine/EngineCoordinator.swift` — remove `onRelease` disarm; keep
  arming/terminal-disarm.
- `mac/Packages/HowlCore/Tests/HowlCoreTests/CancelKeyMonitorTests.swift` —
  updated/expanded tests; new marker tests.
