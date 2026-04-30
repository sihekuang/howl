# In-App Voice Enrollment — Design

**Date:** 2026-04-30
**Goal:** Replace the `enroll.sh`/Python enrollment flow with an in-app Settings UI so users can enable Target Speaker Extraction without touching Terminal.

---

## 1. Problem

The TSE feature ships, but enabling it requires:

1. Running `./enroll.sh` from Terminal (records 10s, runs Python to compute embedding).
2. Running `./run-speaker.sh` (CLI binary, not the Mac app).

The Mac app currently has no awareness of TSE. Users who don't open Terminal cannot use the feature.

## 2. Scope

**In scope (this spec):**

- Swift Settings UI: a new "Voice" tab with record button, status, and a TSE on/off toggle.
- Go: a `ComputeEmbedding()` function using `onnxruntime_go` and `speaker_encoder.onnx`, replacing the Python script.
- C ABI: one new synchronous export `vkb_enroll_compute(samples, count, sample_rate, profile_dir)`. It decimates to 16 kHz, runs the embedding model, and writes `enrollment.wav` + `enrollment.emb` + `speaker.json` atomically to `profile_dir`.
- Pipeline: wire `pipeline.LoadTSE` into the libvkb `buildPipeline` (currently only the vkb-cli code path uses TSE).
- Config: add `tse_enabled`, `tse_profile_dir`, `tse_model_path`, `speaker_encoder_path`, `onnx_lib_path` to `core/internal/config/config.go` and `EngineConfig.swift`.
- UserSettings: persist the user's `tseEnabled` choice.

**Out of scope (deferred):**

- TSE model distribution. This iteration assumes `tse_model.onnx` (~26 MB) and `speaker_encoder.onnx` (~6 MB) already exist at `~/Library/Application Support/VoiceKeyboard/models/`. The Voice tab detects missing models and shows instructions to copy them from `core/build/models/`. Auto-download from a hosted URL or bundling in the .app are explicit follow-ups.
- Multi-profile enrollment (only one speaker profile supported).
- Re-training / fine-tuning. We use the same pre-trained `speaker_encoder.onnx` already in the repo.
- Removing the Python script (`compute_enrollment_embedding.py`). It stays for now as a CLI fallback; we can delete after the in-app flow is verified.

## 3. Non-Goals

- We do not change the TSE model itself. The current ConvTasNet + resemblyzer + hard-argmax pipeline (committed in `aa7c2c5`) is unchanged.
- We do not add any new event kinds for streaming progress during embedding compute. The compute call is synchronous and brief (~100 ms).

## 4. Architecture

### 4.1 Component split

| Component | Responsibility |
|-----------|----------------|
| Swift `VoiceTab` | Settings UI: status, record button, TSE toggle |
| Swift `EnrollmentRecorder` | Collects 10 s of 48 kHz Float32 from `AudioCapture`, returns flat buffer + level callback |
| Swift `EnrollmentSheet` | Modal UI: countdown, level meter, Cancel/Stop |
| Swift `LibvkbEngine.computeEnrollment(...)` | Wraps `vkb_enroll_compute`; returns enrolled-at timestamp on success |
| Go `vkb_enroll_compute` | C export — decimates, computes embedding, writes profile files |
| Go `speaker.ComputeEmbedding` | New: runs `speaker_encoder.onnx` on 16 kHz samples → 256-dim L2-normalised vec |
| Go `speaker.Decimate48to16` | Existing — already in pipeline; expose for reuse |
| Go `pipeline.LoadTSE` | Existing — already used by vkb-cli; we wire it into libvkb's `buildPipeline` |

### 4.2 Data flow — recording

```
User clicks "Record Voice Sample"
        │
        ▼
EnrollmentSheet shows; EnrollmentRecorder.start(audioCapture)
        │
        │  AudioCapture pushes 48 kHz Float32 frames
        │  EnrollmentRecorder accumulates into a flat buffer
        │  Level callback updates the meter
        │
        ▼
After 10 s (or user clicks Stop)
        │
        │  EnrollmentRecorder.stop() → returns [Float] (~480000 samples)
        │
        ▼
LibvkbEngine.computeEnrollment(samples, profileDir):
        │
        │  vkb_enroll_compute(buf, count, sr=48000, profileDir)
        │     ├─ Go: speaker.Decimate48to16(samples)
        │     ├─ speaker.SaveWAV(enrollment.wav, samples16k, 16000)
        │     ├─ speaker.ComputeEmbedding(samples16k)  ← onnxruntime_go
        │     ├─ speaker.SaveEmbedding(enrollment.emb, emb)
        │     └─ speaker.SaveProfile(speaker.json, {Version:1, RefAudio: "...", DurationS: 10.0, EnrolledAt: now})
        │
        ▼
Sheet dismisses, Voice tab updates status to "Enrolled"
TSE toggle becomes active
EngineCoordinator.reapplyConfig() — TSE on if user-enabled
```

### 4.3 Data flow — pipeline boot with TSE

```
EngineCoordinator.applyConfig
        │
        ▼
EngineConfig (now includes tse_enabled + paths)
        │
        ▼
vkb_configure(JSON)
        │
        ▼
state.go buildPipeline:
   if cfg.TSEEnabled {
       tse, ref, err := pipeline.LoadTSE(profileDir, modelPath, onnxLibPath)
       if err != nil → log warning, fall through (TSE off)
       p.TSE = tse; p.TSERef = ref
   }
```

### 4.4 Failure modes

| Failure | Behavior |
|---------|----------|
| Models missing at expected path | Voice tab shows error + manual-copy instructions. Record button disabled. |
| User enables TSE toggle but enrollment is missing | UI prevents this — toggle is disabled until enrolled. |
| Enrollment files exist but corrupt | `LoadTSE` returns error; libvkb logs warning, disables TSE for this session, emits `warning` event. Capture still works. |
| `vkb_enroll_compute` ONNX failure | Returns non-zero rc; Swift shows alert "Failed to compute voice profile: <msg>". No partial files written (atomic temp-then-rename). |
| Mic permission denied during enrollment | `AudioCapture.start` throws; EnrollmentSheet shows "Microphone access required". |

## 5. Detailed component specs

### 5.1 Go: `speaker.ComputeEmbedding`

```go
// ComputeEmbedding runs speaker_encoder.onnx on samples (16 kHz mono PCM)
// and returns a 256-dim L2-normalised float32 embedding.
// Caller is responsible for InitONNXRuntime + opening the session;
// session is closed after Compute returns.
func ComputeEmbedding(modelPath string, samples16k []float32) ([]float32, error)
```

The encoder ONNX expects input `audio: float32[1, T]` and produces `embedding: float32[1, 256]` (already L2-normalised in the export script). `ComputeEmbedding` opens a session, runs once, closes, returns the flat 256-element slice.

### 5.2 Go: `speaker.Decimate48to16`

The existing pipeline has a decimator buried in `pipeline.Run`. Extract it (or use the simple polyphase filter that's already there) into the speaker package as a public function:

```go
// Decimate48to16 down-samples 48 kHz mono to 16 kHz using a 3:1 polyphase filter.
func Decimate48to16(samples48k []float32) []float32
```

If the pipeline's existing decimator is in `internal/audio` already, just expose it; don't duplicate.

### 5.3 C ABI: `vkb_enroll_compute`

```c
// Compute and persist a voice enrollment from a single recorded buffer.
// samples:    Float32 mono PCM
// count:      number of samples
// sampleRate: must be 48000 (we'll only support that for now)
// profileDir: NUL-terminated UTF-8 path; must already exist
//
// On success, writes profileDir/{enrollment.wav, enrollment.emb, speaker.json}
// (atomic — writes to .tmp then renames).
//
// Return codes:
//   0  = success
//   1  = engine not initialized
//   5  = invalid argument (count <= 0, profileDir empty, sr != 48000)
//   6  = compute failed (see vkb_last_error)
int vkb_enroll_compute(const float* samples, int count, int sample_rate, const char* profile_dir);
```

Synchronous; runs on the calling thread. Expected duration: ~100 ms for 10 s of audio. Swift wraps it in `Task.detached` to keep the main thread free. We use a new return-code range (5–6) to distinguish enrollment errors from capture errors (1–4).

### 5.4 Config additions

```go
// core/internal/config/config.go
type Config struct {
    // ... existing fields ...
    TSEEnabled         bool   `json:"tse_enabled"`
    TSEProfileDir      string `json:"tse_profile_dir"`       // ~/Library/Application Support/VoiceKeyboard/voice
    TSEModelPath       string `json:"tse_model_path"`        // .../models/tse_model.onnx
    SpeakerEncoderPath string `json:"speaker_encoder_path"`  // .../models/speaker_encoder.onnx
    ONNXLibPath        string `json:"onnx_lib_path"`         // /opt/homebrew/lib/libonnxruntime.dylib
}
```

`WithDefaults`: leave all empty; the Swift app supplies them. CLI continues to work unchanged (it doesn't set TSE fields, so `tse_enabled` is false).

### 5.5 Swift `EngineConfig`

Mirror the five fields with matching CodingKeys. All optional in the initializer with defaults of `false` / `""` so existing tests don't break.

### 5.6 Swift `UserSettings`

Add:

```swift
public var tseEnabled: Bool = false
```

Persist via the existing `SettingsStore`. EngineCoordinator reads `settings.tseEnabled` and resolves the four paths from `ModelPaths`.

### 5.7 Swift `ModelPaths` additions

```swift
extension ModelPaths {
    static var tseModel: URL { modelsDir.appendingPathComponent("tse_model.onnx") }
    static var speakerEncoder: URL { modelsDir.appendingPathComponent("speaker_encoder.onnx") }
    static var voiceProfileDir: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("VoiceKeyboard/voice")
    }
    static var onnxLib: URL { URL(fileURLWithPath: "/opt/homebrew/lib/libonnxruntime.dylib") }
}
```

### 5.8 Swift `VoiceTab`

A new tab, inserted between General and Hotkey:

```swift
VoiceTab(settings: $settings, onSave: save, audioCapture: composition.audioCapture, engine: composition.engine)
    .tabItem { Label("Voice", systemImage: "person.wave.2") }
```

Sections:

1. **Voice models**
   - Status row: ✓/✗ for each of `tse_model.onnx` and `speaker_encoder.onnx`
   - If missing: instruction text "Copy these files from <repo>/core/build/models/ to ~/Library/Application Support/VoiceKeyboard/models/"
2. **Voice profile**
   - If not enrolled: "Not enrolled" + [Record Voice Sample] button
   - If enrolled: "Enrolled (date, durationS)" + [Re-record] + [Delete] buttons
3. **Filter out background speakers** toggle (disabled unless enrolled and models present)

The record button presents an `EnrollmentSheet` (modal). The sheet uses `audioCapture` directly (it's a one-off recording session — does NOT go through the libvkb capture pipeline).

### 5.9 Swift `EnrollmentSheet`

State machine: `idle → recording → computing → done|cancelled|failed`.

UI:
- Heading: "Record your voice"
- Prompt text: a short paragraph for the user to read (~20 s of natural speech). We provide one fixed prompt.
- Level meter: rolling RMS from the audio callback.
- Status text: "Recording: 7 s remaining" / "Computing voice profile…" / "Done" / error.
- Buttons: [Cancel] / [Stop] (Stop becomes [Done] in the done state).

Recording duration: 10 s default, max 15 s, min 5 s. Auto-stop at 10 s.

Implementation:
- Start: `try await audioCapture.start(deviceUID: settings.inputDeviceUID) { frame in samples.append(contentsOf: frame); /* update level */ }`
- Stop: `audioCapture.stop()`. Handoff samples buffer to engine.
- Engine call: `try await engine.computeEnrollment(samples: samples, sampleRate: 48000, profileDir: ModelPaths.voiceProfileDir.path)`
- On success: write back to `settings.tseEnabled = true` (or leave for the toggle), refresh status, dismiss sheet.

### 5.10 Settings save → engine reapply

When the Voice tab toggles `tseEnabled` or completes enrollment, `onSave(settings)` triggers `EngineCoordinator.reapplyConfig` which builds a new `EngineConfig` (now with TSE fields) and calls `engine.configure`. Standard pattern, no new infrastructure.

## 6. Testing plan

| Layer | Test |
|-------|------|
| Go unit | `TestComputeEmbedding_ReturnsNormalised` — feed silence, verify output is 256 elems, finite, ‖v‖≈1 |
| Go unit | `TestComputeEmbedding_DifferentInputsDifferentEmbeds` — sine vs noise → cosine distance > 0.1 |
| Go unit | `TestDecimate48to16_LengthMatches` — input 48000 → output 16000 |
| Go integration | (existing) TSE pipeline tests still pass |
| C ABI | `TestEnrollCompute_WritesAllArtifacts` — call the export with synthesized audio, verify wav+emb+json exist and are valid |
| C ABI | `TestEnrollCompute_AtomicOnFailure` — mock the ONNX session to fail, verify no partial files left |
| C ABI | `TestEnrollCompute_RejectsBadSampleRate` — sr=44100 → returns 5 |
| Swift unit | `EngineConfigTests` adds round-trip for new fields |
| Swift unit | `UserSettingsTests` — tseEnabled persists |
| Swift integration | (manual) full record-and-test flow in the app |

Manual smoke test: run `./run-streaming.sh` after enrolling via the app — confirm TSE filters a second voice from the same chunk.

## 7. Migration / backward compatibility

- Existing `~/.config/voice-keyboard/` (the old enroll.sh location) is untouched. The app uses `~/Library/Application Support/VoiceKeyboard/voice/` instead. CLI users who care can symlink or just re-enroll.
- Existing `enroll.sh` and `compute_enrollment_embedding.py` continue to work; they're parallel paths. No breaking change.
- `tse_enabled` defaults to false; existing app users see no behavior change until they opt in.

## 8. Open decisions

- **Profile directory location.** I'm using `~/Library/Application Support/VoiceKeyboard/voice/` (separate from `models/`). Alternative: `~/Library/Application Support/VoiceKeyboard/voice-profile/`. Either is fine; this just needs to be consistent across Swift and Go.
- **Prompt text.** The fixed prompt for the user to read. I'll use a paragraph from `assets/enrollment-prompt.txt` so it's editable in code review. Roughly: "The quick brown fox jumps over the lazy dog. Voice keyboards work best when they have a sample of your speaking voice. Please read this paragraph at a normal pace, in your typical speaking tone."

## 9. Implementation order (for the plan)

1. Go: `speaker.ComputeEmbedding` + tests (no new deps; `onnxruntime_go` already linked).
2. Go: expose `Decimate48to16` (likely just a re-export from existing decimator).
3. Go: `vkb_enroll_compute` C export + state.go atomic write helper.
4. Go: wire `LoadTSE` into libvkb `buildPipeline`.
5. Go: extend `Config` with the five TSE fields.
6. Swift: extend `EngineConfig` + `UserSettings` + `ModelPaths`.
7. Swift: `LibvkbEngine.computeEnrollment(...)` wrapper.
8. Swift: `EnrollmentRecorder` (audio buffer accumulator).
9. Swift: `EnrollmentSheet` modal UI.
10. Swift: `VoiceTab` + slot it into `SettingsView`.
11. Swift: `EngineCoordinator.applyConfig` populates TSE fields.
12. Manual end-to-end smoke test.

Each step is independently testable. Steps 1–5 are Go-only; steps 6–11 are Swift-only; step 12 is the integration.
