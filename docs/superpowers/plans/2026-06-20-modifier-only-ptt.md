# Modifier-only Push-to-Talk Triggers Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the user hold a bare modifier (Control / Option / Command / Shift) alone as a push-to-talk trigger, the way fn already works.

**Architecture:** Generalize the existing fn-key machinery. A new `kVK_None` sentinel keyCode represents a non-fn modifier-only trigger; fn keeps its `kVK_Function` representation. The recorder's fn "composing" flow is generalized to any held modifier, and the runtime CGEventTap's hardcoded `maskSecondaryFn` match is generalized to an arbitrary required-modifier set. Key+modifier combos still register through Carbon (no permission).

**Tech Stack:** Swift 6, SwiftUI + AppKit, Carbon Event Manager, CoreGraphics CGEventTap, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-06-20-modifier-only-ptt-design.md`

## Global Constraints

- Swift tools version 6.0; platform floor macOS 14 (`mac/Packages/HowlCore/Package.swift`).
- HowlCore unit tests run with: `cd mac/Packages/HowlCore && swift test` (filter a single suite/test with `--filter <name>`).
- Mac app builds with: `cd mac && make build` (xcodegen + xcodebuild Debug). **Never** hand-edit `Howl.xcodeproj/project.pbxproj`.
- UI-only logic stays in the app target (`mac/Howl`), not HowlCore — even though only HowlCore has unit tests. The recorder (`KeyListenerView`) is app-target and is verified by build + manual smoke test, not unit tests.
- `kVK_None` is `0xFFFF` and must **never** carry `.fn`. fn-alone / fn+modifier stay on `kVK_Function`; fn+letter stays `(letter, [.fn])`.
- End every commit message with:
  `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`
- Work happens on branch `feature/modifier-only-ptt` (already created; the spec is committed there).

## File Structure

- `mac/Packages/HowlCore/Sources/HowlCore/Hotkey/HotkeyMonitor.swift` — data model: `kVK_None`, `isModifierOnly`, `requiredModifiers`, `usesEventTap`, `displayString` branch. **(Task 1)**
- `mac/Packages/HowlCore/Sources/HowlCore/Hotkey/CarbonHotkeyMonitor.swift` — pure `requiredFlagsHeld` helper + generalized routing/match. **(Task 2)**
- `mac/Howl/UI/Settings/HotkeyTab.swift` — generalized recorder composing **(Task 3)** + warning caption **(Task 4)**.
- `mac/Packages/HowlCore/Tests/HowlCoreTests/KeyboardShortcutTests.swift` — data-model tests (extend existing file). **(Task 1)**
- `mac/Packages/HowlCore/Tests/HowlCoreTests/ModifierMatchTests.swift` — new file, `requiredFlagsHeld` tests. **(Task 2)**

---

### Task 1: Data model — `kVK_None` + computed properties + display

**Files:**
- Modify: `mac/Packages/HowlCore/Sources/HowlCore/Hotkey/HotkeyMonitor.swift`
- Test: `mac/Packages/HowlCore/Tests/HowlCoreTests/KeyboardShortcutTests.swift`

**Interfaces:**
- Produces: `KeyboardShortcut.kVK_None: UInt16` (`0xFFFF`); `var isModifierOnly: Bool`; `var requiredModifiers: ModifierFlags`; `var usesEventTap: Bool`; `displayString` renders modifier-only as glyphs only.

- [ ] **Step 1: Write the failing tests**

Append these to `mac/Packages/HowlCore/Tests/HowlCoreTests/KeyboardShortcutTests.swift`, inside the `struct KeyboardShortcutTests` body (before the closing brace):

```swift
    @Test func controlAloneIsModifierOnly() {
        let s = KeyboardShortcut(keyCode: KeyboardShortcut.kVK_None, modifiers: [.control])
        #expect(s.isModifierOnly)
        #expect(s.usesEventTap)
        #expect(s.requiredModifiers == [.control])
        #expect(!s.isFnBased)
        #expect(!s.isFnLetterCombo)
    }

    @Test func multiModifierOnlyRequiresAll() {
        let s = KeyboardShortcut(keyCode: KeyboardShortcut.kVK_None, modifiers: [.control, .option])
        #expect(s.isModifierOnly)
        #expect(s.requiredModifiers == [.control, .option])
    }

    @Test func fnAloneStaysModifierOnly() {
        let s = KeyboardShortcut(keyCode: KeyboardShortcut.kVK_Function, modifiers: [])
        #expect(s.isModifierOnly)
        #expect(s.usesEventTap)
        #expect(s.requiredModifiers.contains(.fn))
    }

    @Test func fnModifierRequiresFnAndCompanion() {
        let s = KeyboardShortcut(keyCode: KeyboardShortcut.kVK_Function, modifiers: [.shift])
        #expect(s.isModifierOnly)
        #expect(s.requiredModifiers.contains(.fn))
        #expect(s.requiredModifiers.contains(.shift))
    }

    @Test func plainComboIsNotModifierOnly() {
        let s = KeyboardShortcut(keyCode: KeyboardShortcut.kVK_Space, modifiers: [.control])
        #expect(!s.isModifierOnly)
        #expect(!s.usesEventTap)
        #expect(s.requiredModifiers == [.control])
    }

    @Test func fnLetterUsesTapButIsNotModifierOnly() {
        let s = KeyboardShortcut(keyCode: 32 /* U */, modifiers: [.fn])
        #expect(!s.isModifierOnly)
        #expect(s.isFnLetterCombo)
        #expect(s.usesEventTap)
    }

    @Test func displayStringModifierOnlyShowsGlyphsOnly() {
        let one = KeyboardShortcut(keyCode: KeyboardShortcut.kVK_None, modifiers: [.control])
        #expect(one.displayString == "⌃")
        let two = KeyboardShortcut(keyCode: KeyboardShortcut.kVK_None, modifiers: [.control, .option])
        #expect(two.displayString == "⌃⌥")
        #expect(!one.displayString.contains("Key"))
    }

    @Test func modifierOnlyRoundTripsCodable() throws {
        let s = KeyboardShortcut(keyCode: KeyboardShortcut.kVK_None, modifiers: [.control, .command])
        let data = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(KeyboardShortcut.self, from: data)
        #expect(back == s)
        #expect(back.isModifierOnly)
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd mac/Packages/HowlCore && swift test --filter KeyboardShortcut`
Expected: compile error — `kVK_None`, `isModifierOnly`, `requiredModifiers`, `usesEventTap` do not exist yet.

- [ ] **Step 3: Add the sentinel constant**

In `mac/Packages/HowlCore/Sources/HowlCore/Hotkey/HotkeyMonitor.swift`, add `kVK_None` right after the `kVK_Function` constant (line 15):

```swift
    public static let kVK_Function: UInt16 = 63
    /// Sentinel keyCode meaning "no base key" — a modifier-only trigger
    /// (Control/Option/Command/Shift held alone). fn-based triggers do NOT
    /// use this; they keep `kVK_Function`. Must never carry `.fn`.
    public static let kVK_None: UInt16 = 0xFFFF
```

- [ ] **Step 4: Add the computed properties**

In the same file, add these right after the `isFnLetterCombo` property (after line 39, before `displayString`):

```swift
    /// True for any trigger with no base key: bare modifiers (`kVK_None`) or
    /// the legacy fn-alone / fn+modifier form (`kVK_Function`). Both are
    /// watched via the CGEventTap flagsChanged path, not Carbon RegisterEventHotKey.
    public var isModifierOnly: Bool {
        keyCode == Self.kVK_None || keyCode == Self.kVK_Function
    }

    /// The full modifier set the runtime tap must see held. `kVK_Function`
    /// implies `.fn` (fn is encoded in the keyCode, not the modifier set).
    public var requiredModifiers: ModifierFlags {
        keyCode == Self.kVK_Function ? modifiers.union(.fn) : modifiers
    }

    /// True for any trigger handled by the CGEventTap rather than Carbon:
    /// modifier-only holds and fn+letter combos.
    public var usesEventTap: Bool {
        isModifierOnly || isFnLetterCombo
    }
```

- [ ] **Step 5: Add the `displayString` modifier-only branch**

In the same file, change the start of `displayString` (currently line 41-42) from:

```swift
    public var displayString: String {
        if isFnBased {
```

to:

```swift
    public var displayString: String {
        if keyCode == Self.kVK_None {
            var s = ""
            if modifiers.contains(.control) { s += "⌃" }
            if modifiers.contains(.option)  { s += "⌥" }
            if modifiers.contains(.shift)   { s += "⇧" }
            if modifiers.contains(.command) { s += "⌘" }
            return s.isEmpty ? "None" : s
        }
        if isFnBased {
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `cd mac/Packages/HowlCore && swift test --filter KeyboardShortcut`
Expected: PASS (all `KeyboardShortcut` tests, including the new ones and the pre-existing three).

- [ ] **Step 7: Commit**

```bash
cd /Users/daniel/Documents/Projects/voice-keyboard
git add mac/Packages/HowlCore/Sources/HowlCore/Hotkey/HotkeyMonitor.swift \
        mac/Packages/HowlCore/Tests/HowlCoreTests/KeyboardShortcutTests.swift
git commit -m "feat(hotkey): model modifier-only triggers (kVK_None)

Add kVK_None sentinel + isModifierOnly/requiredModifiers/usesEventTap and a
glyph-only displayString branch. fn keeps its kVK_Function representation.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Runtime — pure flag-match helper + generalized tap

**Files:**
- Modify: `mac/Packages/HowlCore/Sources/HowlCore/Hotkey/CarbonHotkeyMonitor.swift`
- Test: `mac/Packages/HowlCore/Tests/HowlCoreTests/ModifierMatchTests.swift` (create)

**Interfaces:**
- Consumes: `KeyboardShortcut.usesEventTap`, `KeyboardShortcut.requiredModifiers` (Task 1).
- Produces: `static func CarbonHotkeyMonitor.requiredFlagsHeld(_ flags: CGEventFlags, required: ModifierFlags) -> Bool` (internal; visible to tests via `@testable import`).

- [ ] **Step 1: Write the failing tests**

Create `mac/Packages/HowlCore/Tests/HowlCoreTests/ModifierMatchTests.swift`:

```swift
import CoreGraphics
import Testing
@testable import HowlCore

@Suite("requiredFlagsHeld")
struct ModifierMatchTests {
    @Test func controlHeldMatchesControlRequirement() {
        #expect(CarbonHotkeyMonitor.requiredFlagsHeld([.maskControl], required: [.control]))
    }

    @Test func controlNotHeldFailsControlRequirement() {
        #expect(!CarbonHotkeyMonitor.requiredFlagsHeld([], required: [.control]))
    }

    @Test func extraHeldFlagsDoNotBreakMatch() {
        // Required is just control; command also held -> still matches.
        #expect(CarbonHotkeyMonitor.requiredFlagsHeld([.maskControl, .maskCommand], required: [.control]))
    }

    @Test func allOfMultiRequirementMustBeHeld() {
        #expect(CarbonHotkeyMonitor.requiredFlagsHeld([.maskControl, .maskAlternate], required: [.control, .option]))
        #expect(!CarbonHotkeyMonitor.requiredFlagsHeld([.maskControl], required: [.control, .option]))
    }

    @Test func eachModifierMapsToCorrectMask() {
        #expect(CarbonHotkeyMonitor.requiredFlagsHeld([.maskAlternate], required: [.option]))
        #expect(CarbonHotkeyMonitor.requiredFlagsHeld([.maskCommand], required: [.command]))
        #expect(CarbonHotkeyMonitor.requiredFlagsHeld([.maskShift], required: [.shift]))
        #expect(CarbonHotkeyMonitor.requiredFlagsHeld([.maskSecondaryFn], required: [.fn]))
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd mac/Packages/HowlCore && swift test --filter requiredFlagsHeld`
Expected: compile error — `requiredFlagsHeld` is not a member of `CarbonHotkeyMonitor`.

- [ ] **Step 3: Add the pure helper**

In `mac/Packages/HowlCore/Sources/HowlCore/Hotkey/CarbonHotkeyMonitor.swift`, add this method inside the `CarbonHotkeyMonitor` class, right after the `carbonModifiers(from:)` method (after line 218):

```swift
    /// True when every modifier in `required` is present in the live CGEvent
    /// flags. Pure and side-effect free so the bit-mapping is unit-testable
    /// without a live event tap. Extra held modifiers are ignored (a control
    /// trigger still fires when command is also down).
    static func requiredFlagsHeld(_ flags: CGEventFlags, required: ModifierFlags) -> Bool {
        if required.contains(.control), !flags.contains(.maskControl)     { return false }
        if required.contains(.option),  !flags.contains(.maskAlternate)   { return false }
        if required.contains(.command), !flags.contains(.maskCommand)     { return false }
        if required.contains(.shift),   !flags.contains(.maskShift)       { return false }
        if required.contains(.fn),      !flags.contains(.maskSecondaryFn) { return false }
        return true
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd mac/Packages/HowlCore && swift test --filter requiredFlagsHeld`
Expected: PASS.

- [ ] **Step 5: Generalize the tap routing in `start(_:onPress:onRelease:)`**

In the same file, change the fn branch entry (line 63) from:

```swift
        if shortcut.isFnBased {
            fnRequired = shortcut.modifiers
            fnLetterKeyCode = shortcut.isFnLetterCombo ? Int64(shortcut.keyCode) : -1
```

to:

```swift
        if shortcut.usesEventTap {
            fnRequired = shortcut.requiredModifiers
            fnLetterKeyCode = shortcut.isFnLetterCombo ? Int64(shortcut.keyCode) : -1
```

(`fnRequired` / `fnEventTap` keep their fn-era names but now hold the general required-modifier set; the field is only consumed in the modifier-only branch of the callback.)

- [ ] **Step 6: Generalize the flagsChanged match in the callback**

In the same file, in `fnGlobeEventTapCallback`, replace the modifier-only block (currently lines 258-273):

```swift
    // fn-alone / fn+modifier mode: detect via flagsChanged.
    guard type == .flagsChanged else { return Unmanaged.passUnretained(event) }
    let flags = event.flags
    let rawFlags = flags.rawValue
    var allHeld = flags.contains(.maskSecondaryFn)
    log.info("CGEventTap flagsChanged: raw=0x\(String(format: "%X", rawFlags), privacy: .public) maskSecondaryFn=\(allHeld, privacy: .public)")
    let req = monitor.fnRequired
    if req.contains(.shift)   { allHeld = allHeld && flags.contains(.maskShift) }
    if req.contains(.control) { allHeld = allHeld && flags.contains(.maskControl) }
    if req.contains(.option)  { allHeld = allHeld && flags.contains(.maskAlternate) }
    if req.contains(.command) { allHeld = allHeld && flags.contains(.maskCommand) }

    DispatchQueue.main.async {
        if allHeld { monitor.firePress() } else { monitor.fireRelease() }
    }
    return Unmanaged.passUnretained(event)
```

with:

```swift
    // modifier-only mode (bare modifiers, or fn-alone / fn+modifier): detect via flagsChanged.
    guard type == .flagsChanged else { return Unmanaged.passUnretained(event) }
    let flags = event.flags
    let allHeld = CarbonHotkeyMonitor.requiredFlagsHeld(flags, required: monitor.fnRequired)
    log.info("CGEventTap flagsChanged: raw=0x\(String(format: "%X", flags.rawValue), privacy: .public) allHeld=\(allHeld, privacy: .public)")
    DispatchQueue.main.async {
        if allHeld { monitor.firePress() } else { monitor.fireRelease() }
    }
    return Unmanaged.passUnretained(event)
```

- [ ] **Step 7: Build HowlCore to verify it compiles, and re-run the full HowlCore suite**

Run: `cd mac/Packages/HowlCore && swift test`
Expected: build succeeds; all tests PASS (no regressions in the existing hotkey/HID/settings suites).

- [ ] **Step 8: Commit**

```bash
cd /Users/daniel/Documents/Projects/voice-keyboard
git add mac/Packages/HowlCore/Sources/HowlCore/Hotkey/CarbonHotkeyMonitor.swift \
        mac/Packages/HowlCore/Tests/HowlCoreTests/ModifierMatchTests.swift
git commit -m "feat(hotkey): route modifier-only triggers through the event tap

Add pure requiredFlagsHeld helper; route on usesEventTap and match an
arbitrary required-modifier set instead of hardcoded maskSecondaryFn.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: Recorder — capture bare modifiers in `KeyListenerView`

**Files:**
- Modify: `mac/Howl/UI/Settings/HotkeyTab.swift`

**Interfaces:**
- Consumes: `KeyboardShortcut.kVK_None`, `KeyboardShortcut(keyCode:modifiers:)` (Task 1).
- Produces: recorder emits `(kVK_None, mods)` for non-fn modifier holds, `(kVK_Function, mods − fn)` for fn holds, `(key, mods)` for combos.

This is app-target UI; it has no SwiftPM unit test. It is verified by `make build` plus a manual smoke test.

- [ ] **Step 1: Replace the composing state variables**

In `mac/Howl/UI/Settings/HotkeyTab.swift`, replace the three fn-specific state vars (lines 244-247):

```swift
    // Composing state: fn-press starts composing; fn-release commits the
    // recorded combo (fn alone, fn+Shift, fn+Control, etc.).
    private var pendingFn = false
    private var pendingFnNSFlags: NSEvent.ModifierFlags = []
    // Shared debounce guard (local monitor + responder override).
    private var fnSeen = false
```

with:

```swift
    // Composing state: any monitored modifier down starts composing; full
    // release commits a modifier-only trigger (⌃ alone, ⌃⌥, fn, fn+⇧, …).
    private var composing = false
    private var composedNSFlags: NSEvent.ModifierFlags = []
    // Set when a key+modifier combo is committed via keyDown, so the trailing
    // modifier release in flagsChanged does not also commit a modifier-only trigger.
    private var committedCombo = false
    // Modifiers we treat as triggers (incl. fn/Globe via .function).
    private let monitoredFlags: NSEvent.ModifierFlags = [.control, .option, .command, .shift, .function]
```

- [ ] **Step 2: Update the teardown reset**

In the same file, in `removeLocalMonitor()`, replace the reset lines (currently 288-290):

```swift
        pendingFn = false
        pendingFnNSFlags = []
        fnSeen = false
```

with:

```swift
        composing = false
        composedNSFlags = []
        committedCombo = false
```

- [ ] **Step 3: Rewrite `handleFlagsChanged`**

Replace the whole `handleFlagsChanged` method (currently lines 294-317) with:

```swift
    // Called by both the local monitor and the responder-chain override.
    // Any monitored modifier down enters composing; full release commits the
    // held modifier set as a modifier-only trigger (unless a combo was just
    // committed via keyDown).
    private func handleFlagsChanged(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(monitoredFlags)
        if !flags.isEmpty {
            composing = true
            composedNSFlags = flags
            let desc = composedDisplay(flags)
            log.info("KeyListenerView composing: \(desc, privacy: .public)")
            onKeySeen?(desc)
        } else if composing {
            composing = false
            if committedCombo {
                committedCombo = false
                return
            }
            let shortcut = modifierOnlyShortcut(from: composedNSFlags)
            log.info("KeyListenerView modifier-only committed: \(shortcut.displayString, privacy: .public)")
            onRecord?(shortcut)
        }
    }
```

- [ ] **Step 4: Replace the fn-specific helpers with general ones**

Replace `composedFnDisplay` and `fnShortcut` (currently lines 319-338) with:

```swift
    private func composedDisplay(_ flags: NSEvent.ModifierFlags) -> String {
        var s = ""
        if flags.contains(.function) { s += "fn" }
        if flags.contains(.control)  { s += "⌃" }
        if flags.contains(.option)   { s += "⌥" }
        if flags.contains(.shift)    { s += "⇧" }
        if flags.contains(.command)  { s += "⌘" }
        return s
    }

    private func mappedModifiers(_ flags: NSEvent.ModifierFlags) -> ModifierFlags {
        var mods: ModifierFlags = []
        if flags.contains(.shift)    { mods.insert(.shift) }
        if flags.contains(.control)  { mods.insert(.control) }
        if flags.contains(.option)   { mods.insert(.option) }
        if flags.contains(.command)  { mods.insert(.command) }
        if flags.contains(.function) { mods.insert(.fn) }
        return mods
    }

    /// Build a modifier-only trigger from a flags-only hold. fn-based holds keep
    /// the legacy kVK_Function representation; non-fn holds use kVK_None.
    private func modifierOnlyShortcut(from flags: NSEvent.ModifierFlags) -> HowlCore.KeyboardShortcut {
        let mods = mappedModifiers(flags)
        if mods.contains(.fn) {
            return HowlCore.KeyboardShortcut(
                keyCode: HowlCore.KeyboardShortcut.kVK_Function,
                modifiers: mods.subtracting(.fn)
            )
        }
        return HowlCore.KeyboardShortcut(
            keyCode: HowlCore.KeyboardShortcut.kVK_None,
            modifiers: mods
        )
    }
```

- [ ] **Step 5: Rewrite `keyDown`**

Replace the whole `keyDown(with:)` method (currently lines 344-390) with:

```swift
    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let desc = "kc=\(event.keyCode) flags=0x\(String(flags.rawValue, radix: 16))"
        log.info("KeyListenerView.keyDown \(desc, privacy: .public)")

        // Escape cancels — ignore fn if it's held alongside.
        let nonFnFlags = flags.subtracting(.function)
        if event.keyCode == UInt16(kVK_Escape) && nonFnFlags.isEmpty {
            composing = false
            committedCombo = false
            onCancel?()
            return
        }

        onKeySeen?(desc)

        // A bare key with no modifier is not a valid trigger (it would capture
        // ordinary typing). Require at least one monitored modifier — including
        // fn, which makes fn+letter valid.
        guard !flags.intersection(monitoredFlags).isEmpty else {
            log.debug("KeyListenerView: ignoring key with no modifiers")
            return
        }

        let shortcut = HowlCore.KeyboardShortcut(keyCode: event.keyCode, modifiers: mappedModifiers(flags))
        committedCombo = true
        log.info("KeyListenerView combo committed: \(shortcut.displayString, privacy: .public)")
        onRecord?(shortcut)
    }
```

- [ ] **Step 6: Build the app**

Run: `cd mac && make build`
Expected: build succeeds with no errors. (Resolves any leftover references to the deleted `pendingFn` / `fnShortcut` / `composedFnDisplay` — there should be none.)

- [ ] **Step 7: Manual smoke test of the recorder**

Run: `cd mac && make run`. In the app: Settings → Hotkey → click the Push-to-talk button to start recording, and confirm each of:
- Hold **Control**, release → button label becomes `⌃`.
- Hold **Option** → release → `⌥`. Hold **Command** → release → `⌘`. Hold **Shift** → release → `⇧`.
- Hold **Control + Space** → records `⌃Space` (regression: combo still works).
- Press **fn** alone → records `fn` (regression). Press **fn + U** → records `fn U` (regression).
- Press **Esc** while recording → cancels, label reverts.

- [ ] **Step 8: Commit**

```bash
cd /Users/daniel/Documents/Projects/voice-keyboard
git add mac/Howl/UI/Settings/HotkeyTab.swift
git commit -m "feat(hotkey): record bare modifiers as push-to-talk triggers

Generalize the recorder's fn composing flow to any held modifier. Full
release with no base key commits a modifier-only trigger; combos and fn
behave as before.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: UX — warning caption for high-traffic modifier-only triggers

**Files:**
- Modify: `mac/Howl/UI/Settings/HotkeyTab.swift`

**Interfaces:**
- Consumes: `KeyboardShortcut.isModifierOnly`, `KeyboardShortcut.requiredModifiers` (Task 1).

- [ ] **Step 1: Add the caption**

In `mac/Howl/UI/Settings/HotkeyTab.swift`, in the `body`, immediately after the `if isRecording, let lastSeen { … }` block (currently ends at line 98) and before the `if !conflicts.isEmpty {` block, insert:

```swift
            if settings.hotkey.isModifierOnly,
               !settings.hotkey.requiredModifiers.intersection([.shift, .command]).isEmpty {
                Text("This key is also used in normal shortcuts — dictation will trigger whenever you hold it.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
```

- [ ] **Step 2: Build the app**

Run: `cd mac && make build`
Expected: build succeeds.

- [ ] **Step 3: Manual visual check**

Run: `cd mac && make run`. In Settings → Hotkey:
- Record **Command** alone → the orange caption appears under the button.
- Record **Shift** alone → caption appears.
- Record **Control** alone → caption does **not** appear (Control is low-traffic).
- Record **⌃Space** → caption does not appear (not modifier-only).

- [ ] **Step 4: Commit**

```bash
cd /Users/daniel/Documents/Projects/voice-keyboard
git add mac/Howl/UI/Settings/HotkeyTab.swift
git commit -m "feat(hotkey): warn when a modifier-only trigger is high-traffic

Show a soft, non-blocking caption when the bound trigger is Shift/Command
alone, since those fire during normal use.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: End-to-end manual verification (integration gate, no commit)

**Files:** none (verification only).

Requires Accessibility permission granted (modifier-only triggers use the CGEventTap, like fn). Run `cd mac && make run`, then:

- [ ] **Step 1: Bind Control alone**
Settings → Hotkey → record → hold/release **Control** → label shows `⌃`. The binding saves (the button stops showing "Press a shortcut…").

- [ ] **Step 2: Dictate with the bare modifier**
Hold **Control** → the recording overlay/pill appears (press fired). Speak. Release **Control** → recording stops and the transcription is injected (release fired). Confirm via Console if needed:
Run: `/usr/bin/log show --last 2m --predicate 'subsystem == "com.howl.app" AND category == "Hotkey"' --info | grep -E "PTT|press fired|release fired"`
Expected: `PTT (CGEventTap/fn): tap registered` then `PTT press fired` / `PTT release fired` on hold/release.

- [ ] **Step 3: Regression — combo still works**
Re-bind **⌃Space**, confirm `PTT (Carbon) start: hotkey registered` in the log and that hold-to-talk works.

- [ ] **Step 4: Regression — fn still works**
Re-bind **fn** alone, confirm it records as `fn` and triggers dictation on hold/release.

- [ ] **Step 5: Update spec status**
Edit `docs/superpowers/specs/2026-06-20-modifier-only-ptt-design.md` header `Status:` to `Implemented`, then:
```bash
cd /Users/daniel/Documents/Projects/voice-keyboard
git add docs/superpowers/specs/2026-06-20-modifier-only-ptt-design.md
git commit -m "docs(hotkey): mark modifier-only PTT spec implemented

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Self-Review

**Spec coverage:**
- §1 data model → Task 1 (kVK_None, isModifierOnly, requiredModifiers, usesEventTap, displayString).
- §2 recorder → Task 3 (generalized composing, fn vs kVK_None representation, combo guard).
- §3 runtime → Task 2 (usesEventTap routing, requiredFlagsHeld, generalized callback).
- §4 display + warning → Task 1 (glyph display) + Task 4 (warning caption).
- §5 testing → Task 1 (data-model tests), Task 2 (helper tests + full-suite run), Tasks 3-5 (build + manual smoke/regression).
- Backward compat (legacy fn `kVK_Function`) → Task 1 tests `fnAloneStaysModifierOnly`, `fnModifierRequiresFnAndCompanion`; Task 5 step 4.

**Placeholder scan:** none — every code step shows complete code; every run step shows command + expected.

**Type consistency:** `kVK_None: UInt16`, `isModifierOnly: Bool`, `requiredModifiers: ModifierFlags`, `usesEventTap: Bool`, `requiredFlagsHeld(_ flags: CGEventFlags, required: ModifierFlags) -> Bool`, `modifierOnlyShortcut(from:) -> HowlCore.KeyboardShortcut`, `mappedModifiers(_:) -> ModifierFlags` — used consistently across tasks. The runtime field `fnRequired` is intentionally reused (now holds `requiredModifiers`).
