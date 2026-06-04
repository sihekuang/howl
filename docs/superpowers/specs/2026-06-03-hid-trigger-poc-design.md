# HID Trigger POC

**Date:** 2026-06-03
**Status:** Approved

## Problem

Recording is triggered today only by the keyboard: `CarbonHotkeyMonitor`
(`mac/Packages/HowlCore/Sources/HowlCore/Hotkey/CarbonHotkeyMonitor.swift`)
registers a `KeyboardShortcut` via Carbon `RegisterEventHotKey` (or a
CGEventTap for the fn/Globe key) and calls `onPress`/`onRelease`. There is
no IOKit/HID code anywhere in the codebase, so users cannot trigger
dictation from a foot pedal, a multi-button mouse, a gamepad, or any other
HID device.

This is a proof-of-concept to prove we can listen to arbitrary HID devices
and trigger recording, **alongside** the existing keyboard hotkey (multiple
trigger sources live at once), with clean dependency injection so the seam
is testable and the keyboard path is untouched.

## Goals

- Listen to arbitrary HID devices (foot pedal, mouse extra buttons, gamepad)
  using IOKit `IOHIDManager`, driverless, in passive listen mode.
- A chosen HID element start/stops a real recording end-to-end through the
  existing engine seam (`engine.startCapture()` / `stopCapture()`).
- Keyboard hotkey and HID trigger are **both active simultaneously**.
- Everything injected behind protocols; keyboard path unchanged; new units
  unit-testable with fakes.

## Non-Goals (POC scope)

- No unified `TriggerBinding` enum refactor (that is the productionization
  follow-on — see "Future work").
- No polished Settings UI; binding selection is minimal (see "Binding
  selection").
- No per-app trigger profiles, no multi-button/chord HID combos.
- No seizing/remapping of device input — we listen only, never consume.

## Decision

Add a **peer** HID trigger monitor next to the keyboard monitor, fan both
into a small **owner-token arbiter**, and inject all new units through
`CompositionRoot`. Stop semantics: **first source owns the session** — the
source that started a recording is the only one that can stop it; other
sources are ignored until it releases.

## Architecture

```
CarbonHotkeyMonitor  ──(source: .keyboard)──┐
IOHIDTriggerMonitor  ──(source: .hid)───────┼─▶ TriggerArbiter ─▶ onPress/onRelease ─▶ engine.start/stopCapture
(future sources)     ──(source: .x)─────────┘   (owner-token)
```

Each monitor keeps its existing closure-based interface (`onPress` /
`onRelease`). The arbiter **vends** those closures per source, wrapping them
with owner-token logic. `EngineCoordinator.onPress` therefore only ever sees
real start transitions — no re-entrancy guards needed in the coordinator,
and `CarbonHotkeyMonitor` is literally unchanged.

## New Components

All live in the `HowlCore` SwiftPM package, behind protocols.

### `HIDBinding` (value type)

`Codable, Equatable, Sendable`. Identifies the chosen device + element,
mirroring how `KeyboardShortcut` describes a keyboard trigger.

```swift
public struct HIDBinding: Codable, Equatable, Sendable {
    public var vendorID: Int
    public var productID: Int
    public var usagePage: Int   // element's usage page
    public var usage: Int       // element's usage
}
```

### `HIDTriggerMonitor` protocol + `IOHIDTriggerMonitor`

```swift
public protocol HIDTriggerMonitor: Sendable {
    /// Begin listening. `binding == nil` means discovery/log mode
    /// (no trigger fires; all device elements are logged).
    func start(_ binding: HIDBinding?,
               onPress: @escaping @Sendable () -> Void,
               onRelease: @escaping @Sendable () -> Void) async throws
    func stop()
}
```

`IOHIDTriggerMonitor` wraps `IOHIDManager`:
- Match-all device dictionary; opened in **listen** mode (passive,
  non-seizing) so the device's normal function (mouse clicks, gamepad
  input) is preserved.
- Scheduled on the main run loop; registers an input-value callback.
- A bound element going to its "down" logical value fires `onPress`; back to
  "up" fires `onRelease`.
- On device removal mid-hold, fires a synthetic release so the arbiter token
  cannot get stuck.

### `TriggerArbiter` (owner-token)

```swift
public final class TriggerArbiter: Sendable {
    public init(onStart: @escaping @Sendable () -> Void,
                onStop:  @escaping @Sendable () -> Void)
    public func source(_ id: TriggerSourceID)
        -> (onPress: @Sendable () -> Void, onRelease: @Sendable () -> Void)
}

public enum TriggerSourceID: Hashable, Sendable { case keyboard, hid }
```

Owner-token rules (owner field guarded by `os_unfair_lock`, since edges
arrive from Carbon's main thread and the HID run loop):
- press + no owner  → set owner = source, call `onStart`.
- press + owner set  → ignore.
- release + source is owner → clear owner, call `onStop`.
- release + source is not owner → ignore.

Pure and fully unit-testable.

### `HIDInputMonitoringPermission` protocol + default impl

Thin wrapper over `IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)` and
`IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)`. Input Monitoring is a
**separate** TCC permission from the Accessibility permission the keyboard
path already uses.

## Dependency Injection

`CompositionRoot` (`mac/Howl/Composition/CompositionRoot.swift`) gains peer
dependencies next to `hotkey`:

```swift
public let hidTrigger: any HIDTriggerMonitor = IOHIDTriggerMonitor()
public let hidPermission: any HIDInputMonitoringPermission = DefaultHIDInputMonitoringPermission()
```

`EngineCoordinator.start()` builds the arbiter and starts both monitors
through it (keyboard call site otherwise unchanged):

```swift
let arbiter = TriggerArbiter(
    onStart: { [weak self] in Task { @MainActor in await self?.onPress() } },
    onStop:  { [weak self] in Task { @MainActor in await self?.onRelease() } }
)
let kb = arbiter.source(.keyboard)
try await composition.hotkey.start(settings.hotkey, onPress: kb.onPress, onRelease: kb.onRelease)

let hid = arbiter.source(.hid)
try await composition.hidTrigger.start(settings.hidBinding,
                                       onPress: hid.onPress, onRelease: hid.onRelease)
```

`stop()`, `reapplyConfig()`, and `pauseHotkeyForRecording()` extend to the
HID monitor symmetrically.

## Binding Selection (POC)

Two phases, same `IOHIDTriggerMonitor`:

1. **Discovery/log mode** (`binding == nil`): enumerate all HID devices, log
   VID/PID/usages and every element edge. Validates IOKit + the Input
   Monitoring prompt with zero UI; lets us read the IDs for the pedal, mouse
   side-buttons, and gamepad.
2. **Learn-the-next-button**: capture the next non-keyboard element edge,
   persist it as `settings.hidBinding`. The real product UX; works uniformly
   across all three test devices.

Ship phase 1 first (instantly runnable, proves the hard part), then phase 2.

`SettingsStore` gains an optional `hidBinding: HIDBinding?` (nil = no HID
trigger bound), decoded with a nil fallback so existing settings keep
loading.

## Permissions

On `start`, check `IOHIDCheckAccess`. If not granted, call
`IOHIDRequestAccess` (triggers the system prompt) and surface a clear
message through the existing `appState` warning channel — same pattern as the
Accessibility flow. Recording via keyboard keeps working regardless of HID
permission state.

## Testing

- `TriggerArbiter` unit tests: first-owner wins; non-owner press ignored;
  non-owner release ignored; owner release clears token; device-disconnect
  force-release.
- `FakeHIDTriggerMonitor` + existing mock engine: an HID press routes to
  `startCapture()`; a keyboard press during an HID-owned session is ignored;
  HID release stops capture.
- `IOHIDTriggerMonitor` itself is validated manually against the three real
  devices (foot pedal, multi-button mouse, gamepad) via discovery-log mode.

## Risks

- **Permission UX**: Input Monitoring prompt only appears on first
  `IOHIDDeviceOpen`; if denied, listening silently no-ops. Mitigation:
  explicit check + warning surface.
- **Thread safety**: edges from two run loops mutate the arbiter token —
  guarded by `os_unfair_lock`.
- **Built-in keyboard**: opening the built-in keyboard as HID is restricted;
  we match all devices but only *bind* a user-chosen non-keyboard element, so
  this does not block the POC.

## Future Work (post-POC)

- Approach 2: unify into a `TriggerBinding = .keyboard | .hid` enum with one
  settings field, one binding UI, and a router — replacing the two parallel
  fields once the POC is validated.
- Settings → Hotkey tab UI for HID device/element selection mirroring the
  existing key-listener.
- Configurable stop semantics if "last release wins" is ever wanted.
