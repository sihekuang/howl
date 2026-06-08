# HID Trigger POC — progress / where we left off

**Last updated:** 2026-06-08
**Branch:** `feat/hid-trigger-poc`
**Spec:** [2026-06-03-hid-trigger-poc-design.md](./2026-06-03-hid-trigger-poc-design.md)

## Status

Full POC **implemented, builds, unit-tested, and hardware-validated** — both
phase 1 (discovery) and phase 2 (learn-the-next-button), plus the keyboard+HID
fan-in and UI. Validated end-to-end on a **PS5 DualSense** (2026-06-08): learn
captures a real button, hold-to-record works, and clear works.

- HowlCore: `swift test` → **187 tests pass** (+23 for this feature).
- App: `make build` → **BUILD SUCCEEDED**.

## What's built

| Layer | File(s) | Notes |
|---|---|---|
| Value | `HowlCore/HID/HIDBinding.swift` | vid/pid/usagePage/usage; mirrors `KeyboardShortcut` |
| Arbitration | `HowlCore/HID/TriggerArbiter.swift` | owner-token, `os_unfair_lock`; first-source-owns-stop |
| Monitor seam | `HowlCore/HID/HIDTriggerMonitor.swift` | protocol: `start(binding?,…)`, `learnNextBinding`, `stop` |
| Learn logic | `HowlCore/HID/HIDLearnFilter.swift` | **pure** eligibility (reject keyboard page / GD axes / up-edge) |
| IOKit | `HowlCore/HID/IOHIDTriggerMonitor.swift` | `Mode` enum: `.bound` / `.discovery` / `.learn`; listen mode, main run loop |
| Permission | `HowlCore/Permissions/HIDInputMonitoringPermission.swift` | wraps `IOHIDCheckAccess`/`RequestAccess(listenEvent)` |
| Settings | `HowlCore/Storage/SettingsStore.swift` | `hidBinding: HIDBinding?` + legacy nil-fallback decode |
| Wiring | `Howl/Composition/CompositionRoot.swift`, `Howl/Engine/EngineCoordinator.swift` | arbiter fan-in; `learn/discovery/clear/cancel` flows; HID non-fatal |
| State | `Howl/StateMachine/AppState.swift` | `hidLearning: Bool` (learn-mode UI hint) |
| UI | `Howl/UI/Settings/HotkeyTab.swift` (+ `SettingsView.swift`), `Howl/UI/MenuBar/MenuBarMenu.swift` (+ `HowlApp.swift`) | Hotkey-tab section + "HID Trigger ▸" submenu |

Tests (`HowlCore/Tests/HowlCoreTests/`): `HIDBindingTests` (2), `TriggerArbiterTests`
(7), `HIDTriggerRoutingTests` (4, uses `FakeHIDTriggerMonitor`),
`UserSettingsHIDBindingTests` (3), `HIDLearnFilterTests` (5).

## Key decisions

- **Single binding** (one device + one element), not chords/multiple — per POC scope.
- **Listen-only** (non-seizing): the bound element still does its normal job; bind a
  spare element.
- **HID is non-fatal**: keyboard dictation works regardless of HID permission/availability.
- **Learn captures only digital button-down edges**: `HIDLearnFilter` rejects the
  keyboard usage page (0x07) and continuous Generic Desktop axes (0x30–0x38).
- **Discovery** logs every edge; buttons (page 0x09) at `.notice`, pointer axes suppressed.
- **No self-stop race**: learn clears `mode` then the coordinator does the single
  ordered stop()+start(bound) to release/rebind.

## Hardware validation — DONE (2026-06-08, PS5 DualSense)

Validated learn → hold-to-record → clear end-to-end. Confirmed: learn waits for
and captures a real Button-page element (`usagePage=0x9`), press/release are
clean discrete edges, and the keyboard hotkey stays active alongside. Two bugs
were found and fixed during validation:

1. **Learn captured vendor-stream noise.** The DualSense streams continuous
   vendor reports on HID page `0xFF00`; the original `HIDLearnFilter` accepted
   non-button pages, so learn "captured" garbage within ~100ms before any button
   press, then bound to a continuously-changing value → recording jammed on.
   **Fix:** `HIDLearnFilter` accepts only the Button page (`0x09`);
   `EngineCoordinator.startHIDTrigger` guards the same way (`acceptsUsagePage`),
   so a stale non-button binding self-heals (skipped at startup) instead of
   re-jamming. Regression test (`vendorDefinedStreamIsIgnored`) reproduces the
   exact `054C:0CE6 / 0xFF00` capture.

2. **Clear (and freshly-learned binding) didn't show in the UI.** Learn/clear
   update the settings store via the coordinator, but the Settings view binds to
   its own stale `@State` copy, so the row never refreshed. **Fix:** the binding
   flows through observable `appState.hidBinding`; the Hotkey tab mirrors it via
   `.onChange` so the row updates live and a later save of another field can't
   clobber it.

Still untried: foot pedal and multi-button mouse (only the DualSense was on
hand). The D-pad (hat switch) and analog triggers are intentionally **not**
learnable — use a face/shoulder button.

## Open items / caveats

- **Input Monitoring confirmed working** (non-sandboxed app): the TCC prompt
  appears and `IOHIDManagerOpen` succeeds once the built-in retry rides out the
  trust-cache lag (first attempt returns `rc=-536870201`, attempt 2/3 succeeds).
  No special entitlement needed.
- **Pre-existing, unrelated: ggml-metal aborts on app *quit*.** Quitting Howl
  triggers `SIGABRT` in `libggml-metal` during static-destructor teardown
  (`ggml_metal_device_free` → `ggml_abort`), so a crash report is written on
  every quit. It's in the Go/Whisper-Metal core, not the HID code — surfaced
  here only because it generated a confusing crash report mid-validation.
  Should be tracked/fixed separately.
- **Only the Button page (0x09) is learnable** — hat switches/D-pad and analog
  triggers are excluded by design; keyboard-emulating foot pedals won't work via
  HID (they're on the keyboard page) and would use the keyboard hotkey path.
- **Gamepad brand quirks** still apply for non-DualSense controllers (Xbox over
  USB / via GameController framework).

## Future work (post-validation, per spec)

- Unify into `TriggerBinding = .keyboard | .hid` enum + single binding UI/router.
- Polished Settings → Hotkey UI for device/element selection.
- Configurable stop semantics if "last release wins" is ever wanted.
