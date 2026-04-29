# Voice Keyboard — Phase 1 Design

**Status:** Draft, awaiting user review
**Date:** 2026-04-29
**Scope:** Phase 1 (Mac MVP) — full deliverable per project.md, with the modifications captured during brainstorming

---

## 1. Vision and Differentiators

An open-source, privacy-first voice dictation tool for macOS. The defining differences against incumbents:

- **Local Whisper transcription** (no cloud transcription dependency)
- **User-supplied LLM** for cleanup (Anthropic in v1; provider-agnostic interface)
- **Custom dictionary** for niche vocabulary (technical terms, proper nouns)
- **Filler-word removal** as part of the cleanup pass
- **Open source**, no subscription, no telemetry

Cross-platform (Linux/Windows) is explicit Phase 3 work and informs current architectural choices, but not v1 scope.

---

## 2. Scope

### V1 ships

- Go core library compiled to `libvkb.dylib` via `-buildmode=c-shared`, plus a `vkb-cli` test harness binary
- Audio capture via `malgo` (miniaudio), 48kHz mono float32
- Noise suppression via DeepFilterNet (pinned to a specific upstream version, currently DeepFilterNet3) compiled to `libdf.dylib`, vendored prebuilt
- Whisper transcription via CGo bindings to `libwhisper.dylib` (already installed via Homebrew)
- Custom dictionary fuzzy matching (Levenshtein)
- LLM cleanup with Anthropic via the official `anthropic-sdk-go`, behind an `LLMCleaner` interface
- SwiftUI menu bar app (`MenuBarExtra` scene) with tabbed settings (General / Hotkey / Provider / Dictionary)
- Configurable global hotkey for push-to-talk via `CGEventTap`. Default: ⌥⌘Space.
- Floating recording overlay with live waveform + processing spinner (Wispr Flow-style)
- Clipboard paste injection with save/restore of the original clipboard
- Keychain-backed API key storage; UserDefaults for non-secret settings
- First-run flow: Accessibility permission request, Whisper model download

### V1 does not ship

- VAD (push-to-talk removes the need; we are not building VAD in any phase)
- OpenAI / Ollama LLM providers (interface is in place; concrete impls are Phase 2)
- Metaphone phonetic dictionary matching (Phase 2)
- Multilingual UI strings
- App signing, notarization, universal binary, auto-updates (commercial-readiness work, deferred)
- Linux / Windows builds (Phase 3)

### Activation paradigm

**Push-to-talk only.** Hold the hotkey, speak, release. No toggle mode, no auto-stop. Audio capture is bounded by the keypress, which removes the need for VAD entirely.

---

## 3. Top-Level Architecture

Two binaries that ship together inside one `.app` bundle:

```
┌──────────────────────────────────────────────────────┐
│  VoiceKeyboard.app  (SwiftUI menu bar app)           │
│  - Menu bar icon, status, settings panel             │
│  - Global hotkey monitoring (⌥⌘Space, configurable)  │
│  - Clipboard paste injection                         │
│  - Settings persistence (UserDefaults / Keychain)    │
│  - Floating recording overlay                        │
│                       │                              │
│                       ▼ CGo / C ABI                  │
│  ┌───────────────────────────────────────────────┐   │
│  │ libvkb.dylib  (Go core, c-shared build)       │   │
│  │ - Audio capture (malgo)                       │   │
│  │ - Noise suppression (DeepFilterNet via libdf) │   │
│  │ - Whisper transcription (CGo to libwhisper)   │   │
│  │ - Dictionary fuzzy matching (pure Go)         │   │
│  │ - LLM cleanup (Anthropic impl behind iface)   │   │
│  └───────────────────────────────────────────────┘   │
└──────────────────────────────────────────────────────┘
```

### Why two binaries

- macOS UI work (`MenuBarExtra`, `CGEventTap`, paste injection, Accessibility API, Keychain) is dramatically easier in Swift/AppKit than in any cross-platform Go UI framework.
- Whisper integration, audio pipelining, dictionary matching, and LLM cleanup are easier in Go and **portable to Linux/Windows in Phase 3** without rewriting. That is the load-bearing reason for keeping core logic in Go.
- The CGo / C-ABI seam is the contract between them: small, stable, language-neutral.

### Boundary contract

The C ABI exposes 7 functions: `vkb_init`, `vkb_configure`, `vkb_start_capture`, `vkb_stop_capture`, `vkb_poll_event`, `vkb_destroy`, `vkb_last_error`. Rich types (Config, transcription events, audio level samples) cross the boundary as JSON strings. Mapping nested structs through C is brittle; JSON is trivial to evolve.

The C ABI is **poll-based, not callback-based.** Go cannot safely invoke Objective-C selectors across a CGo boundary mid-call without thread-pinning gymnastics. Swift polls `vkb_poll_event()` on a 30ms timer to drain audio levels and final results. 30ms granularity is invisible to humans.

---

## 4. Go Core Design

### Package layout

Hexagonal / ports-and-adapters. Every collaborator is an interface; concrete impls plug in at composition roots in `cmd/`. No `init()` hidden state, no global singletons.

```
core/                              # Go module: github.com/<owner>/voice-keyboard/core
├── go.mod
├── cmd/
│   ├── vkb-cli/main.go            # CLI test harness (composition root #1)
│   └── libvkb/main.go             # //export functions, c-shared build (composition root #2)
├── internal/
│   ├── audio/
│   │   ├── capture.go             # Capture interface
│   │   ├── malgo_capture.go       # malgo (miniaudio) impl
│   │   └── fake_capture.go        # test impl driven by a WAV file
│   ├── denoise/
│   │   ├── denoiser.go            # Denoiser interface
│   │   ├── deepfilter_cgo.go      # CGo binding to libdf
│   │   └── passthrough.go         # no-op impl when feature disabled
│   ├── resample/
│   │   └── decimate3.go           # 48kHz → 16kHz polyphase FIR
│   ├── transcribe/
│   │   ├── transcriber.go         # Transcriber interface
│   │   └── whisper_cpp.go         # CGo binding to libwhisper
│   ├── dict/
│   │   ├── dictionary.go          # Dictionary interface
│   │   └── fuzzy.go               # Levenshtein impl
│   ├── llm/
│   │   ├── cleaner.go             # Cleaner interface
│   │   └── anthropic.go           # anthropic-sdk-go impl
│   ├── pipeline/
│   │   └── pipeline.go            # Pipeline struct, Run(ctx) method
│   └── config/
│       └── config.go              # Config types, JSON marshaling for C ABI
└── test/integration/              # full-pipeline tests with fakes wired in
```

### Interfaces (signatures sketched)

```go
// audio/capture.go
type Capture interface {
    Start(ctx context.Context, sampleRate int, channels int) (<-chan []float32, error)
    Stop() error
}

// denoise/denoiser.go
type Denoiser interface {
    Process(frame []float32) []float32      // expects 480 samples @ 48kHz
    Close() error
}

// transcribe/transcriber.go
type Transcriber interface {
    Transcribe(ctx context.Context, pcm16k []float32) (string, error)
}

// dict/dictionary.go
type Dictionary interface {
    Match(text string) (corrected string, matchedTerms []string)
}

// llm/cleaner.go
type Cleaner interface {
    Clean(ctx context.Context, text string, preserveTerms []string) (string, error)
}
```

### Pipeline orchestrator

```go
// pipeline/pipeline.go
type Pipeline struct {
    capture     audio.Capture
    denoiser    denoise.Denoiser
    transcriber transcribe.Transcriber
    dict        dict.Dictionary
    cleaner     llm.Cleaner
    decimator   *resample.Decimator
}

func New(c audio.Capture, d denoise.Denoiser, t transcribe.Transcriber,
         dy dict.Dictionary, cl llm.Cleaner) *Pipeline { ... }

// Run executes one PTT cycle: starts capture, waits for stop signal,
// processes the captured audio, returns the cleaned text.
func (p *Pipeline) Run(ctx context.Context, stopCh <-chan struct{}) (Result, error)
```

The pipeline is **single-utterance**, not a long-lived loop. Each PTT press maps to one `Run` call. Lifecycle (start/stop/cancel) lives at the composition root.

### Composition roots

Both `cmd/vkb-cli` and `cmd/libvkb` wire up the same internal packages with the same impls — different surfaces (CLI flags vs. C ABI), same wiring. This is how IoC stays clean: nothing in `internal/` constructs concrete dependencies of other layers.

### Sample-rate handling

```
mic → 48kHz mono float32 → DeepFilterNet (10ms frames, 480 samples)
                        → polyphase 3:1 decimate → 16kHz mono float32 → Whisper
```

Capture is always 48kHz regardless of whether noise suppression is enabled. When the user toggles noise suppression off, the `Denoiser` interface is bound to `passthrough.go` (no-op). The decimation step always runs. This keeps the data path uniform; only the active impl changes.

### LLM cleanup prompt

Per project.md:

```
You are a transcription editor. Clean up the following voice transcription:
- Remove filler words (um, uh, like, you know, basically)
- Fix grammar and punctuation
- Preserve technical terms exactly as listed: {custom_terms}
- Keep meaning intact, do not add new content
- Return only the cleaned text, nothing else

Raw transcription: {text}
```

`{custom_terms}` is populated from `Dictionary.Match`'s `matchedTerms` return value, so we only inject the terms that actually appeared.

---

## 5. Swift App Design

### Package layout

```
mac/VoiceKeyboard/
├── VoiceKeyboard.xcodeproj
└── VoiceKeyboard/
    ├── VoiceKeyboardApp.swift          # @main, MenuBarExtra scene
    ├── AppDelegate.swift               # lifecycle, accessibility checks
    ├── Composition/
    │   └── CompositionRoot.swift       # builds and wires every protocol impl
    ├── Core/
    │   ├── Bridge/
    │   │   ├── libvkb.h                # generated by go build -buildmode=c-shared
    │   │   ├── module.modulemap        # imports the C header into Swift
    │   │   ├── CoreEngine.swift        # protocol
    │   │   └── LibvkbEngine.swift      # impl: calls C ABI, marshals JSON
    │   ├── Hotkey/
    │   │   ├── HotkeyMonitor.swift     # protocol
    │   │   └── CGEventHotkeyMonitor.swift   # CGEventTap impl, keyDown + keyUp
    │   ├── Injection/
    │   │   ├── TextInjector.swift      # protocol
    │   │   └── ClipboardPasteInjector.swift # save → set → ⌘V → restore
    │   ├── Permissions/
    │   │   └── AccessibilityPermissions.swift
    │   └── Storage/
    │       ├── SettingsStore.swift     # protocol + UserDefaults impl
    │       └── SecretStore.swift       # protocol + Keychain impl
    ├── UI/
    │   ├── MenuBar/
    │   │   └── MenuBarController.swift # observes engine state, animates icon
    │   ├── Overlay/
    │   │   ├── RecordingOverlayController.swift   # NSPanel, .floating, non-activating
    │   │   ├── RecordingOverlayView.swift         # state-driven SwiftUI view
    │   │   └── WaveformView.swift                 # SwiftUI Canvas, RMS levels
    │   ├── Settings/
    │   │   ├── SettingsView.swift      # Settings { } scene, tabbed
    │   │   ├── GeneralTab.swift        # Whisper model, language, noise suppression
    │   │   ├── HotkeyTab.swift         # rebind capture
    │   │   ├── ProviderTab.swift       # LLM provider + API key (Keychain)
    │   │   └── DictionaryTab.swift     # custom term editor
    │   └── FirstRun/
    │       └── FirstRunView.swift      # permission grant + model download
    └── Resources/Assets.xcassets       # menu bar icons (idle, listening, processing)
```

### Protocols

```swift
protocol CoreEngine {
    func configure(_ config: Config) async throws
    func startCapture() async throws
    func stopCapture() async throws
    var events: AsyncStream<EngineEvent> { get }     // levels, results, errors
}

protocol HotkeyMonitor {
    func setHotkey(_ shortcut: KeyboardShortcut)
    var onPress: (() -> Void)? { get set }
    var onRelease: (() -> Void)? { get set }
}

protocol TextInjector {
    func inject(_ text: String) async throws
}

protocol SettingsStore { ... }
protocol SecretStore { ... }   // Keychain-backed, never UserDefaults
```

### Composition

`CompositionRoot.swift` is the **only** place that says `LibvkbEngine()` or `ClipboardPasteInjector()`. Every other type takes protocols at construction time. Swap fakes in for tests, swap impls without touching consumers.

### Concurrency model

- All UI on `@MainActor`.
- Engine calls dispatch through an `EngineActor` to serialize C ABI access. The Go core's `vkb_*` functions are not safe to call concurrently for a single engine instance.
- Polling timer (30ms) runs on a non-main task, drains `vkb_poll_event`, sends events into the engine's `AsyncStream`.

---

## 6. Data Flow and State Machine

### One PTT cycle

```
USER PRESSES ⌥⌘Space (key down)
   │
   ▼
[Swift] HotkeyMonitor → MenuBarController.startCapture()
   │
   ▼
[Swift] CoreEngine.startCapture() → C ABI: vkb_start_capture()
   │
   ▼
[Go] pipeline.Run starts: audio.Capture begins streaming PCM frames @ 48kHz
   │   While capture runs:
   │     - Frames pushed into a ring buffer
   │     - DeepFilterNet processes 10ms frames in real time
   │     - RMS levels computed post-denoise, published via C ABI poll
   │     - Swift overlay shows "listening" state with waveform
   │
   ▼
USER RELEASES ⌥⌘Space (key up)
   │
   ▼
[Swift] HotkeyMonitor → MenuBarController.stopCapture()
   │
   ▼
[Swift] CoreEngine.stopCapture() → C ABI: vkb_stop_capture()
   │   (Swift overlay flips to "processing" state)
   │
   ▼
[Go] pipeline finishes capture, calls in sequence:
   │   1. resample.Decimate3 (48kHz → 16kHz)
   │   2. transcribe.Transcribe(audio_buffer) → raw_text
   │   3. dict.Match(raw_text) → text_with_terms_preserved + matched_terms
   │   4. cleaner.Clean(text, matched_terms) → cleaned_text
   │   Result published via C ABI poll mechanism
   │
   ▼
[Swift] LibvkbEngine receives result → MenuBarController.handleResult(text)
   │   - If text is empty → overlay hides, done (no error, no notification)
   │   - If non-empty → TextInjector.inject(text)
   │
   ▼
[Swift] ClipboardPasteInjector:
   │   1. Save current NSPasteboard contents (all types)
   │   2. Write cleaned_text to pasteboard
   │   3. CGEventPost synthetic ⌘V (cmd+v keyDown then keyUp)
   │   4. Wait 50ms for paste to land in target app
   │   5. Restore saved pasteboard contents
   │
   ▼
[Swift] Overlay hides, menu bar back to idle
```

### State machine

Single source of truth, lives on the Swift side. Three states, four transitions:

```
                  hotkey press
            ┌──────────────────────┐
            │                      ▼
       ┌─────────┐            ┌───────────┐
       │  Idle   │ ◄───────── │ Recording │
       └─────────┘  Esc       └───────────┘
           ▲                        │
           │                        │ hotkey release
           │ paste fired            │
           │ (or empty result)      ▼
           │                  ┌──────────────┐
           └──────────────────│  Processing  │
                              └──────────────┘
```

- `Idle` → `Recording`: hotkey press starts capture
- `Recording` → `Processing`: hotkey release ends capture, pipeline runs
- `Processing` → `Idle`: pipeline returns; paste fires for non-empty result, no-ops for empty
- `Recording` → `Idle` (cancel): user presses Esc; capture is discarded, no pipeline runs

### Hotkey-paste interaction

Paste injection during a held hotkey is broken: synthesizing ⌘V while the user still holds ⌥⌘ produces ⌥⌘V at the OS level, which most apps treat as nothing useful. The state machine guarantees paste only fires during `Processing`, *after* the hotkey is fully released.

---

## 7. Build and Distribution

### Toolchain (developer machine)

- macOS 13+ (current dev: macOS 26 / Apple Silicon)
- Go 1.22+ (install via `brew install go`)
- Swift 6.x / Xcode 26 (already installed)
- whisper.cpp (already installed via `brew install whisper-cpp`; provides `libwhisper.dylib`)
- `make`
- **No Rust required** — `libdf.dylib` is vendored prebuilt

### Vendored dependencies

```
vendor/deepfilter/
├── lib/macos-arm64/libdf.dylib    # ~5–10MB, prebuilt by maintainer once
├── include/deep_filter.h          # C header for CGo
└── VERSION.md                     # upstream tag, commit, build date, deployment target
```

The maintainer-only `make rebuild-denoise` target documents how to regenerate `libdf.dylib`: clone DeepFilterNet at the pinned tag, `cargo build --release -p libdf`, copy artifacts, update `VERSION.md`. Requires Rust at that point only.

### Build targets

```
make bootstrap     # check Go, Xcode, brew, whisper.cpp; go mod download
make build-go      # build libvkb.dylib + vkb-cli
make build-swift   # build VoiceKeyboard.app
make build         # build-go + build-swift
make test          # go test ./... + swift test
make rebuild-denoise   # maintainer-only, requires Rust
```

### App bundling

`libdf.dylib`, `libwhisper.dylib`, and `libvkb.dylib` ship inside the `.app` at `Contents/Frameworks/`. Install names rewritten with `install_name_tool -id "@rpath/libname.dylib"` so the loader resolves them from the bundle at runtime.

### End-user distribution

End users download a single `.app` (likely as a `.dmg`). They drag it to `/Applications`, double-click, grant Mic + Accessibility permissions when prompted, and download a Whisper model on first run via in-app UI. Zero terminal usage, zero build tools required.

### Commercial readiness (deferred from v1, additive)

When the project goes commercial:
- Apple Developer ID code signing for every dylib in the bundle
- Notarization via `xcrun notarytool`
- Universal binary support: vendor `libdf.dylib` for both `arm64` and `x86_64`, `lipo`-merge
- Document each vendored binary's deployment target and Rust toolchain in `VERSION.md` for compliance audits
- Sparkle for auto-updates

None of this changes the v1 architecture — it is layered on top of the existing build.

---

## 8. Error Handling

Graceful degradation over modal dialogs. The app is invoked dozens of times a day; modal errors that interrupt typing flow are user-hostile.

| Failure | Behavior |
|---|---|
| Mic permission denied | Red mic icon. Click → "Microphone access denied" + button to open System Settings. |
| Whisper model missing/corrupt | First-run flow surfaces it; in steady state, overlay shows "Model not loaded" and links to General settings. |
| API key missing/invalid | **Graceful degrade:** still transcribe + apply dictionary, paste *that*. Notification once per session: "LLM cleanup unavailable — check your API key." |
| LLM network error / rate limit / timeout | Same as above — paste raw+dict transcription, notification. |
| Accessibility permission revoked at runtime | Notification + open settings button; injection no-ops until re-granted. |
| Paste rejected by target app | Fall back to leaving cleaned text on clipboard only, surface notification with the text shown. |
| `vkb_*` C function returns error code | Logged in Go; surfaced to Swift via `vkb_last_error()`. UI shows generic "Something went wrong" with a "View logs" affordance. |
| Whisper inference produces empty result | Overlay hides silently. No notification, no error. |

The graceful-degradation principle is meaningful: a transcription with filler words is still 90% as useful as a cleaned one. We never lose the user's words to a network blip.

---

## 9. Testing Strategy

### Go core (TDD per the skill)

```
internal/dict/fuzzy_test.go         # pure logic, ~100% coverage
internal/pipeline/pipeline_test.go  # all collaborators are fakes
internal/llm/anthropic_test.go      # httptest.Server for HTTP mocking
internal/transcribe/*_test.go       # short audio fixtures, build-tagged for CI without model
internal/audio/*_test.go            # fake source for unit tests; hardware tests build-tagged
internal/denoise/*_test.go          # before/after RMS comparison on noise fixtures
internal/resample/*_test.go         # frequency-domain check on synthetic signals
test/integration/full_pipeline_test.go
                                    # real impls + fake AudioCapture from a WAV fixture
```

### Swift app

```
ClipboardPasteInjectorTests.swift   # fake NSPasteboard, fake CGEventPost
StateMachineTests.swift             # transitions including cancel during processing
CABIBridgeTests.swift               # JSON round-trip, error code marshaling
SettingsStoreTests.swift            # fake UserDefaults
KeychainStoreTests.swift            # fake Security framework
HotkeyMonitorTests.swift            # synthetic CGEvent injection
```

Every concrete type has a protocol/interface, so every test injects fakes — no mocking frameworks needed, no test doubles for things we don't own.

### Manual / E2E (no automation in v1)

- First-run flow on a clean macOS user account
- Real PTT + paste into Notes, VS Code, Chrome, Terminal, password fields, sandboxed apps
- Permission revocation mid-session
- Network disconnect mid-cleanup
- API key rotated mid-session
- Whisper model deleted mid-session

### CLI test harness (`cmd/vkb-cli`)

```
vkb-cli check                  # verifies whisper.cpp, mic, API key, model file, libdf
vkb-cli capture --out a.wav    # record from mic, dump to WAV
vkb-cli transcribe a.wav       # just the Whisper step
vkb-cli pipe a.wav             # full pipeline: denoise → transcribe → dict → LLM
vkb-cli pipe --live            # PTT-equivalent via stdin keypress, full pipeline
```

The CLI is what we exercise during Go core development. Once `vkb-cli pipe --live` works end to end, the dylib is proven and the Swift work becomes pure UI integration.

---

## 10. Configuration

The Config struct travels across the C ABI as JSON. Stored on disk in `~/Library/Application Support/VoiceKeyboard/config.json` (non-secrets) and the macOS Keychain (API keys).

```go
type Config struct {
    WhisperModelPath    string   // absolute path to Whisper model file
    WhisperModelSize    string   // "tiny" | "base" | "small" | "medium" | "large"
    Language            string   // "en", "es", etc. ("auto" = let Whisper detect)
    NoiseSuppression    bool     // default true
    DeepFilterModelPath string   // absolute path to DeepFilterNet model archive (.tar.gz)
    LLMProvider         string   // "anthropic" (v1)
    LLMModel            string   // e.g. "claude-sonnet-4-6"
    LLMAPIKey           string   // injected by Swift from Keychain at configure time
    CustomDict          []string // user vocabulary
}
```

API keys never persist to `config.json`. Swift reads them from Keychain at startup, injects them into the Config sent over the C ABI, and the Go core holds them only in process memory.

---

## 11. References

- whisper.cpp: https://github.com/ggerganov/whisper.cpp
- DeepFilterNet: https://github.com/Rikorose/DeepFilterNet
- malgo (miniaudio Go bindings): https://github.com/gen2brain/malgo
- anthropic-sdk-go: https://github.com/anthropics/anthropic-sdk-go
- Original project brief: `project.md`
