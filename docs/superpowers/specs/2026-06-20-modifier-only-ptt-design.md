# Modifier-only push-to-talk triggers

**Date:** 2026-06-20
**Status:** Approved design, pending implementation plan

## Problem

The Push-to-talk recorder (Settings → Hotkey) lets the user bind a
key+modifier combo (e.g. `⌃Space`) or the **fn/Globe** key held alone, but
it cannot bind **Control, Option, Command, or Shift held alone** as a
trigger. A user who presses one of those bare modifiers in the recorder
sees nothing happen — the button stays in its "Press a shortcut…" state.

Root cause (two gaps, both currently hardcoded to fn):

1. **Recorder** (`mac/Howl/UI/Settings/HotkeyTab.swift`, `KeyListenerView`):
   macOS does not send `keyDown` for a bare modifier press — those arrive as
   `flagsChanged`. `keyDown` (line ~344) therefore never fires for a lone
   `⌃`/`⌥`/`⌘`. `handleFlagsChanged` (line ~297) only commits a shortcut when
   **fn** is the trigger (it gates on `pendingFn`, set only when `.function`
   is in the flags). A bare Control/Option/Command/Shift press matches neither
   path and is silently dropped.

2. **Runtime** (`mac/Packages/HowlCore/.../Hotkey/CarbonHotkeyMonitor.swift`):
   Even if the recorder emitted a modifier-only shortcut, it is not
   `isFnBased`, so it would route to Carbon `RegisterEventHotKey` with the
   modifier's own keyCode (e.g. `kVK_Control`), which the system rejects —
   modifier keys are not valid base keys for a Carbon hotkey.

## Goal

Let the user hold **any single bare modifier** — Control, Option, Command, or
Shift (and combinations of them) — as a push-to-talk trigger, the same way
fn already works. fn continues to work unchanged.

### Decisions captured during brainstorming

- **Side does not matter** — "either side" of a modifier triggers (left or
  right Control both fire). No left/right distinction.
- **All four modifiers allowed** as standalone holds: `⌃`, `⌥`, `⌘`, `⇧`.
  Shift is included despite firing during normal capital-letter typing — the
  user accepted this tradeoff. Mitigated by a soft warning (see §4).
- **Fire-on-press semantics**: any qualifying modifier press starts dictation,
  release stops it (push-to-talk). This matches the existing fn-alone runtime
  behavior. No minimum-hold debounce in this iteration (YAGNI; can be added
  later if empty/garbage transcriptions become a problem).
- **Approach A** (generalize the existing fn machinery), chosen over a
  separate NSEvent global monitor (unreliable on macOS 15+, per existing code
  comments) or routing everything through one CGEventTap (regresses the
  "combos need no permission" property).
- fn keeps its **existing** representation (`keyCode == kVK_Function`).
  Unification happens only at the *routing* level (`isModifierOnly` /
  `usesEventTap` cover both `kVK_Function` and the new `kVK_None`), not at the
  representation level. `kVK_None` is used **only** for non-fn bare modifiers —
  it must never carry `.fn`, or `isFnLetterCombo` would wrongly match it. The
  §4 warning is a soft, non-blocking caption.

## Non-goals

- Left/right modifier discrimination.
- Double-tap triggers (e.g. double-tap fn like macOS Dictation).
- Minimum-hold duration / debounce before a hold "counts."
- Changing the default PTT (`⌃Space` stays the default).
- Settings migration (the new representation is additive; old values still
  parse).

## Design

### 1. Data model — `HotkeyMonitor.swift` (HowlCore)

`KeyboardShortcut` stays `{ keyCode: UInt16, modifiers: ModifierFlags }`.
Add a "no base key" sentinel and unify the held-modifier concept.

- New constant: `public static let kVK_None: UInt16 = 0xFFFF` — "modifier-only
  trigger, no base key."
- A **modifier-only trigger** is represented as `keyCode == kVK_None`, with
  `modifiers` holding the required set. Examples:
  - Control-alone → `KeyboardShortcut(keyCode: kVK_None, modifiers: [.control])`
  - Control+Option-alone → `(kVK_None, [.control, .option])`
- New computed properties:
  - `isModifierOnly: Bool` — `keyCode == kVK_None` **or** the legacy
    `keyCode == kVK_Function` (old fn-alone / fn+modifier). Both route to the
    event tap.
  - `requiredModifiers: ModifierFlags` — for `kVK_None`: `modifiers`; for
    legacy `kVK_Function`: `modifiers` ∪ `[.fn]` (fn is implied by the legacy
    keyCode). This is the set the runtime tap must see fully held.
  - `usesEventTap: Bool` — `isModifierOnly || isFnLetterCombo`. The single
    routing predicate replacing today's `isFnBased` check at the call site.
- **`kVK_None` never carries `.fn`.** fn-alone / fn+modifier stay on
  `kVK_Function`; fn+letter stays on `(letter, [.fn])`. This keeps the existing
  fn predicates correct: `isFnLetterCombo` (`keyCode != kVK_Function &&
  modifiers.contains(.fn)`) cannot match a `kVK_None` value because its
  modifiers never include `.fn`. The `displayString` `kVK_None` branch is
  reached only for non-fn modifier sets.
- `displayString` gains a modifier-only branch: when `keyCode == kVK_None`,
  render the modifier glyphs only (`⌃`, `⌥`, `⇧`, `⌘` in a stable order), no
  key name. Legacy fn rendering is unchanged.
- Existing `isFnBased`, `isFnKey`, `isFnLetterCombo`, `fnKey`, `defaultPTT`
  stay as-is for backward compatibility.

**Backward compatibility:** a hotkey persisted before this change with
`keyCode == kVK_Function` still decodes and is treated as modifier-only via
the legacy arm of `isModifierOnly` / `requiredModifiers`. No migration.

### 2. Recorder — `HotkeyTab.swift` `KeyListenerView` (app target)

Generalize the fn-only "composing" flow to **any monitored modifier**
(`⌃⌥⌘⇧` and fn). Per the project convention, this UI logic stays in the app
target (`mac/Howl`), not HowlCore.

State (replacing the fn-specific `pendingFn` / `pendingFnNSFlags` / `fnSeen`):
- `composing: Bool` — any monitored modifier currently held.
- `composedNSFlags: NSEvent.ModifierFlags` — latest modifier state while held.
- `committedCombo: Bool` — a base-key combo was just committed via `keyDown`;
  suppresses the trailing modifier-release from committing a modifier-only
  trigger.

`flagsChanged` (via the existing local monitor + responder override →
`handleFlagsChanged`):
- Compute the monitored modifiers currently held (control/option/command/
  shift/fn).
- If any held → `composing = true`, update `composedNSFlags`, and call
  `onKeySeen` with the composed glyph string (live "Last key seen" hint).
- If none held: if `composing && !committedCombo` → commit a modifier-only
  trigger via `onRecord`, then reset `composing`, `committedCombo`. The
  representation depends on whether fn was in the held set:
  - **fn held** → emit the existing fn form `(kVK_Function, mapped(flags) − .fn)`
    (identical to today's `fnShortcut` helper — fn-alone or fn+modifier).
  - **fn not held** → emit `(kVK_None, mapped(flags))` (new — bare
    `⌃`/`⌥`/`⌘`/`⇧` and their combinations).

`keyDown`:
- Escape with no other modifiers → cancel (unchanged).
- A **non-modifier** key (the existing combo path, now unified): commit
  `KeyboardShortcut(keyCode: event.keyCode, modifiers: mapped(flags))` —
  including `.fn` when fn is held (fn+letter), or `[.control]` etc. for plain
  combos. Set `committedCombo = true` so the subsequent modifier-release in
  `flagsChanged` does not also fire. (In practice `onRecord` ends recording
  and tears down the view, but the guard makes the ordering safe regardless.)
- A bare modifier keyCode arriving via `keyDown` (shouldn't normally happen) →
  ignore; `flagsChanged` owns modifier-only.

Behavioral outcomes:
- Hold `⌃`, release → records `⌃`.
- Hold `⌃`, press `Space` → records `⌃Space` (unchanged from today).
- fn-alone, fn+modifier, fn+letter → unchanged.

The pure mapping `NSEvent.ModifierFlags → ModifierFlags` already exists inline;
keep it as a small private helper.

### 3. Runtime — `CarbonHotkeyMonitor.swift` (HowlCore)

Generalize the CGEventTap path from "fn-hardcoded" to "arbitrary required
modifier set."

- `start(_:onPress:onRelease:)`: route on `shortcut.usesEventTap` instead of
  `shortcut.isFnBased`.
  - `isFnLetterCombo` → existing keyDown/keyUp keycode detection (active tap to
    swallow the letter). Unchanged.
  - `isModifierOnly` (bare modifiers and legacy fn) → flagsChanged detection,
    `listenOnly` tap. Store `required = shortcut.requiredModifiers` in place of
    the current `fnRequired`.
  - else → Carbon `RegisterEventHotKey` (no permission). Unchanged.
- In `fnGlobeEventTapCallback` flagsChanged arm, replace the hardcoded
  `var allHeld = flags.contains(.maskSecondaryFn)` seed with a set built from
  `required`:
  - `allHeld = true`
  - require `.maskControl` if `required.contains(.control)`
  - require `.maskAlternate` if `required.contains(.option)`
  - require `.maskCommand` if `required.contains(.command)`
  - require `.maskShift` if `required.contains(.shift)`
  - require `.maskSecondaryFn` if `required.contains(.fn)`
  - fire `firePress()` when all required held, `fireRelease()` otherwise.
- Extract this match into a pure, testable helper (see §5), e.g.
  `static func allModifiersHeld(_ cgFlags: CGEventFlags, required: ModifierFlags) -> Bool`,
  so the bit-mapping is unit-tested independently of the live tap.
- Accessibility requirement: modifier-only triggers need the tap, which needs
  Accessibility — already required by the app for paste injection and for fn
  today. No new permission surface; the existing tapCreate retry/backoff
  applies.

### 4. Display + warning UX — `HotkeyTab.swift`

- The PTT button label uses `settings.hotkey.displayString`, which now renders
  modifier-only triggers as glyphs (§1). No extra UI wiring.
- Add a non-blocking caption shown when the recorded hotkey `isModifierOnly`
  **and** its `requiredModifiers` intersects `[.shift, .command]` (the
  high-traffic modifiers): e.g. *"This key is also used in normal shortcuts —
  dictation will trigger whenever you hold it."* Warn, don't block.
- `SymbolicHotkeyChecker` is keyCode-based; it finds no symbolic conflict for a
  modifier-only trigger and is left unchanged.

### 5. Testing

- **HowlCore SwiftPM tests** (the only target with tests):
  - `KeyboardShortcut` computed properties: `isModifierOnly`, `requiredModifiers`,
    `usesEventTap`, and `displayString` for representative cases —
    `(kVK_None, [.control])`, `(kVK_None, [.control, .option])`, plain combo
    `(kVK_Space, [.control])`, fn-alone legacy `(kVK_Function, [])`, fn+modifier
    legacy `(kVK_Function, [.shift])`, fn+letter `(kVK_U, [.fn])`.
  - The extracted `allModifiersHeld(_:required:)` helper: verify each modifier
    maps to the correct CGEventFlags mask and that all-held / partially-held
    inputs produce the expected boolean.
  - A round-trip `Codable` test confirming a `kVK_None` trigger and a legacy
    `kVK_Function` value both decode correctly (backward compatibility).
- **Recorder & live tap:** AppKit / system-level, not SwiftPM-testable. The
  recorder's commit decision stays a small pure function in the app target;
  verified by manual smoke test:
  - Hold `⌃` → button shows `⌃`; release starts/stops dictation when bound.
  - Hold `⌃` + `Space` → records `⌃Space` (regression check).
  - fn-alone and fn+letter still record and fire (regression check).

## Files touched

- `mac/Packages/HowlCore/Sources/HowlCore/Hotkey/HotkeyMonitor.swift` —
  `kVK_None`, `isModifierOnly`, `requiredModifiers`, `usesEventTap`,
  `displayString` branch.
- `mac/Packages/HowlCore/Sources/HowlCore/Hotkey/CarbonHotkeyMonitor.swift` —
  `usesEventTap` routing, generalized flagsChanged matching, extracted helper.
- `mac/Howl/UI/Settings/HotkeyTab.swift` — generalized recorder composing,
  warning caption.
- `mac/Packages/HowlCore/Tests/HowlCoreTests/` — new unit tests (data model +
  helper).

## Risks / open questions

- **Garbage transcriptions** from very brief modifier taps (e.g. Shift while
  typing). Accepted for this iteration; a minimum-hold debounce is the
  follow-up if it bites.
- **fn representation (resolved):** fn-alone / fn+modifier keep emitting
  `kVK_Function`; only non-fn modifiers use `kVK_None`. This was chosen because
  collapsing fn-alone into `(kVK_None, [.fn])` would make `isFnLetterCombo`
  match it (`keyCode != kVK_Function && contains(.fn)`), mis-rendering and
  mis-routing it. Routing is unified via `isModifierOnly` / `usesEventTap`;
  representation is not. A test asserts a `kVK_Function` value and a `kVK_None`
  value both report `isModifierOnly == true` and `usesEventTap == true`.
- **`displayString` for `kVK_None`:** the sentinel `0xFFFF` has no entry in
  `keyNames`, so the modifier-only branch must `return` before the generic
  `keyName` fallback is reached (which would print `Key65535`). Covered by a
  display unit test.
