# Voice Keyboard — Swift Mac App Design (Plan 2)

**Status:** Draft, awaiting user review
**Date:** 2026-04-29
**Scope:** SwiftUI Mac app that wraps the `libvkb.dylib` C ABI shipped by Plan 1 (Phase 1 Go core). Produces a working `.app` bundle for personal/dev use; commercial signing/notarization deferred to a separate plan.

---

## 1. Context

Plan 1 shipped `libvkb.dylib` with an 8-function C ABI (`vkb_init`, `vkb_configure`, `vkb_start_capture`, `vkb_stop_capture`, `vkb_poll_event`, `vkb_destroy`, `vkb_last_error`, `vkb_free_string`) and a CLI test harness (`vkb-cli`) that proves the full pipeline works end-to-end. This plan builds the SwiftUI Mac app that consumes the dylib.

The Phase 1 design spec (`2026-04-29-voice-keyboard-phase-1-design.md` Section 5) already covers the Swift architecture at a high level. This document fills in the implementation-level decisions.

---

## 2. Project structure

```
voice-keyboard/
├── core/                                  # Plan 1 (Go core, shipped)
└── mac/
    ├── VoiceKeyboard.xcodeproj            # Xcode project (the .app target)
    ├── VoiceKeyboard/                     # App-specific sources
    │   ├── VoiceKeyboardApp.swift         # @main, MenuBarExtra scene
    │   ├── AppDelegate.swift              # NSApp lifecycle, accessibility checks
    │   ├── Composition/
    │   │   └── CompositionRoot.swift      # the only place that says ConcreteImpl()
    │   ├── UI/
    │   │   ├── MenuBar/                   # NSStatusItem-style controller
    │   │   ├── Overlay/                   # NSPanel + waveform Canvas
    │   │   ├── Settings/                  # Settings { } scene, tabbed
    │   │   └── FirstRun/                  # download wizard
    │   ├── Resources/Assets.xcassets      # menu bar icons (idle/listening/processing)
    │   ├── VoiceKeyboard.entitlements     # Microphone, Accessibility usage descriptions
    │   └── Info.plist                     # NSMicrophoneUsageDescription, etc.
    └── Packages/
        └── VoiceKeyboardCore/             # Local Swift package
            ├── Package.swift
            ├── Sources/VoiceKeyboardCore/
            │   ├── Bridge/
            │   │   ├── CoreEngine.swift          # protocol
            │   │   ├── LibvkbEngine.swift        # impl: calls libvkb C ABI, JSON marshaling
            │   │   ├── EngineEvent.swift         # event types from the C ABI
            │   │   └── module.modulemap          # imports core/build/libvkb.h
            │   ├── Hotkey/
            │   │   ├── HotkeyMonitor.swift       # protocol
            │   │   └── CGEventHotkeyMonitor.swift  # CGEventTap impl
            │   ├── Injection/
            │   │   ├── TextInjector.swift        # protocol
            │   │   └── ClipboardPasteInjector.swift
            │   ├── Permissions/
            │   │   └── AccessibilityPermissions.swift
            │   └── Storage/
            │       ├── SettingsStore.swift       # protocol + UserDefaults impl
            │       └── SecretStore.swift         # protocol + Keychain impl
            └── Tests/VoiceKeyboardCoreTests/    # Swift Testing, runs via `swift test`
```

**Why split the package out:** every type in `VoiceKeyboardCore` is non-UI logic with clean protocol boundaries. Splitting forces the discipline of "no SwiftUI / NSApplication imports here" and means you can `cd mac/Packages/VoiceKeyboardCore && swift test` without ever opening Xcode. The Xcode app target depends on the package; it owns only the SwiftUI / AppKit composition.

**Bundle identifier:** `com.voicekeyboard.app` (placeholder; rename via Xcode project settings before shipping commercially).
**Product name:** `VoiceKeyboard`.
**Min macOS:** 13.0 (matches Phase 1 spec; required for `MenuBarExtra`).
**Swift:** 6.0 with strict concurrency enabled (greenfield, no migration cost).

---

## 3. libvkb.dylib build integration

Two Xcode build phases on the app target:

1. **Run Script (pre-build):** `make -C "$SRCROOT/../core" build-dylib`. Halts the build on Go failure. Output: `core/build/libvkb.dylib` and `core/build/libvkb.h`.
2. **Copy Files (Frameworks destination):** copies `core/build/libvkb.dylib` into `VoiceKeyboard.app/Contents/Frameworks/`. Xcode signs whatever lands there.

The Bridge `module.modulemap` declares `core/build/libvkb.h` as a system module:

```
module VKBCore [system] {
    header "../../../../../core/build/libvkb.h"
    link "vkb"
    export *
}
```

Swift code does `import VKBCore` and calls `vkb_init()` etc. directly. The `link "vkb"` line tells Xcode to link against `libvkb.dylib`; the path is set via `-L"$SRCROOT/../core/build"` in the Xcode "Library Search Paths" build setting and an `@rpath/libvkb.dylib` entry in `LD_RUNPATH_SEARCH_PATHS` set to `@executable_path/../Frameworks`.

**Outcome:** ⌘R rebuilds the Go core, embeds `libvkb.dylib`, and launches the app. Single-button workflow.

---

## 4. App lifecycle

### Cold launch

```
[AppDelegate] applicationDidFinishLaunching
   │
   ▼
[CompositionRoot] wires:
   - SettingsStore (UserDefaults)
   - SecretStore   (Keychain)
   - LibvkbEngine  (calls vkb_init + vkb_configure)
   - CGEventHotkeyMonitor
   - ClipboardPasteInjector
   - AccessibilityPermissions
   │
   ▼
[Setup gate] check 3 conditions in order:
   ① Accessibility permission granted?  (AXIsProcessTrustedWithOptions)
   ② Whisper model file present?        (~/Library/Application Support/VoiceKeyboard/models/...)
   ③ Anthropic API key in Keychain?
   │
   ├─── all yes → [MenuBarExtra] enters "ready" state, hotkey monitor starts
   │
   └─── any no  → [FirstRunWindow] opens, walks user through gates in order
                  After each gate satisfied, re-runs the setup gate.
```

### First-run wizard

Three panels, presented strictly in order (Accessibility first because it's the only one requiring the user to leave the app to System Settings):

1. **Welcome + Accessibility.** "VoiceKeyboard needs Accessibility permission to capture your hotkey and paste cleaned text." Button opens System Settings → Privacy & Security → Accessibility. Wizard polls `AXIsProcessTrusted()` once a second; advances when granted.

2. **Whisper model.** "Choose a transcription model" — radio list (Tiny/Base/Small/Medium/Large) with size and speed annotations, **Small selected by default** (per Phase 1 spec). Click Download → progress bar streams from `https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-{size}.en.bin` to `~/Library/Application Support/VoiceKeyboard/models/`. Cancel button supported. Failed downloads (network, disk full) surface inline error with retry.

3. **Anthropic API key.** "Paste your API key" — `SecureField` for entry. "Where do I get one?" link opens `https://console.anthropic.com/`. Valid key syntax checked client-side (`sk-ant-...`). On submit, write to Keychain via `SecretStore`.

After all three: wizard closes, MenuBarExtra goes from "Setup required" → "Ready", hotkey monitor starts.

### Steady-state PTT cycle

```
USER PRESSES ⌥⌘Space (key down)
   │
   ▼
[Hotkey] CGEventHotkeyMonitor.onPress fires
   │
   ▼
[MenuBar] icon switches to "listening" state (animated waveform mic)
[Overlay] NSPanel appears bottom-center with live waveform
   │
   ▼
[Engine] vkb_start_capture()  → Go core's pipeline.Run goroutine starts
   │
   ▼
[Engine] poll loop drains vkb_poll_event every 30ms:
   │       - kind:"level"   → overlay's WaveformView appends RMS sample
   │       - kind:"warning" → menu bar shows transient warning state
   │       - kind:"error"   → log + idle, overlay hides
   │
   ▼
USER RELEASES ⌥⌘Space (key up)
   │
   ▼
[Hotkey] onRelease fires
   │
   ▼
[Engine] vkb_stop_capture() → Go pipeline finishes processing
[MenuBar] icon switches to "processing" (spinner)
[Overlay] flips to processing state (spinner instead of waveform)
   │
   ▼
[Engine] poll loop receives kind:"result"
   │
   ▼
[Injector] ClipboardPasteInjector:
   1. read NSPasteboard contents (all types)
   2. write Result.cleaned to pasteboard
   3. CGEventPost synthetic ⌘V
   4. wait 50ms
   5. restore saved pasteboard contents
   │
   ▼
[MenuBar] icon back to "ready"
[Overlay] hides
```

### State machine (Swift side, single source of truth)

```
┌────────┐  hotkey down   ┌───────────┐  hotkey up   ┌────────────┐
│  Idle  │ ─────────────▶ │ Recording │ ───────────▶ │ Processing │
└────────┘                └───────────┘              └────────────┘
   ▲                            │                          │
   │                            │ Esc                      │
   │                            ▼                          │
   │                       ┌─────────┐                     │
   └────────── paste fired ─┤  Idle   │ ◀──── result ─────┘
                           └─────────┘  (or empty result)
```

The state machine lives on `@MainActor`; transitions are synchronous in Swift. The Go side handles concurrency.

### Cancellation

If the user presses Esc during recording: hotkey monitor emits a cancel signal → `vkb_stop_capture` followed by `vkb_destroy` + `vkb_init` + `vkb_configure` to fully reset → discards the in-flight pipeline → no paste fires.

### Polling cadence

Every 30ms the engine drains all queued events from `vkb_poll_event` until it returns NULL. 30ms is fast enough that overlay updates feel live, slow enough that we don't burn CPU. Drains a batch per tick to avoid backing up.

### Hotkey-paste interaction

Synthesizing ⌘V while the user still holds ⌥⌘ produces ⌥⌘⌘V at the OS level. The state machine guarantees paste only fires in `Processing`, *after* the hotkey is fully released.

---

## 5. Floating overlay

Borderless `NSPanel` with `.floating` window level and `nonactivatingPanel` style mask (so showing it doesn't steal focus from the app the user is typing into).

- **Position:** bottom-center, ~80px above the bottom of the active screen, horizontally centered.
- **States:**
  - **Hidden** (idle).
  - **Listening:** small mic icon + live waveform `Canvas` view rendering the last ~2 seconds of RMS samples (circular buffer).
  - **Processing:** mic icon + small spinner, no waveform.
- **Live audio levels:** `LibvkbEngine` publishes RMS samples (~30Hz) into a Combine publisher / AsyncStream that `WaveformView` subscribes to.

---

## 6. Settings panel

Standard `Settings { }` SwiftUI scene with `TabView`. Four tabs:

- **General:** Whisper model picker (Tiny/Base/Small/Medium/Large) with size + speed annotations, language picker (auto/en/es/...), noise suppression toggle (default on).
- **Hotkey:** displays current shortcut + "Record New Shortcut" button. Recording UI captures the next CGEvent via a temporary tap.
- **Provider:** LLM provider picker (currently `anthropic` only; placeholder for future), model picker (`claude-sonnet-4-6` default), API key field (Keychain-backed `SecureField`).
- **Dictionary:** add/remove/edit custom terms. Live preview optional.

Settings changes write through `SettingsStore` → trigger a debounced `vkb_configure` call to apply to the running engine.

---

## 7. Plan 1.5: Go core delta (RMS event publication)

This change to the Go core must land before the Swift overlay can render a real waveform. Bundled into Plan 2's first task to keep concerns colocated.

### Required Go-core changes

```
core/internal/pipeline/pipeline.go
   - Add a LevelCallback func(float32) field to Pipeline.
   - In captureAndDenoise, after each denoised frame, compute RMS:
       rms := sqrt(mean(frame[i]^2))
   - Call the callback with each RMS sample.

core/cmd/libvkb/exports.go (or state.go)
   - In vkb_start_capture's goroutine, install a LevelCallback that
     pushes event{Kind: "level", RMS: rms} onto e.events channel.
   - Throttle: emit at most one level event per ~33ms (≈30Hz);
     coalesce intermediate frames by taking the max RMS over the
     window (so peaks aren't lost).

core/internal/audio/levels.go (new, ~10 lines)
   - rms helper: math.Sqrt over the per-sample-squared mean.
```

### Where to compute RMS

**Post-denoise**, matching Phase 1 spec section 4. The waveform reflects the cleaned signal that's about to be transcribed: quiet rooms = quiet waveform; loud talker on noisy mic = clean waveform.

### Throttling rationale

DeepFilterNet processes 480-sample frames (10ms each). Naive emission = 100 events/sec, which would bury real `result` events behind a level flood. Coalescing to ~30Hz matches the Swift poll cadence and what the eye perceives as smooth. We pick the **max** RMS over each window so peaks aren't lost.

### Event schema

Already declared in Plan 1's `state.go`; this just lights it up:

```go
type event struct {
    Kind string  `json:"kind"`         // "level" | "result" | "warning" | "error"
    RMS  float32 `json:"rms,omitempty"` // populated when Kind=="level", in [0.0, 1.0]
    Text string  `json:"text,omitempty"`
    Msg  string  `json:"msg,omitempty"`
}
```

`RMS` is float32 in [0.0, 1.0] (clamped). Swift converts to dB or linear gain for visual display.

### Test impact

`pipeline_test.go` gets a new test using a `*levelCollector` fake to assert RMS events fire on real audio. The integration test (`test/integration/full_pipeline_test.go`) gets one new assertion: at least one level event was received.

---

## 8. Error handling

Same graceful-degradation philosophy as Plan 1. The Mac app surfaces:

| Failure | Behavior |
|---|---|
| Mic permission denied | Menu bar shows red mic state. Click → "Microphone access denied" with button to open System Settings. |
| Accessibility permission revoked at runtime | Notification + open settings affordance; injection no-ops until re-granted. |
| Whisper model missing/corrupt | Re-runs the first-run wizard's model panel. |
| API key missing/invalid | LLMError event surfaces transient warning ("LLM cleanup unavailable — check your API key"); raw+dict text still pastes. |
| LLM network error / rate limit / timeout | Same as above. |
| Paste rejected by target app | Falls back to leaving cleaned text on clipboard only; menu bar shows transient "couldn't paste" warning. |
| `vkb_*` C function returns error code | Logged via `os_log`; engine surfaces `vkb_last_error()` string in transient menu-bar warning. |
| Whisper inference produces empty result | Overlay hides silently. No notification, no error. |

**The graceful-degradation principle from Plan 1 carries forward:** the user's words always reach the clipboard if Whisper produced anything, even when the LLM is unavailable.

---

## 9. Testing

### Swift Package (`VoiceKeyboardCore`) — Swift Testing framework

```
Tests/VoiceKeyboardCoreTests/
├── BridgeTests/
│   ├── LibvkbEngineTests.swift          # JSON round-trip, error code mapping
│   └── ConfigSerializationTests.swift   # Codable Config matches Go struct
├── HotkeyTests/
│   ├── KeyboardShortcutTests.swift      # parsing "⌥⌘Space" ↔ keyCode + modifiers
│   └── HotkeyMonitorTests.swift         # synthetic CGEvent injection via fake monitor
├── InjectionTests/
│   └── ClipboardPasteInjectorTests.swift # fake NSPasteboard, fake CGEventPost
├── StorageTests/
│   ├── SettingsStoreTests.swift         # in-memory UserDefaults fake
│   └── SecretStoreTests.swift           # in-memory Keychain fake
└── StateMachineTests.swift              # Idle ↔ Recording ↔ Processing transitions
```

Every concrete type takes its protocol via init parameter. Tests inject fakes — no mocking framework needed. Pure DI.

### Xcode app target

Limited automated testing; the app shell is mostly composition + UI:

```
mac/VoiceKeyboardTests/  (Xcode unit test target)
├── CompositionRootTests.swift           # all required protocols are wired
├── FirstRunStateMachineTests.swift      # gates progress correctly
└── MenuBarStateTests.swift              # icon state matches engine state
```

**No SwiftUI snapshot tests.** Maintenance-heavy for low value at v1.
**No XCUITest end-to-end.** Driving real Accessibility events from a test environment is brittle on macOS.

### Manual smoke test (analog to Plan 1's Task 21)

- [ ] First-run on a fresh user account: wizard walks through all three gates correctly.
- [ ] Hotkey ⌥⌘Space: PTT works in Notes, VS Code, Chrome, Terminal, Slack, password fields.
- [ ] Settings → change hotkey → new hotkey works immediately, old one ignored.
- [ ] Settings → toggle noise suppression → next utterance reflects the change.
- [ ] Settings → add custom dict term → next utterance preserves it verbatim.
- [ ] Pulling the mic permission in System Settings mid-session → menu bar shows "permission needed" affordance, doesn't crash.
- [ ] Network down → speak → cleaned text falls back to raw+dict (LLM warning surfaced).
- [ ] Bad API key in Settings → next utterance surfaces inline error; future utterances after a fix succeed.
- [ ] Quit + relaunch: settings persisted, Keychain key persisted.

---

## 10. Distribution

### v1 (this plan)

Unsigned dev build, run locally. First launch will need:

1. Right-click → Open the first time (Gatekeeper prompt for unsigned binaries).
2. Grant Accessibility in System Settings when the wizard prompts.
3. Grant Microphone in System Settings on first hotkey press (macOS prompts automatically).

### v2 (commercial readiness — separate plan)

Deferred per the Phase 1 brainstorming decision. When commercial:

- Apple Developer ID Application certificate.
- Code-sign every bundled dylib (`libvkb`, `libwhisper`, `libdf`).
- Notarize via `xcrun notarytool`.
- Universal binary (`arm64` + `x86_64`).
- Sparkle for auto-updates.
- DMG packaging.

Plan 2's scope **stops at unsigned dev build**. Commercial-readiness is its own plan when ready.

---

## 11. Plan 2 task structure (preview)

Sketching how Plan 2 will decompose. Final task list lives in the implementation plan; this is just to align expectations:

1. Go-core RMS publication (Section 7's deltas)
2. Swift package skeleton + Bridge module + LibvkbEngine
3. Storage (SettingsStore, SecretStore)
4. Hotkey monitor (CGEventTap)
5. Clipboard paste injector
6. State machine + AppDelegate
7. MenuBarExtra UI + idle/listening/processing icons
8. Floating overlay NSPanel + WaveformView
9. Settings tabs (General/Hotkey/Provider/Dictionary)
10. First-run wizard
11. Xcode build phase + Copy Files for libvkb
12. Manual smoke pass

Roughly 12 tasks. Smaller than Plan 1's 21, but each task is denser (UI + state).

---

## 12. References

- Plan 1 (Go core): `docs/superpowers/plans/2026-04-29-voice-keyboard-go-core.md`
- Phase 1 design: `docs/superpowers/specs/2026-04-29-voice-keyboard-phase-1-design.md`
- Apple Accessibility framework: https://developer.apple.com/documentation/applicationservices/axuielement
- MenuBarExtra (macOS 13+): https://developer.apple.com/documentation/swiftui/menubarextra
- Swift Testing: https://developer.apple.com/documentation/testing
