# Any-key Cancel Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the user hit any key to cancel an in-flight dictation — during recording *or* processing — aborting the whole pipeline, without Howl's own injected keystrokes self-cancelling.

**Architecture:** Extend the existing `CancelKeyMonitor` (global `NSEvent` key-down monitor) to fire on any key instead of only Escape, and keep it armed through the processing phase. To avoid self-cancelling on Howl's own synthetic keystrokes (streaming injection + final ⌘V paste), every synthetic event Howl posts is stamped with a sentinel in `CGEventField.eventSourceUserData`; the monitor ignores stamped events. No Go/core changes — `howl_cancel_capture` already aborts the whole pipeline.

**Tech Stack:** Swift, AppKit (`NSEvent`), CoreGraphics (`CGEvent`), Swift Testing (`@Suite`/`@Test`), SwiftPM (`swift test`).

**Spec:** `docs/superpowers/specs/2026-06-14-any-key-cancel-design.md`

---

## File Structure

- **Create** `mac/Packages/HowlCore/Sources/HowlCore/Injection/HowlSyntheticEvent.swift` — the shared marker constant + a small `CGEvent` extension (`markAsHowlSynthetic()` / `isHowlSynthetic`). Single responsibility: identifying Howl-originated synthetic input.
- **Create** `mac/Packages/HowlCore/Tests/HowlCoreTests/HowlSyntheticEventTests.swift` — tests for the marker helper.
- **Modify** `mac/Packages/HowlCore/Sources/HowlCore/Hotkey/CancelKeyMonitor.swift` — any-key + synthetic filter + pure `shouldCancel` decision + updated test seams.
- **Modify** `mac/Packages/HowlCore/Tests/HowlCoreTests/CancelKeyMonitorTests.swift` — updated/expanded tests.
- **Modify** `mac/Packages/HowlCore/Sources/HowlCore/Injection/CGEventTextTyper.swift` — stamp marker on streamed keystrokes.
- **Modify** `mac/Packages/HowlCore/Sources/HowlCore/Injection/ClipboardPasteInjector.swift` — stamp marker on the ⌘V paste keystrokes (`CGEventKeystrokeSender`).
- **Modify** `mac/Howl/Engine/EngineCoordinator.swift` — stop disarming the monitor on PTT release so it stays armed through processing.

**Testability note:** Unit tests cover what is unit-testable — the marker round-trip and the pure `shouldCancel` decision. The injectors (post events and return `Void`) and `EngineCoordinator` (app-target `@MainActor` with live composition/`NSEvent`) are not unit-tested in this codebase; they are wiring around the tested helper and are verified by build + the manual checklist in Task 6.

---

### Task 1: Synthetic-event marker + CGEvent helper

**Files:**
- Create: `mac/Packages/HowlCore/Sources/HowlCore/Injection/HowlSyntheticEvent.swift`
- Test: `mac/Packages/HowlCore/Tests/HowlCoreTests/HowlSyntheticEventTests.swift`

- [ ] **Step 1: Write the failing test**

Create `mac/Packages/HowlCore/Tests/HowlCoreTests/HowlSyntheticEventTests.swift`:

```swift
import Testing
import CoreGraphics
@testable import HowlCore

@Suite("HowlSyntheticEvent")
struct HowlSyntheticEventTests {
    @Test func markerIsStable() {
        // Guards against an accidental value change that would silently
        // break the cancel monitor's filter.
        #expect(HowlSyntheticEvent.marker == 0x484F_574C_0001)
    }

    @Test func cgEventMarkerRoundTrips() {
        guard let ev = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true) else {
            // No window server (headless CI) — CGEvent creation returns nil.
            // Nothing to assert; the pure decision logic is covered elsewhere.
            return
        }
        #expect(ev.isHowlSynthetic == false)
        ev.markAsHowlSynthetic()
        #expect(ev.isHowlSynthetic == true)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd mac/Packages/HowlCore && swift test --filter HowlSyntheticEvent`
Expected: FAIL — compile error, "cannot find 'HowlSyntheticEvent' in scope" (and `markAsHowlSynthetic`/`isHowlSynthetic` unresolved).

- [ ] **Step 3: Write minimal implementation**

Create `mac/Packages/HowlCore/Sources/HowlCore/Injection/HowlSyntheticEvent.swift`:

```swift
import CoreGraphics

/// Identifies synthetic keyboard events that Howl posts itself — streaming
/// text injection (`CGEventTextTyper`) and the final ⌘V paste
/// (`CGEventKeystrokeSender`). The any-key cancel monitor reads this marker
/// to tell Howl's own injection apart from a real user keypress, so typing
/// text into the document never self-cancels the dictation.
enum HowlSyntheticEvent {
    /// Sentinel written to `CGEventField.eventSourceUserData` on every
    /// synthetic keystroke Howl posts. Arbitrary but fixed ("HOWL" + a tag);
    /// unique-enough not to collide with other apps' synthetic events.
    static let marker: Int64 = 0x484F_574C_0001
}

extension CGEvent {
    /// Stamp this event as Howl-originated synthetic input.
    func markAsHowlSynthetic() {
        setIntegerValueField(.eventSourceUserData, value: HowlSyntheticEvent.marker)
    }

    /// True when this event carries Howl's synthetic-input marker.
    var isHowlSynthetic: Bool {
        getIntegerValueField(.eventSourceUserData) == HowlSyntheticEvent.marker
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd mac/Packages/HowlCore && swift test --filter HowlSyntheticEvent`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add mac/Packages/HowlCore/Sources/HowlCore/Injection/HowlSyntheticEvent.swift \
        mac/Packages/HowlCore/Tests/HowlCoreTests/HowlSyntheticEventTests.swift
git commit -m "feat(cancel): add Howl synthetic-event marker + CGEvent helper

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: CancelKeyMonitor — any key, ignore Howl's synthetic keystrokes

**Files:**
- Modify: `mac/Packages/HowlCore/Sources/HowlCore/Hotkey/CancelKeyMonitor.swift`
- Test: `mac/Packages/HowlCore/Tests/HowlCoreTests/CancelKeyMonitorTests.swift`

- [ ] **Step 1: Write the failing tests**

Replace the entire contents of `mac/Packages/HowlCore/Tests/HowlCoreTests/CancelKeyMonitorTests.swift` with:

```swift
import Testing
import Foundation
@testable import HowlCore

private final class Counter: @unchecked Sendable { var value = 0 }

@Suite("CancelKeyMonitor")
struct CancelKeyMonitorTests {
    @Test func cancelsOnEsc() {
        let c = Counter()
        let mon = CancelKeyMonitor(onCancel: { c.value += 1 })
        mon.simulateEscForTest()
        #expect(c.value == 1)
    }

    @Test func cancelsOnAnyKey() {
        let c = Counter()
        let mon = CancelKeyMonitor(onCancel: { c.value += 1 })
        mon.simulateKeyForTest(keyCode: 0)
        #expect(c.value == 1)
    }

    @Test func ignoresHowlSyntheticKey() {
        let c = Counter()
        let mon = CancelKeyMonitor(onCancel: { c.value += 1 })
        mon.simulateSyntheticKeyForTest()
        #expect(c.value == 0)
    }

    @Test func shouldCancelDecision() {
        #expect(CancelKeyMonitor.shouldCancel(userData: 0) == true)
        #expect(CancelKeyMonitor.shouldCancel(userData: 12345) == true)
        #expect(CancelKeyMonitor.shouldCancel(userData: HowlSyntheticEvent.marker) == false)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd mac/Packages/HowlCore && swift test --filter CancelKeyMonitor`
Expected: FAIL — compile error: no `shouldCancel(userData:)` static method and no `simulateSyntheticKeyForTest()` on `CancelKeyMonitor`; `cancelsOnAnyKey` would also fail at runtime (old `simulateKeyForTest` is a no-op).

- [ ] **Step 3: Write the implementation**

Replace the entire contents of `mac/Packages/HowlCore/Sources/HowlCore/Hotkey/CancelKeyMonitor.swift` with:

```swift
import AppKit
import CoreGraphics

/// Watches for ANY key globally while a dictation cycle is active — both
/// recording and processing — and fires `onCancel`, which aborts the whole
/// pipeline. Howl's own injected keystrokes (streaming text + final ⌘V paste)
/// carry the `HowlSyntheticEvent.marker` in `eventSourceUserData` and are
/// ignored, so typing text into the document never self-cancels.
///
/// Start it on PTT press; stop it on a terminal event (result / cancelled /
/// error) or manual reset, so normal typing outside a dictation is
/// unaffected.
///
/// THREAD SAFETY: `start()` and `stop()` must only be called from the main
/// actor. `@unchecked Sendable` is required because `NSEvent` monitor tokens
/// (`Any?`) are not `Sendable`; all mutations are serialized on the main
/// thread by the caller (`EngineCoordinator`).
public final class CancelKeyMonitor: @unchecked Sendable {
    private let onCancel: @Sendable () -> Void
    private var monitor: Any?

    public init(onCancel: @escaping @Sendable () -> Void) {
        self.onCancel = onCancel
    }

    /// Pure cancel decision: any observed key cancels unless it carries
    /// Howl's synthetic-event marker (i.e. it's our own injection).
    /// `userData` is the event's `eventSourceUserData` field value
    /// (0 for real hardware keypresses).
    static func shouldCancel(userData: Int64) -> Bool {
        userData != HowlSyntheticEvent.marker
    }

    public func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [onCancel] event in
            let userData = event.cgEvent?.getIntegerValueField(.eventSourceUserData) ?? 0
            if CancelKeyMonitor.shouldCancel(userData: userData) {
                onCancel()
            }
        }
    }

    public func stop() {
        guard let m = monitor else { return }
        NSEvent.removeMonitor(m)
        monitor = nil
    }

    deinit { stop() }

    // MARK: - Test surface

    /// Simulates a real (non-synthetic) keypress — should cancel.
    public func simulateKeyForTest(keyCode _: UInt16 = 0) {
        if Self.shouldCancel(userData: 0) { onCancel() }
    }

    /// Simulates a Howl-injected keystroke — should NOT cancel.
    public func simulateSyntheticKeyForTest() {
        if Self.shouldCancel(userData: HowlSyntheticEvent.marker) { onCancel() }
    }

    /// Simulates Esc — now just one of "any key".
    public func simulateEscForTest() {
        simulateKeyForTest(keyCode: 53)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd mac/Packages/HowlCore && swift test --filter CancelKeyMonitor`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add mac/Packages/HowlCore/Sources/HowlCore/Hotkey/CancelKeyMonitor.swift \
        mac/Packages/HowlCore/Tests/HowlCoreTests/CancelKeyMonitorTests.swift
git commit -m "feat(cancel): CancelKeyMonitor fires on any key, ignores Howl's own keystrokes

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: Stamp the marker on Howl's injected keystrokes

**Files:**
- Modify: `mac/Packages/HowlCore/Sources/HowlCore/Injection/CGEventTextTyper.swift`
- Modify: `mac/Packages/HowlCore/Sources/HowlCore/Injection/ClipboardPasteInjector.swift`

No new unit test: both methods post events and return `Void`. The marker behavior is already covered by Task 1's helper test; this task wires the tested helper into the two injection paths. Verified by `swift build` and the manual checklist in Task 6.

- [ ] **Step 1: Stamp the streaming injector**

In `mac/Packages/HowlCore/Sources/HowlCore/Injection/CGEventTextTyper.swift`, the existing `injectChunk` posts `down`/`up` via `.cgAnnotatedSessionEventTap`. Add the two `markAsHowlSynthetic()` calls just before the `down.post(...)` line. Replace this block:

```swift
        utf16.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            down.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: base)
            up.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: base)
        }
        // cgAnnotatedSessionEventTap routes the event through the
        // current login session; the focused app sees it like any
        // other key press.
        down.post(tap: .cgAnnotatedSessionEventTap)
        up.post(tap: .cgAnnotatedSessionEventTap)
```

with:

```swift
        utf16.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            down.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: base)
            up.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: base)
        }
        // Mark as Howl-originated so the any-key cancel monitor (armed during
        // processing) ignores our own streamed keystrokes instead of treating
        // them as a user cancel.
        down.markAsHowlSynthetic()
        up.markAsHowlSynthetic()
        // cgAnnotatedSessionEventTap routes the event through the
        // current login session; the focused app sees it like any
        // other key press.
        down.post(tap: .cgAnnotatedSessionEventTap)
        up.post(tap: .cgAnnotatedSessionEventTap)
```

- [ ] **Step 2: Stamp the ⌘V paste injector**

In `mac/Packages/HowlCore/Sources/HowlCore/Injection/ClipboardPasteInjector.swift`, in `CGEventKeystrokeSender.sendCmdV`, replace this block:

```swift
            down.flags = .maskCommand
            up.flags = .maskCommand
            down.post(tap: .cgAnnotatedSessionEventTap)
            up.post(tap: .cgAnnotatedSessionEventTap)
```

with:

```swift
            down.flags = .maskCommand
            up.flags = .maskCommand
            // Mark as Howl-originated so the any-key cancel monitor ignores
            // our own paste keystrokes (defense in depth: the monitor is
            // stopped before this fires on the .result path, but the marker
            // keeps it correct regardless of ordering).
            down.markAsHowlSynthetic()
            up.markAsHowlSynthetic()
            down.post(tap: .cgAnnotatedSessionEventTap)
            up.post(tap: .cgAnnotatedSessionEventTap)
```

- [ ] **Step 3: Verify the package builds**

Run: `cd mac/Packages/HowlCore && swift build`
Expected: Build succeeds with no errors.

- [ ] **Step 4: Run the full package test suite (no regressions)**

Run: `cd mac/Packages/HowlCore && swift test`
Expected: PASS — all tests, including Task 1 + Task 2 suites.

- [ ] **Step 5: Commit**

```bash
git add mac/Packages/HowlCore/Sources/HowlCore/Injection/CGEventTextTyper.swift \
        mac/Packages/HowlCore/Sources/HowlCore/Injection/ClipboardPasteInjector.swift
git commit -m "feat(cancel): stamp Howl marker on injected keystrokes (streaming + paste)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Keep the cancel monitor armed through processing

**Files:**
- Modify: `mac/Howl/Engine/EngineCoordinator.swift` (the `onRelease()` method)

No unit test: `EngineCoordinator` is an app-target `@MainActor` type wired to the live composition and `NSEvent`; this codebase verifies it by build + manual testing. The arming/disarming on terminal events (`.result`, `.cancelled`, `.error`) and `manualReset` already exists and is unchanged — this task only removes the early disarm on PTT release.

- [ ] **Step 1: Remove the early disarm in `onRelease`**

In `mac/Howl/Engine/EngineCoordinator.swift`, the `onRelease()` method currently starts:

```swift
    private func onRelease() async {
        log.info("onRelease: setting state=processing, stopping Swift capture, signaling engine EOI")
        composition.appState.engineState = .processing
        composition.cancelKeyMonitor.stop()
        // Stop the mic FIRST so no more frames push into the engine.
        composition.audioCapture.stop()
```

Replace that block with (deletes the `cancelKeyMonitor.stop()` line and explains why):

```swift
    private func onRelease() async {
        log.info("onRelease: setting state=processing, stopping Swift capture, signaling engine EOI")
        composition.appState.engineState = .processing
        // NOTE: do NOT stop the cancel-key monitor here. It must stay armed
        // through processing so any key still aborts the in-flight pipeline
        // (transcription / LLM / injection). It is disarmed on the terminal
        // events (.result / .cancelled / .error) and in manualReset.
        // Stop the mic FIRST so no more frames push into the engine.
        composition.audioCapture.stop()
```

- [ ] **Step 2: Build the app**

Run: `cd mac && make build`
Expected: Build succeeds (regenerates project if needed, then xcodebuild Debug). This also rebuilds the Go dylib via the preBuild phase; a clean build is expected.

- [ ] **Step 3: Commit**

```bash
git add mac/Howl/Engine/EngineCoordinator.swift
git commit -m "feat(cancel): keep cancel monitor armed through processing

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: Confirm the cancel decision is wired end-to-end (read-through)

No code. A quick static confirmation that the pieces connect, before manual testing.

- [ ] **Step 1: Confirm the wiring**

Verify each link by reading the code:

- `mac/Howl/Composition/CompositionRoot.swift` — `cancelKeyMonitor = CancelKeyMonitor { eng.cancelCapture() }` (onCancel → engine cancel). Unchanged; confirm it still reads this way.
- `mac/Howl/Engine/EngineCoordinator.swift` — `onPress()` calls `composition.cancelKeyMonitor.start()` after `startCapture()`; `onRelease()` no longer stops it (Task 4); `handle(.result/.cancelled/.error)` and `manualReset()` still stop it.
- `cancelCapture()` → `howl_cancel_capture()` aborts the pipeline and emits `cancelled` (no change needed — `core/cmd/libhowl/exports.go`).

Expected: all links present. If `CompositionRoot` no longer wires `onCancel` to `cancelCapture`, stop and reconcile before continuing.

---

### Task 6: Manual verification

No code. Run the built app and walk the manual checklist from the spec. Build/launch via the project's run path (`cd mac && make run`, or the `run` skill).

- [ ] **Step 1: Held trigger does not self-cancel**

Hold the PTT hotkey and speak for ~5s, then release normally. Expected: recording proceeds, result is injected — holding the trigger never triggers a cancel.

- [ ] **Step 2: Cancel during recording**

Start recording (hold PTT), and while still recording press any other key (e.g. `a`). Expected: recording aborts immediately; overlay hides; no text injected; state returns to idle.

- [ ] **Step 3: Cancel during the "thinking" window**

Dictate and release so the engine is in processing (transcription / LLM, before any text appears). Press any key. Expected: pipeline aborts; no text injected; state returns to idle.

- [ ] **Step 4: Cancel mid-stream (streaming LLM)**

With a streaming LLM provider configured, dictate a long sentence so streamed text starts appearing in the document. Press any key mid-stream. Expected: further typing stops; whatever was already typed stays in the document; state returns to idle. Critically: the streamed text appearing does NOT itself cancel (the marker filter works).

- [ ] **Step 5: Esc still cancels**

Confirm Escape during recording or processing still cancels (it's now just one of "any key").

- [ ] **Step 6: Normal completion still works**

Dictate and release without pressing any other key. Expected: full result is injected normally; no spurious cancel.

- [ ] **Step 7: Final commit (if any notes/docs updated)**

If Steps 1–6 surfaced no code changes, nothing to commit. If a fix was needed, commit it with a `fix(cancel): ...` message and re-run the affected checklist steps.

---

## Self-Review

**Spec coverage:**
- Any key (not just Esc) cancels → Task 2 (`shouldCancel`, any-key monitor) + Task 2 tests.
- Works during recording AND processing, including mid-stream → Task 4 (keep armed) + Task 6 Steps 2–4.
- Aborts whole pipeline, partial mid-stream text stays → existing `cancelCapture`/`howl_cancel_capture` (Task 5 confirms wiring) + Task 6 Step 4.
- Held PTT trigger never self-cancels → Task 6 Step 1.
- Howl's injected keystrokes never self-cancel → Task 1 (marker) + Task 3 (stamp both injectors) + Task 2 (`ignoresHowlSyntheticKey`).
- `.keyDown` only (bare modifiers don't cancel) → Task 2 implementation (`matching: .keyDown`).
- No Go/core changes → confirmed; Task 5 only reads `exports.go`.
- Tests: marker round-trip (Task 1), monitor cancels on any/Esc + ignores synthetic + `shouldCancel` (Task 2), updated `ignoresOtherKeys`→`cancelsOnAnyKey` (Task 2). All present.

**Placeholder scan:** No TBD/TODO/"handle edge cases"/"add tests for the above" — every code step shows full code; every run step shows command + expected output.

**Type consistency:** `HowlSyntheticEvent.marker: Int64` defined in Task 1; consumed identically in `markAsHowlSynthetic`/`isHowlSynthetic` (Task 1), `CancelKeyMonitor.shouldCancel(userData: Int64)` (Task 2), and the injectors (Task 3). `eventSourceUserData` read via `getIntegerValueField` and written via `setIntegerValueField` consistently. Test seam names (`simulateKeyForTest`, `simulateSyntheticKeyForTest`, `simulateEscForTest`) match between monitor and tests.
