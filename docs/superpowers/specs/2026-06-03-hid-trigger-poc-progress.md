# HID Trigger POC — progress / where we left off

**Last updated:** 2026-06-08
**Branch:** `feat/hid-trigger-poc`
**Spec:** [2026-06-03-hid-trigger-poc-design.md](./2026-06-03-hid-trigger-poc-design.md)

## Status

Full POC **implemented, builds, and unit-tested** — both phase 1 (discovery)
and phase 2 (learn-the-next-button), plus the keyboard+HID fan-in and UI.
**Not yet validated against real hardware** (IOKit runtime + the Input
Monitoring TCC prompt can only be confirmed by running the app with a device).

- HowlCore: `swift test` → **185 tests pass** (+21 for this feature).
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

## Next step — manual device validation

1. `make run`. Menu bar → **HID Trigger → Start discovery (log mode)**; grant Input
   Monitoring when prompted. Press buttons; watch Console (`category: hid`) for
   `HID discovery BUTTON vid=… pid=… button=…`.
2. **Learn trigger…** (menu or Settings → Hotkey): press the button → it captures,
   persists `settings.hidBinding`, and goes live in bound mode.
3. Hold the bound button → recording starts; release → stops. Confirm the keyboard
   hotkey still works simultaneously (both active).
4. Try the three target devices: foot pedal, multi-button mouse, gamepad (digital
   button, not analog trigger).

## Open items / caveats

- **Entitlement/sandbox not verified** for Input Monitoring — confirm the prompt
  actually appears and `IOHIDManagerOpen` succeeds for this (non-sandboxed) app.
- **Gamepad brand quirks**: PlayStation/Switch Pro = clean HID; Xbox may be quirky
  over USB / via GameController framework.
- **Keyboard-emulating foot pedals** won't work via HID (they're on the keyboard
  page, deliberately ignored) — those would use the keyboard hotkey path.

## Future work (post-validation, per spec)

- Unify into `TriggerBinding = .keyboard | .hid` enum + single binding UI/router.
- Polished Settings → Hotkey UI for device/element selection.
- Configurable stop semantics if "last release wins" is ever wanted.
