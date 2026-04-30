# Speaker TSE (Target Speaker Extraction) — Design Doc

**Date:** 2026-04-30
**Branch:** `feat/speaker-tse` (off `main`)
**Status:** Approved

## Goal

Enable voice dictation in noisy environments — including places where other people are talking nearby or simultaneously — by extracting only the enrolled user's voice before transcription. Whisper always receives clean, single-speaker audio regardless of background speech.

**Non-goals (this spec):**
- Swift UI for enrollment (Settings panel, onboarding wizard)
- C API exports (`vkb_enroll_*`) — CLI-only for now
- Apple Voice Isolation (`AVAudioEngine`) — separate Mac-specific addition later
- Speaker verification (reject/accept gate) — TSE supersedes this; the extracted audio is always passed to Whisper
- Multi-speaker diarization
- Windows/Linux binary distribution (cross-compilation works; packaging is out of scope)

---

## Background

The current pipeline applies DeepFilterNet2 for stationary noise (fans, HVAC) and uses an RMS threshold in the chunker as a basic voice activity gate. Neither handles competing speech from nearby talkers:

- DeepFilterNet treats other people's voices as valid speech signal and passes them through intact
- The RMS gate fires on any loud audio, including background speakers
- Whisper has no concept of "which speaker to transcribe" and will mix or alternate between voices in the output

Target Speaker Extraction solves this at the audio level: given a short reference audio clip of the user's voice (recorded once at enrollment), TSE outputs only that speaker's audio from any mixed signal. Two people talking simultaneously → Whisper hears only the user.

---

## Architecture

```
Mic → malgo capture → DeepFilterNet (stationary noise)
    → chunker (Silero VAD gate)
    → TSE: SpeakerBeam-SS (competing speech)  ← enrollment.wav (reference audio)
    → Whisper → LLM cleanup → cursor
```

Three additions to the existing pipeline:
1. **Silero VAD** replaces the RMS threshold in the chunker
2. **TSE gate** in `pipeline.Run` between chunker emission and transcribe worker
3. **Enrollment CLI** produces `speaker.json` once per user

When `speaker.json` is absent, `TSE` is `nil` and the gate is skipped entirely — zero overhead, pipeline behaves exactly as today.

---

## Section 1 — New package: `core/internal/speaker/`

### Interfaces

```go
// VAD reports whether a 100ms window of 16kHz mono samples contains voiced speech.
type VAD interface {
    IsVoiced(samples []float32) bool
}

// TSEExtractor extracts the target speaker's audio from a mixed signal.
// mixed: 16kHz mono chunk from the chunker
// ref:   enrollment reference audio (loaded from enrollment.wav at startup)
// Returns clean audio at the same sample rate and length as mixed.
type TSEExtractor interface {
    Extract(ctx context.Context, mixed []float32, ref []float32) ([]float32, error)
}
```

Both interfaces are satisfied by fake implementations in tests. `nil` TSEExtractor means feature off.

### Files

| File | Responsibility |
|---|---|
| `vad.go` | `VAD` interface + `SileroVAD`: loads `silero_vad.onnx`, runs one inference per 100ms window |
| `tse.go` | `TSEExtractor` interface |
| `speakerbeam.go` | `SpeakerBeamSS`: loads `tse_model.onnx` via onnxruntime_go, implements `TSEExtractor` |
| `store.go` | Read/write `speaker.json` — metadata + path to `enrollment.wav` |
| `enroller.go` | Records mic audio via malgo, saves `enrollment.wav`, writes `speaker.json` |

### `speaker.json` schema

```json
{
  "version": 1,
  "ref_audio": "~/.config/voice-keyboard/enrollment.wav",
  "enrolled_at": "2026-04-30T14:23:00Z",
  "duration_s": 10.2
}
```

`enrollment.wav` is the raw 16kHz mono recording from the enrollment session. `speaker.json` is the index — it holds metadata and the path to the WAV. Both stored under `~/.config/voice-keyboard/`. Paths are configurable via flags on the enroll CLI.

---

## Section 2 — Chunker VAD upgrade

`ChunkerOpts` gains one field:

```go
type ChunkerOpts struct {
    VAD            speaker.VAD // nil → fall back to RMS threshold (existing behaviour)
    VoiceThreshold float32     // used only when VAD is nil
    SilenceHangMs  int
    MaxChunkMs     int
    ForceCutScanMs int
}
```

Inside `processWindow`, the voiced decision becomes:

```go
var voiced bool
if c.opts.VAD != nil {
    voiced = c.opts.VAD.IsVoiced(w)
} else {
    voiced = audio.RMS(w) > c.opts.VoiceThreshold
}
```

Everything else in `chunker.go` — force-cut logic, silence hang, tail flush, `Flush()` — is unchanged. Existing chunker tests pass unmodified (they use `ChunkerOpts` with no VAD set).

Silero VAD runs one inference per 100ms window (~1ms CPU). It is designed for exactly this window size (512–1600 samples at 16kHz).

---

## Section 3 — Pipeline TSE gate

`Pipeline` struct gains one field:

```go
type Pipeline struct {
    // ... existing fields unchanged ...
    TSE speaker.TSEExtractor // nil = TSE off
}
```

`Pipeline.New()` loads `speaker.json` at startup:
- File present and valid → initialise `SpeakerBeamSS`, set `p.TSE`
- File absent or unreadable → `p.TSE = nil`, no error (feature silently off)

Inside `pipeline.Run`, after chunker emission, before queuing for the transcribe worker:

```go
if p.TSE != nil {
    cleaned, err := p.TSE.Extract(ctx, chunk.Samples, p.enrolledRef)
    if err != nil {
        return Result{}, fmt.Errorf("tse: %w", err)
    }
    chunk.Samples = cleaned
}
```

`p.enrolledRef` is the raw reference audio loaded from `enrollment.wav` at `Pipeline.New()`. It is read-only for the lifetime of the pipeline run. The TSE model runs its internal speaker encoder on this clip on each chunk call (~5–20ms overhead, acceptable given chunk intervals of 1–12s).

Whisper always receives audio — no chunks are dropped. If the TSE output is near-silence (colleague speaking, user silent), Whisper returns `""` for that chunk, which the join step and LLM cleanup handle gracefully.

---

## Section 4 — Dependency

One new Go dependency:

```
github.com/yalue/onnxruntime_go
```

Thin CGo wrapper over the ONNX Runtime C library. Loads any `.onnx` model. Used for both Silero VAD (`silero_vad.onnx`) and SpeakerBeam-SS (`tse_model.onnx`). No sherpa-onnx needed.

### Model files

| File | Size | Source | Used by |
|---|---|---|---|
| `silero_vad.onnx` | ~2MB | Downloaded by `enroll.sh` from Silero GitHub releases | `SileroVAD` (chunker) |
| `tse_model.onnx` | ~8MB | Produced by `scripts/export_tse_model.py` | `SpeakerBeamSS` (inference) |

Single consolidated model: inputs `(mixed [1,T], ref_audio [1,R])` → output `[1,T]`. The speaker encoder runs internally on each call. No separate enrollment inference step needed — enrollment just records and saves the WAV.

Models are downloaded/built to `core/build/models/` by the shell scripts. Not committed to the repo.

---

## Section 5 — SpeakerBeam-SS ONNX export

`scripts/export_tse_model.py` — a developer tool, not shipped to users.

Runs once when adopting the model or upgrading its version:

1. Downloads SpeakerBeam-SS pretrained weights from the Asteroid model hub
2. Exports one consolidated ONNX model via `torch.onnx.export()`:
   - `tse_model.onnx`: inputs `mixed [1, T]` + `ref_audio [1, R]` → output `[1, T]`
   - The speaker encoder runs as an internal subgraph — no separate export needed
3. Validates round-trip: feeds a synthetic 2-speaker mix, asserts output energy is dominated by the target channel

The resulting `tse_model.onnx` is committed as a release artifact or stored in a known location documented in the README. No Python is required at runtime.

---

## Section 6 — Enrollment CLI + shell scripts

### `core/cmd/enroll/main.go`

```
vkb-enroll [--duration=10] [--out=~/.config/voice-keyboard/] [--models=core/build/models/]
```

Flow:
1. Open mic via malgo (same device selection as the main pipeline)
2. Record for `--duration` seconds (or until keypress)
3. Save 16kHz mono WAV to `enrollment.wav`
4. Write `speaker.json` with path to WAV and metadata
5. Print confirmation

### `enroll.sh`

```bash
# 1. Download models if missing
# 2. Build vkb-enroll if needed
# 3. Run enrollment
echo "🎙  Speak naturally for 10 seconds — press any key to stop early."
core/build/vkb-enroll --duration=10
echo "✓ Voice enrolled. Run ./run-speaker.sh to test."
```

### `run-speaker.sh`

Mirrors `run-streaming.sh` with TSE enabled. Per-chunk output:

```
🎙  Recording (TSE active) — press any key to stop, 'q' to cancel.
[vkb] chunk #1: 2.3s (vad-cut) → TSE applied → transcribe: 341ms → "let's ship this feature"
[vkb] chunk #2: 1.1s (vad-cut) → TSE applied → transcribe: 180ms → ""
[vkb] === latency report ===
[vkb]   post-stop wait: 180ms

let's ship this feature
```

Chunk #2 with empty output indicates TSE suppressed a background speaker — no special handling needed.

---

## Section 7 — Testing strategy

### `core/internal/speaker/` — unit tests, no hardware

| Test | Method |
|---|---|
| `SileroVAD.IsVoiced` true on sine wave, false on silence | Synthesized samples |
| `SpeakerBeamSS.Extract` reduces RMS of interferer | Two tones at different frequencies; assert target channel dominates output |
| `Store` round-trips metadata + WAV path to/from JSON | Temp file |
| `Enroller` writes non-empty WAV and valid `speaker.json` | Synthesized audio input, temp dir output |

### Chunker — existing tests unchanged

One addition: `ChunkerOpts{VAD: fakeVAD{}}` confirms VAD decisions replace RMS threshold.

### Pipeline — extend existing fake-transcriber tests

| Test | Assertion |
|---|---|
| `Pipeline{TSE: nil}` | TSE stage skipped; output matches current behaviour |
| `Pipeline{TSE: fakeTSE{}}` | `Extract` called once per chunk; Whisper receives returned samples |
| `speaker.json` absent at `Pipeline.New()` | `p.TSE == nil`, no error |
| `fakeTSE.Extract` returns empty audio | Whisper returns `""`; pipeline completes without error |

### Integration — build tag `speakerbeam`

Feed a 2-speaker mixture WAV. Assert WER of target speaker is lower with TSE enabled than vanilla Whisper on the same input.

### Not tested

- Real-world accuracy across different microphones, accents, room acoustics — validated manually via `run-speaker.sh`
- TSE quality regression across SpeakerBeam-SS model versions — caught by the integration test's WER budget

---

## Implementation order

1. `onnxruntime_go` dep + `core/internal/speaker/` package skeleton (interfaces only)
2. `SileroVAD` — load model, `IsVoiced`, unit tests
3. Chunker VAD integration — `ChunkerOpts.VAD` field, nil fallback, test
4. `Store` — `speaker.json` + `enrollment.wav` read/write, unit tests
5. `Enroller` + `core/cmd/enroll/main.go` — record WAV, write store
6. `scripts/export_tse_model.py` — PyTorch → ONNX consolidated export + validation
7. `SpeakerBeamSS` — ONNX inference wrapper, unit tests (build tag `speakerbeam`)
8. Pipeline TSE gate — `Pipeline.TSE` field, `Pipeline.New()` loads WAV, `Run` applies TSE
9. `enroll.sh` + `run-speaker.sh`
10. Integration similarity test (build tag `speakerbeam`)

---

## What this design does NOT change

- `Transcriber`, `Cleaner`, `StreamingCleaner`, `Dict`, `Denoiser` interfaces
- `Pipeline.Run` signature and `Result` struct
- `vkb_push_audio` / `vkb_start_capture` / `vkb_stop_capture` / `vkb_poll_event` / `vkb_cancel_capture` C API surface
- Existing event kinds
- `run.sh` and `run-streaming.sh` (unmodified, remain valid regression checks)
- Mac Swift app (no changes this branch)
