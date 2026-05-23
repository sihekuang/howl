# Audio Cleanup Evaluation Harness — Design

## Context

The May 7 TSE noise-robustness research and the May 11 personalized-denoiser
survey (both in `DEV_NOTES.md`) leave us with a shortlist of three candidate
audio-cleanup components: pyannote-sep + ECAPA cosine pick, DPDFNet (DFN3
upgrade), and an ECAPA-conditioned personal-VAD. Today's TSE harness
(`tse_real_voice_test.go`, `tse_noise_diagnostic_test.go`,
`voice_fixtures_test.go`) was built specifically for waveform target-speaker
extractors that emit audio at 16 kHz mono and gets re-embedded via ECAPA.

That harness shape doesn't generalise to the new candidates without
extension. Specifically:

- It only mixes voice + voice. `core/CLAUDE.md` calls out non-speech noise
  classes (fan, music, café, traffic, keyboard) plus voice + non-speech
  combinations as required for honest comparison; the harness has neither.
- It measures cosine + RMS only. The May 7 notes flagged WER as the
  load-bearing metric — cleanup that wins on cosine can lose on WER if it
  introduces artefacts Whisper isn't trained on. WER measurement is absent.
- It assumes one shape of component (`SpeakerGate`); we need to A/B against
  a baseline (`Passthrough`), the existing default (`DFN3`), the disabled
  former default (`SpeakerGate`), and the new prototype.

This spec defines the harness extensions needed to verify whether the
first prototype — pyannote-sep + ECAPA pick — actually improves the
dictation pipeline against the DFN3-only default we ship today.

## Goal

A `go test` invocation that gives a confident yes/no answer to "does
candidate X produce cleaner audio for the dictation pipeline than today's
DFN3-only baseline." Confidence comes from running each candidate against
the same fixtures, the same mixture conditions, the same SNR sweeps, and
measuring **WER through Whisper** (not just embedding cosine) so the answer
captures end-to-end pipeline quality, not just isolation quality.

## Non-goals

- Real-time latency measurement. Harness runs offline.
- Production model bundling. Pyannote-sep ONNX is resolved via env var the
  same way `TSE_MODEL_PATH` is today.
- Apple VPIO integration into the Mac app. Harness can evaluate a
  VPIO-passthrough baseline if useful, but VPIO wiring in the Swift shell
  is a separate workstream.
- The full noise taxonomy from `core/CLAUDE.md` (fan, café, traffic,
  music, keyboard). One non-speech class first; remaining classes added
  when a candidate has cleared the bar against the minimal matrix.
- CI integration. Local `go test` only at first.

## Architecture

Four layers, each independently testable; mirrors the existing TSE harness
pattern.

### 1. Fixtures

**Voice fixtures** are reused unchanged from the existing harness:

```go
type voiceFixture interface {
    Name() string
    Voices(t *testing.T) (a, b voiceClip)
}
```

`libriSpeechFixture` (always available) and `elevenLabsFixture` (opt-in via
API key) carry over without modification.

**New: ground-truth transcripts** for the LibriSpeech fixture, sourced
from upstream LibriSpeech (CC-BY-4.0). Stored as sibling `.txt` files next
to the bundled WAVs:

```
core/test/integration/testdata/voices/
  libri_1272.wav   (existing)
  libri_1272.txt   (new — ground-truth transcript)
  libri_1462.wav   (existing)
  libri_1462.txt   (new)
  LICENSE.md       (updated to note transcript provenance)
```

ElevenLabs fixture transcripts are derived from `elevenLabsTestText` in
the existing fixture file — that constant is the synthesis input, so it
serves as ground truth without additional sourcing.

**New: noise fixtures.** Symmetric interface to `voiceFixture`:

```go
type noiseFixture interface {
    Name() string
    Noise(t *testing.T) noiseClip
}

type noiseClip struct {
    Label   string
    Samples []float32   // 16 kHz mono
    Class   string      // "music" | "fan" | "babble" | "keyboard" | "traffic"
}
```

First implementation: `musanMusicFixture` reads a single committed ~10 s
clip from `core/test/integration/testdata/noise/musan_music_excerpt.wav`,
sourced via `scripts/fetch-musan-music-fixture.sh` from MUSAN
(Apache-2.0). One class is enough to prove the interface generalises;
remaining classes are added incrementally as candidates clear the
single-class bar.

### 2. Mix machinery

Extracted from the SNR-sweep body currently duplicated in
`tse_noise_diagnostic_test.go` into a shared helper:

```go
// mixAtSNR scales noise so target_rms / noise_rms ≈ 10^(snrDB/20),
// then sums target + scaled_noise * 0.5 element-wise. Pads the shorter
// signal with zeros to the longer length.
func mixAtSNR(target, noise []float32, snrDB float64) []float32

// mixThree adds a third signal at its own SNR relative to the target.
// Used for voice + voice + noise conditions.
func mixThree(target, voiceB []float32, noise []float32, snrVoiceDB, snrNoiseDB float64) []float32
```

Both helpers live in a new `mix_helpers_test.go`. The existing TSE
diagnostic tests get refactored to call them (small, in-place change).

### 3. Cleanup component interface

```go
type Cleanup interface {
    // Process accepts 16 kHz mono mixture, returns cleaned 16 kHz mono audio.
    // Implementations may be speaker-conditioned at construction time.
    Process(ctx context.Context, mixed []float32) ([]float32, error)
    Name() string
    Close() error
}
```

Adapters provided:

| Adapter | Wraps | Speaker-conditioned? | Notes |
|---|---|---|---|
| `Passthrough` | nothing | No | Returns input unchanged. WER baseline. |
| `DFN3Wrapper` | `denoise.NewDeepFilter` | No | Today's default. Frame-stage component adapted to chunk shape. |
| `SpeakerGateAdapter` | existing `SpeakerGate` | Yes (via ECAPA) | The disabled former default. Run for reference. |
| `PyannoteSepECAPA` | new — pyannote-sep ONNX + ECAPA pick | Yes | The prototype. Skips cleanly when ONNX absent. |

`PyannoteSepECAPA` implementation sketch:

1. Run pyannote-sep ONNX on `mixed`. Output: N source streams (typically 3
   per the AMI checkpoint).
2. Compute ECAPA embedding for each source.
3. Pick the source whose embedding has highest cosine to the enrolled
   reference embedding.
4. Return the picked source.

Model artefact resolution mirrors `resolveModelPath` for `TSE_MODEL_PATH`:
`PYANNOTE_SEP_PATH` env var → conventional repo and Application Support
locations → `t.Skip` if missing.

### 4. Evaluators

**Cosine evaluator** (existing — `evaluateTSE` shape, generalised):

```go
type cosineResult struct {
    SimTarget     float32
    SimInterferer float32  // for voice+voice; cosine to noise embedding for voice+noise
    RMSIn, RMSOut float32
}

func evaluateCosine(t *testing.T, cleanup Cleanup, mixed, target, interferer []float32,
    encoderPath string) cosineResult
```

The existing `evaluateTSE` becomes a thin wrapper around this for backward
compatibility.

**WER evaluator** (new):

```go
type werResult struct {
    Reference  string
    Hypothesis string
    WER        float64  // (sub + del + ins) / |ref words|
}

func evaluateWER(t *testing.T, audio []float32, transcript string,
    transcriber transcribe.Transcriber) werResult
```

Uses the same `transcribe.Transcriber` we ship in production
(Whisper-small from the default preset). WER is computed via standard
token Levenshtein. Transcribers are reused across rows to amortise model
load.

**RMS sanity** is a property of `cosineResult` (already there: `RMSIn`,
`RMSOut`). No separate evaluator.

### 5. Matrix runner

Single test entry point: `TestCleanup_Matrix`. Driven by a 2D matrix of
`(condition, candidate)` tuples. Per row, runs all three evaluators and
logs a unified table.

Test matrix for the first prototype run:

| Voice fixture | Mixture type | SNR (dB) | Candidates |
|---|---|---|---|
| LibriSpeech | clean (no mix) | n/a | Passthrough, DFN3, SpeakerGate, PyannoteSepECAPA |
| LibriSpeech | voice + voice | 0 / -6 / -12 | same 4 |
| LibriSpeech | voice + voice (multi-voice TV stand-in) | 0 / -6 | same 4 |
| LibriSpeech | voice + musan music | 0 / -6 / -12 | same 4 |
| LibriSpeech | voice + voice + music | -6 (voice) / 0 (music) | same 4 |
| ElevenLabs | same matrix | same | same 4 (skipped without API key) |

Each voice + voice row runs in BOTH directions (target=A and target=B), per
the existing harness's symmetric-test discipline. Each row produces a
unified output line:

```
candidate          | snr  | simT  | simI  | margin | RMSr  | WER%  | notes
-------------------+------+-------+-------+--------+-------+-------+------
Passthrough        |   0  | 0.51  | 0.49  |  0.02  | 1.00  | 78.4% | baseline
DFN3               |   0  | 0.52  | 0.48  |  0.04  | 0.91  | 71.2% |
SpeakerGate        |   0  | 0.61  | 0.42  |  0.19  | 0.83  | 42.1% | disabled in default preset
PyannoteSepECAPA   |   0  | 0.74  | 0.31  |  0.43  | 0.78  | 28.7% |
...
```

## Pass criteria

The criteria below are a **rubric, not gospel**. They are the starting
calibration for the first measurement run; thresholds are expected to
change as we learn what the candidate actually does and what the noise
floor of the fixture set looks like. Every threshold below comes with a
"refine after first run" expectation.

### Per-row diagnostic gates

| Metric | Pass band | Failure means |
|---|---|---|
| `simT` ≥ 0.40 | — | Cleaned audio still recognisable as the target speaker |
| `margin` ≥ 0.03 | — | Model pulled toward target, not interferer (calibration is candidate-specific; recompute per model after first run) |
| 0.1 ≤ `RMSr` ≤ 10 | — | Output not silent and not blown up |

These are **debuggability gates**, not ship gates. They catch broken
models. A model can pass them and still not be worth shipping; conversely
a model can fail them on a single edge-case row and still be worth
shipping if the WER answer is clear.

### Aggregate ship/no-ship rubric

A candidate is recommended for shipping when all three hold; failure on
any single criterion is a signal to investigate, not an automatic reject:

1. **WER win on hard conditions.** Mean WER across `voice+voice @ 0 dB`,
   `voice+voice @ -6 dB`, and `voice+voice+noise @ -6 dB` is **≥ 5
   absolute percentage points lower** than the DFN3 baseline at the same
   conditions, on the LibriSpeech fixture.
2. **No regression on easy conditions.** WER on `clean (no mix)` is
   **within +2 absolute points** of the Passthrough baseline. Catches the
   failure mode where a cleanup model corrupts already-clean input.
3. **Sanity gates pass on the typical case.** Per-row diagnostic
   thresholds hold for the majority of the matrix. Single-row failures on
   `RMSr < 0.1` (silent output) or `simT < 0.40` (lost the speaker) are
   investigation triggers.

The 5-point WER threshold is calibrated to be: bigger than measurement
noise on a small fixture set (so wins are real), smaller than the win we
need to justify the artefact-risk and integration cost (so we don't ship
marginal gains). Refine it after the first run produces actual baseline
noise.

### No-ship outcomes are also signal

| Pattern | Conclusion | Action |
|---|---|---|
| WER lift on hard conditions, regression on clean | Model trained too aggressively; only useful when conditions are bad | Build a quality detector, run model conditionally |
| Cosine wins, WER loses | The May-7 risk: model creates artefacts Whisper hates. Same family failure as ConvTasNet | Drop this candidate, try Personal-VAD next |
| No win on any axis | Candidate is genuinely worse than baseline | Drop, move to next shortlist item |
| WER tied within ±1 point | Inconclusive given fixture size | Add a second non-speech noise class and re-run before deciding |

### Calibration policy

After the first measurement run:
- Record the actual baseline WER numbers (Passthrough, DFN3) per condition
  in this spec, dated.
- Recompute the candidate-specific cosine `margin` lower bound per the
  same "half the observed minimum" rule the existing TSE spec uses.
- Re-record the rubric thresholds with one-sentence rationale per number,
  dated. The numbers above are starting points; the rubric is the
  durable artefact.

## File layout

```
core/internal/speaker/
  cleanup.go                    NEW — Cleanup interface + adapters
  cleanup_test.go               NEW — adapter unit tests (model load, basic process)
  noise_fixtures_test.go        NEW — noiseFixture interface + musanMusicFixture
  mix_helpers_test.go           NEW — mixAtSNR, mixThree (extracted from existing tests)
  wer_eval_test.go              NEW — evaluateWER + werResult
  cleanup_eval_test.go          NEW — TestCleanup_Matrix
  voice_fixtures_test.go        UPDATED — add transcript loader for libriSpeechFixture
  tse_noise_diagnostic_test.go  UPDATED — refactor to use mix_helpers_test.go
  tse_real_voice_test.go        UNCHANGED

core/test/integration/testdata/voices/
  libri_1272.txt                NEW — ground-truth transcript
  libri_1462.txt                NEW — ground-truth transcript
  LICENSE.md                    UPDATED — note transcript provenance

core/test/integration/testdata/noise/
  musan_music_excerpt.wav       NEW — ~10 s 16 kHz mono clip
  LICENSE.md                    NEW — MUSAN attribution (Apache-2.0)

scripts/
  fetch-musan-music-fixture.sh  NEW — one-time fixture sourcing
  fetch-libri-transcripts.sh    NEW — one-time transcript sourcing
```

Build tag for new test files: `//go:build cleanupeval` (independent of
the existing `speakerbeam` tag).

## Test invocation

```bash
# Existing TSE tests (unchanged)
go test -tags speakerbeam ./internal/speaker/...

# New cleanup harness
go test -tags cleanupeval -run TestCleanup_Matrix ./internal/speaker/...

# Verbose with full per-row output
go test -tags cleanupeval -v -run TestCleanup_Matrix ./internal/speaker/...

# Both together
go test -tags 'speakerbeam,cleanupeval' ./internal/speaker/...
```

`PYANNOTE_SEP_PATH=… SPEAKER_ENCODER_PATH=… TSE_MODEL_PATH=…
ONNXRUNTIME_LIB_PATH=…` env vars resolve model artefacts; missing models
cause `t.Skip`, not failure.

## Dependencies

Zero new Go modules. Reuses:
- `audio.ReadWAVMono` / `audio.WriteWAVMono` (existing)
- `speaker.ComputeEmbedding` / `cosineSimilarity` (existing)
- `speaker.NewSpeakerGate` (existing — used as the `SpeakerGate` adapter)
- `transcribe.Transcriber` (existing — used by `evaluateWER`)
- `denoise.NewDeepFilter` (existing — used as the `DFN3` adapter)

Pyannote-sep ONNX is the only new model artefact. Sourcing the ONNX is a
follow-up task in the implementation plan, not the spec. Suggested
approach: export `pyannote/speech-separation-ami-1.0` from PyTorch via
`pyannote.audio`'s standard pipeline, save as ONNX, document the
conversion script in `core/BUILDING_*` style. Falls back to `t.Skip`
cleanly until the model is available.

## Out of scope

- **SI-SDR signal-domain metric.** WER is the load-bearing answer; cosine
  + RMS are diagnostic. SI-SDR adds a third axis but only on the
  LibriSpeech path (needs clean ground truth). Defer until cosine + WER
  prove insufficient.
- **Streaming-mode evaluation.** Pyannote-sep is offline-windowed; the
  harness runs offline. Streaming behaviour of any candidate is a
  separate evaluation.
- **Latency / RTF measurement.** Same reason. Easy to add as a sidecar
  benchmark when needed.
- **Combined-component evaluations** (DFN3 → pyannote-sep → personal-VAD
  stack). Single-component first; combinations once at least one
  candidate has cleared the single-component bar. The `Cleanup` interface
  composes naturally for stacks but they're not the first-run target.
- **Fan, café, traffic, keyboard noise classes.** Music is the first
  non-speech class because music's harmonic content is the hardest case
  for ASR (Whisper hallucinates lyrics). Other classes added when a
  candidate clears the music-class bar.
- **CI integration.** Test runs locally; wiring into GitHub Actions is a
  separate change after the harness has stabilised.

## Risks and mitigations

| Risk | Mitigation |
|---|---|
| Pyannote-sep ONNX export from PyTorch is harder than expected | The harness `t.Skip`s cleanly when the model is absent. Worst case: harness is built and proven against `Passthrough + DFN3 + SpeakerGate` rows, awaiting the ONNX before the prototype row activates. |
| Whisper-small WER measurement has high variance on short clips | Bundled clips are 5+ s; run each measurement once per row (no averaging). If variance proves problematic post-first-run, add multi-run averaging in the matrix runner. |
| Ground-truth transcripts disagree with Whisper's tokenisation | Lower-case + strip punctuation + collapse whitespace before WER computation. Standard practice; documented in the WER evaluator. |
| Pass-criteria thresholds are wrong on first run | The rubric framing makes this expected, not a failure. First run produces baseline numbers that update the spec. |
| MUSAN clip is too short / atypical of "music" | One clip is enough to prove the noise-fixture interface works; representativeness improves as more clips are added under the same interface. The fetch script makes adding clips trivial. |
| Test runtime grows past tolerable | First-run estimate ~30 minutes for the full matrix on M-series. If it grows past an hour, drop ElevenLabs runs from the default invocation; keep them under a separate `-tags cleanupeval,full` flag. |

## Success metric

After implementation:
- `go test -tags cleanupeval -run TestCleanup_Matrix ./internal/speaker/...`
  runs to completion locally with at least the LibriSpeech subtests
  active.
- Output table contains one row per `(candidate, condition)` tuple, with
  cosine + WER + RMS columns populated.
- `Passthrough`, `DFN3`, and `SpeakerGate` rows produce numbers
  unconditionally (no skip path for those).
- `PyannoteSepECAPA` row either produces numbers or `t.Skip`s with a
  clear reason ("PYANNOTE_SEP_PATH not set or model file missing").
- A deliberate regression — feeding a constant zero embedding as the
  reference to a speaker-conditioned adapter — produces a row whose
  diagnostic gates fail, with log output identifying which gate broke.
