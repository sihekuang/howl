# Diarization-mask target selection (`diar_mask`) — Design

## Context

Howl's speaker cleanup today is **target-speaker extraction by waveform
separation**: `SpeakerGate` (`core/internal/speaker/speakerbeam.go`) runs a
combined ONNX (ConvTasNet 2-source separator + ECAPA-TDNN encoder) that
separates the mixture, embeds each source, hard-selects the source closest to
the enrolled embedding, and then applies an optional **post-extract cosine
gate**: if the extracted audio's similarity to the enrolled reference drops
below a threshold, the chunk is silenced (`applyThreshold`,
speakerbeam.go:210).

This has a failure mode users hit directly: **the aggressive/paranoid presets
cut the user's own voice.** Two compounding causes, both documented in
`DEV_NOTES.md` (2026-05-07 research log):

1. A 2-channel separator forced to fit 3+ concurrent voices "puts the user's
   voice and competing voices into the same channel," degrading the extracted
   signal.
2. The post-extract cosine **gate** then reads that degraded signal as
   "not target enough" and silences it — zeroing the user's own speech.

`DEV_NOTES.md` ranks the cheapest fix as a **personal-VAD / speaker-verification
approach — "no separation, just decide is-this-frame-the-user"** — and cites the
CHiME-8 finding that diarization-driven systems beat separation-driven ones
because waveform reconstruction introduces artifacts the ASR was not trained on.
The eval harness rubric already names this trap explicitly
(`docs/superpowers/specs/2026-05-11-audio-cleanup-eval-harness-design.md:282`):
"Cosine wins, WER loses → … Same family failure as ConvTasNet → Drop this
candidate, try Personal-VAD next."

A test-only prototype of the *separation + cosine-pick* idea already exists
(`PyannoteSepECAPA`, cleanup_pyannote_test.go) but inherits exactly this
separation-artifact risk.

This design takes the diarization-driven path instead: **diarize the mixture
into per-speaker activity, cosine-*select* the enrolled speaker's track, and
mask — keeping the user's original audio verbatim** rather than reconstructing
or gating it.

## Goal

Build `diar_mask`: a speaker-cleanup component that isolates the enrolled
speaker by **time-masking** rather than separation, and measure it head-to-head
against the existing `SpeakerGate` in the cleanup eval harness. Specifically:

- The enrolled speaker's audio is **never reconstructed and never
  threshold-gated** — only frames where *other* speakers are exclusively active
  are removed. The component therefore cannot cut the user's voice more than a
  passthrough would.
- Implement the **same interfaces `SpeakerGate` implements** (`Cleanup`,
  `audio.Stage`, `LastSimilarity()`), so it is a drop-in alternative selectable
  alongside TSE via dependency injection — both remain options for users.
- Prove the win with a new **target self-retention** metric added to the
  existing matrix: `diar_mask` should Pareto-dominate the aggressive
  `SpeakerGate` — equal-or-better interferer rejection at strictly higher
  target retention.

## Non-goals

- **No live pipeline wiring this pass.** No `ChunkStages` insertion, no preset
  JSON entry, no `build.FromOptions` branch, no C-ABI / Mac changes. Those are
  the documented follow-up (Out of scope below). The component is written as
  production code implementing the live interfaces so that wiring is later a
  pure composition change.
- **No multi-speaker transcript / who-said-what.** Goal is single enrolled-target
  isolation. The one-chunk → one-Whisper-call → one-text pipeline assumption is
  untouched.
- **No replacement of TSE.** `SpeakerGate` stays; `diar_mask` is an additional
  selectable backend.
- **No DiCoW / diarization-conditioned ASR.** That remains the long-term
  north-star in `DEV_NOTES.md`, blocked by whisper.cpp lacking FDDT hook points.
  The per-frame target/other/overlap mask `diar_mask` computes is, however, the
  same conditioning signal DiCoW consumes — so this work is reusable if we ever
  pursue it.
- **We do not run the model export in this pass.** We write the export recipe;
  producing `pyannote_seg.onnx` is a separate step. The masking logic ships
  fully unit-tested via a fake segmenter; the real-model matrix row skips
  cleanly (and logs the skip) until the artifact exists.

## Architecture

### 1. Component and interfaces (dependency-injection seam)

New production type `DiarMask` in `core/internal/speaker/diarmask.go`,
mirroring `SpeakerGate`'s interface surface so it is injectable anywhere TSE is:

```go
// Cleanup (harness adapter interface, cleanup.go:10)
func (d *DiarMask) Process(ctx context.Context, mixed []float32) ([]float32, error)
func (d *DiarMask) Name() string        // "diar_mask"
func (d *DiarMask) Close() error

// audio.Stage (live pipeline interface, audio/stage.go:14) — for later DI
func (d *DiarMask) OutputRate() int      // 0 (preserves 16 kHz input)

// Event/manifest score hook (type-asserted at pipeline.go:156)
func (d *DiarMask) LastSimilarity() float32  // selection cosine of the chosen track
```

Compile-time checks: `var _ Cleanup = (*DiarMask)(nil)`,
`var _ audio.Stage = (*DiarMask)(nil)`.

Construction captures the enrolled reference at build time, exactly like
`SpeakerGateOptions`:

```go
type DiarMaskOptions struct {
    Segmenter           Segmenter   // injected (real ONNX or fake)
    EncoderPath         string      // ECAPA encoder ONNX, for per-track embeddings
    EncoderDim          int         // 192 for ECAPA
    Reference           []float32   // L2-normalised enrolled embedding
    MinSelectCosine     float32     // below this → low-confidence fallback (default 0.40)
    MinExclusiveSeconds float32     // min exclusive speech to embed a track (default 0.75)
    FallbackPassthrough bool        // default true; false = mask even when low-confidence (for measurement)
    BoundaryRampMs      int         // raised-cosine ramp at mask edges (default 15)
}
```

### 2. Algorithm (mask-select, per whole-utterance buffer)

`Process(mixed)` operates on the full input buffer (a chunker emission in
production; a fixture clip in the harness), 16 kHz mono, and returns
**same-length** output. The model's window is 10 s; `DiarMask` owns the
windowing so steps 2–5 run **independently per window** and only the resulting
*masks* are stitched — local speaker indices are never aligned across windows
(each window selects its own target by cosine to the fixed reference, so no
cross-window identity tracking is needed):

1. **Window + segment.** Split `mixed` into ≤10 s windows (a single window for
   typical utterances; the chunker force-cuts at 12 s and fixtures are a few
   seconds). Windows shorter than 10 s are zero-padded to the model's input
   length. Run the `Segmenter` on each window → a per-frame activity matrix
   `A[frame][k]` for up to 3 local speakers, plus a non-speech indicator. Steps
   2–5 below are applied to each window; step 6 stitches.
2. **Embed each local track.** For each local speaker `k`, gather frames where
   `k` is *exclusively* active (no other speaker), concatenate the corresponding
   `mixed` samples into a contiguous signal, and run `ComputeEmbedding`
   (`embedding.go:18`) → `emb_k`. Skip a track whose exclusive audio is shorter
   than `MinExclusiveSeconds` (too little to embed reliably).
3. **Select by cosine.** `cos_k = cosineSimilarity(emb_k, Reference)`
   (`speakerbeam.go:232`). Target `k* = argmax_k cos_k`. Record
   `lastSimilarity = cos_{k*}`. **This is a selector, not a gate — it picks
   which track to *keep*; it never decides to silence the target.**
4. **Build the target mask.** Frame-level `m[frame] = 1` where `k*` is active,
   **including overlap frames** where `k*` and another speaker are both active
   (inclusion bias — we keep target speech even when an interferer overlaps it,
   accepting some leak rather than cutting the user). `m[frame] = 0` only where
   `k*` is inactive (non-speech, or other speakers exclusively).
5. **Apply at sample resolution.** Upsample `m` from frame to sample resolution
   and apply raised-cosine ramps of `BoundaryRampMs` at on/off transitions to
   avoid clicks. This yields a per-window sample-level mask.
6. **Stitch + return.** Concatenate per-window masks (center-favoring
   overlap-add if windows overlap), multiply against the **original** `mixed`
   samples, and return the same-length result. The target's own audio passes
   through unchanged; no reconstruction. `lastSimilarity` is the max selection
   cosine across windows.

**Why no global clustering (the usual diarization↔streaming friction does not
bite us):** because the target is defined by a *fixed enrolled embedding*, each
window's target track is chosen independently by cosine to that reference. We
never need to stitch speaker *identity* across windows or cluster globally —
only the per-window masks are concatenated — so the hard part of classical
diarization is sidestepped by enrollment.

### 3. `Segmenter` interface and pyannote ONNX implementation

Segmentation is injected so the masking logic is testable without a model:

```go
// Segment returns per-frame local-speaker activity for ONE ≤10 s window of
// 16 kHz mono audio (shorter input is zero-padded to the model length by the
// implementation). Windowing across longer buffers is DiarMask's job, not the
// Segmenter's. FrameHopSamples maps frames↔samples.
type Segmenter interface {
    Segment(ctx context.Context, window []float32) (activity SpeakerActivity, err error)
    Close() error
}

type SpeakerActivity struct {
    Frames          [][]bool // [frame][localSpeaker] active?  (≤3 local speakers)
    FrameHopSamples int      // samples per frame at 16 kHz
}
```

- **`pyannoteSegmenter`** (`diarmask_pyannote.go`): wraps
  `pyannote/segmentation-3.0` exported to ONNX. Input `(1, 1, 160000)` = 10 s @
  16 kHz; output `(num_frames, 7)` **powerset** classes (non-speech, spk1, spk2,
  spk3, spk1+2, spk1+3, spk2+3). We convert powerset → per-frame multilabel
  (≤2 active speakers/frame) in Go. It handles exactly one window; `DiarMask`
  drives the per-window loop (§2) so local speaker indices never need aligning
  across windows. Model path resolves via `PYANNOTE_SEG_PATH` mirroring
  `resolveModelPath` (`tse_real_voice_test.go:122`); absent → the harness row
  skips cleanly.
- **`fakeSegmenter`** (test): returns a deterministic `SpeakerActivity` from a
  hand-built script, so masking, selection, overlap, and fallback logic are unit
  tested with no ONNX dependency.

Reused as-is: `ComputeEmbedding` (ECAPA), `cosineSimilarity`,
`InitONNXRuntime`, the `onnxruntime_go` binding, `resolveModelPath`.

### 4. Guardrails against diarizer error

`DEV_NOTES.md` notes ~70 % of diarization-conditioned error is the diarizer
itself; a mislabeled frame could re-introduce voice-cutting. Mitigations are
part of the design, not afterthoughts:

- **Inclusion bias** (step 4): keep any frame where the target is among the
  active speakers.
- **Single-track → passthrough:** if segmentation finds ≤1 local speaker, return
  the input unchanged (nothing to separate; never mask a solo speaker).
- **Low-confidence → passthrough:** if `cos_{k*} < MinSelectCosine`, return the
  input unchanged (we would rather leak an interferer than cut the user).
  Toggleable via `FallbackPassthrough` so the harness can also measure raw,
  no-fallback masking.
- **Boundary ramps + hysteresis** on the sample-level mask to avoid chopping
  words and producing clicks.

Net invariant: **`diar_mask` can never remove more of the target's own speech
than passthrough.** The only audio it removes is other-speaker-exclusive frames.

### 5. Harness wiring and the self-retention evaluator

Plug into the existing matrix (`cleanup_eval_test.go`) — no parallel test
infrastructure:

- Register a `diar_mask` `adapterFactory` in `cleanupAdapters()` alongside
  `passthrough`, `speakergate`, `pyannote_sep_ecapa`. It builds a `DiarMask`
  with the `pyannoteSegmenter`; returns `nil` (logged skip) when
  `PYANNOTE_SEG_PATH` is unset/absent — matching the existing skip discipline.
- Add a **target self-retention** evaluator and matrix column. Retention
  measures "of the target's own speech energy, how much survived":

  ```
  retention = ||output ⊙ targetVAD|| / ||cleanTarget ⊙ targetVAD||
  ```

  where `cleanTarget` is the fixture's known target clip (`a.Samples`) and
  `targetVAD` marks its voiced frames (simple energy VAD on the clean clip).
  Masking → retention ≈ 1.0; the aggressive gate → retention drops as it
  silences target chunks. The crispest reading is on the **`clean (no mix)`**
  condition: there, retention and `RMSr` must be ≈ 1.0 and WER ≈ passthrough —
  a direct "did it cut my voice" guard.

- Existing evaluators (`evaluateCosine`/`evaluateTSE` shape → `simT/simI/margin`,
  `evaluateWER` → `WER%`, `RMSr`) run unchanged on the new candidate.

## Pass criteria

Per the harness's calibration policy, these are the **starting rubric**, refined
after the first measurement run with real model artifacts.

### Per-row diagnostic gates (debuggability, not ship gates)

| Metric | Pass band | Failure means |
|---|---|---|
| `retention` (clean condition) | ≥ 0.95 | Component eats clean target speech — the core regression |
| `LastSimilarity` (target present) | ≥ `MinSelectCosine` (0.40) | Selector failed to find the target track |
| `RMSr` | 0.1 – 10 | Output not silent / not blown up |

### Aggregate claim to validate

`diar_mask` is recommended over the aggressive `SpeakerGate` when **both** hold
on the LibriSpeech fixture (refine thresholds after first run):

1. **No target-voice cutting.** On `clean (no mix)`, WER within +2 absolute
   points of passthrough and `retention ≥ 0.95`. (The aggressive `SpeakerGate`
   is expected to fail this — that is the pain we are fixing.)
2. **Interferer rejection is not sacrificed.** On the hard mixed conditions
   (`voice+voice @ 0 / -6 dB`, `voice+voice+music @ -6 dB`), `diar_mask`'s WER is
   **≤ `SpeakerGate`'s WER** at the same conditions (equal-or-better), with
   `margin > 0`.

Together these state the Pareto claim: equal-or-better interferer rejection at
strictly higher target retention.

### No-ship outcomes are also signal

| Pattern | Conclusion |
|---|---|
| Retention high, interferer WER worse than gate | Masking is too conservative (overlap leak dominates) — tune inclusion bias / consider overlap-only TSE follow-up |
| Retention drops below passthrough | Segmenter mislabels target frames — diarizer quality is the bottleneck (expected dominant error per DEV_NOTES); revisit model / window stitching |
| Wins everywhere | Promote to live wiring (Out of scope here) |

### Calibration policy

After the first run with `pyannote_seg.onnx`: record actual baseline WER and
retention per condition (dated) in this spec; recompute `MinSelectCosine` and
the `margin` lower bound per the "half the observed minimum" rule the TSE spec
uses; re-record thresholds with one-line rationale each.

## File layout

```
core/internal/speaker/
  diarmask.go            NEW — DiarMask (Cleanup + audio.Stage + LastSimilarity),
                               DiarMaskOptions, Segmenter interface, SpeakerActivity,
                               mask/select/powerset-decode/ramp logic
  diarmask_pyannote.go   NEW — pyannoteSegmenter (ONNX), powerset→multilabel,
                               sliding-window stitching, PYANNOTE_SEG_PATH resolution
  diarmask_test.go       NEW — fakeSegmenter; unit tests for select-by-cosine,
                               overlap inclusion, single-track/low-confidence
                               fallback, ramp/length invariants; interface checks
  cleanup_eval_test.go   EDIT — register `diar_mask` adapterFactory;
                               add target self-retention evaluator + matrix column
core/
  BUILDING_PYANNOTE_SEG.md  NEW — export recipe for pyannote/segmentation-3.0 → ONNX
                               (mirrors BUILDING_PYANNOTE_SEP.md; not run this pass)
docs/superpowers/specs/
  2026-06-20-diarization-mask-select-design.md   THIS FILE
```

`diarmask.go` and `diarmask_pyannote.go` are **production** files (no build tag)
so the live interfaces are real for later DI. The harness wiring lives in the
existing `//go:build cleanupeval && whispercpp` test file.

## Test invocation

```bash
# Unit tests (fake segmenter, no models) — always run
go test ./core/internal/speaker/ -run TestDiarMask

# Full cleanup matrix incl. diar_mask (skips diar_mask row without the model)
go test -tags 'cleanupeval whispercpp' ./core/internal/speaker/ -run TestCleanup_Matrix -v

# With the real segmentation model
PYANNOTE_SEG_PATH=/path/to/pyannote_seg.onnx \
SPEAKER_ENCODER_PATH=/path/to/speaker_encoder.onnx \
WHISPER_MODEL_PATH=/path/to/ggml-small.bin \
go test -tags 'cleanupeval whispercpp' ./core/internal/speaker/ -run TestCleanup_Matrix -v
```

## Dependencies

- Existing: `onnxruntime_go`, ECAPA `speaker_encoder.onnx`, whisper.cpp (WER),
  the LibriSpeech / MUSAN fixtures and mix machinery, `cosineSimilarity`,
  `ComputeEmbedding`.
- New artifact (not produced this pass): `pyannote_seg.onnx`, an ONNX export of
  `pyannote/segmentation-3.0` (gated HF model; accept EULA). Recipe in
  `BUILDING_PYANNOTE_SEG.md`.

## Out of scope (documented follow-up once the experiment wins)

- Live wiring: add a chunk-stage backend (`{"name": "...", "backend":
  "diar_mask"}` in `pipeline-presets.json`), branch in `build.FromOptions`,
  register in the backend registry or an analogous selector, surface
  `LastSimilarity` through `Event`/manifest, expose in Settings/Compare and the
  Mac bridge.
- Optional overlap-only TSE: run ConvTasNet `SpeakerGate` *only* on overlap
  frames to reduce leak there (kept out to preserve the "never cut my voice"
  guarantee for the first pass).
- A dedicated 3-concurrent-voice fixture to best showcase masking vs. the
  2-source separator (reuse existing conditions for the first run).

## Risks and mitigations

| Risk | Mitigation |
|---|---|
| Segmenter mislabels target → cuts voice | Inclusion bias, single-track & low-confidence passthrough, boundary ramps; invariant "never removes more target than passthrough" |
| Model artifact absent blocks the experiment | Logic fully unit-tested via `fakeSegmenter`; real matrix row skips cleanly (logged), never silently |
| Overlap leak hurts interferer rejection vs. gate | Measured directly (interferer WER column); documented overlap-only TSE follow-up if needed |
| Short utterance → no exclusive frames to embed a track | `MinExclusiveSeconds` guard; single-track passthrough |
| Powerset→multilabel / frame↔sample mapping bugs | Pure functions, unit-tested against hand-built `SpeakerActivity` and length/ramp invariants |
| onnxruntime sessions are single-threaded/blocking | Same constraint as existing TSE; per-chunk inference, no new concurrency assumptions |

## Success metric

The experiment succeeds when the matrix shows `diar_mask` **retains target
speech where the aggressive `SpeakerGate` cuts it** (clean-condition retention
≈ 1.0 and WER ≈ passthrough, vs. measurable gate suppression) **without losing
interferer rejection** on the hard mixed conditions — a clear, dated,
reproducible Pareto win recorded in this spec, sufficient to justify the live
wiring follow-up.
