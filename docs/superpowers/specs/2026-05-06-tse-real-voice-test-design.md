# TSE Real-Voice Integration Test — Design

## Context

The current TSE integration tests don't actually verify Target Speaker
Extraction works:

- `TestTSE_ReducesInterfererRMS` (sine tones) feeds a 32000-sample raw
  audio buffer into the `Reference` slot that expects a 192-dim ECAPA
  embedding. The shape mismatch happens to pass through ONNX without
  erroring on the current model, but the resulting "extraction" has
  no meaningful relationship to speaker identity — sine tones aren't
  speech, and ECAPA was trained on real human voices.
- An attempted second test using macOS `say` voices revealed that
  every cross-speaker cosine sits between 0.77 and 0.92 (real human
  speakers land at 0.0–0.15 with the same encoder). The encoder
  treats every macOS TTS voice as essentially the same speaker, so
  no TSE assertion built on `say` voices can produce signal.

The encoder itself is healthy: every embedding is exactly L2-norm 1.0
and self-cosine = 1.0. The problem is purely the test inputs.

This design specifies a test that uses real human voices and applies
literature-backed pass criteria so a successful run gives a confident
"TSE is doing its job" signal and a failed run is debuggable.

## Goal

A `go test`, gated on the TSE + encoder ONNX models being present,
that gives a confident yes/no answer to "does our TSE extract the
enrolled speaker from a 2-speaker mix?"

## Pass criteria (per direction)

For a mix of speakers A and B with target=A, computed embeddings
`e_A`, `e_B` (192-d L2-normalised), TSE output `y` with embedding
`e_y`:

| Assertion | Threshold | Rationale |
|---|---|---|
| `cos(e_y, e_A) >= 0.40` | 0.40 | ECAPA EER decision boundary is ~0.25; same-speaker clean speech scores 0.55–0.85. 0.40 sits comfortably above the noise floor without demanding clean-speech quality from a separated signal. |
| `cos(e_y, e_A) - cos(e_y, e_B) >= 0.03` | 0.03 (calibrated post-hoc — see commit `dd30d78`) | The literature value (0.30, from WeSep / X-TF-GridNet) assumed jointly trained SOTA TSE models. Our model is an off-the-shelf JorisCos ConvTasNet separator glued to a Wespeaker ECAPA encoder at export time; observed minimum margin across LibriSpeech 1272/1462 directions is 0.0565. 0.03 is roughly half the observed minimum — catches "TSE didn't actually pick the right source" while leaving fixture-variance headroom. The directional symmetry check below remains the primary correctness guard. |
| `0.1 * rms(mix) <= rms(y) <= 10 * rms(mix)` | 0.1×–10× | Catches degenerate-silent and energy-blowup outputs that would make cosine numerically unstable. |
| **Symmetric**: same assertions hold with B as reference | — | Single most valuable guard. Defeats speaker-confusion ("TSE always returns the louder speaker") and reference-ignoring ("TSE always returns voice X regardless of reference") failure modes that an asymmetric test misses. |

A test invocation passes only when every assertion holds in **both**
directions for every fixture provider that ran. The ElevenLabs
fixture skips cleanly when its API key is absent (skip ≠ fail); the
LibriSpeech fixture is always required to run and pass.

## Architecture

Three layers, each independently testable:

### 1. Fixture provider

Yields `(name, []float32 16 kHz mono PCM)` tuples for two distinct
speakers. Two implementations sharing a common interface:

```go
type voiceFixture interface {
    Name() string
    Voices(t *testing.T) (a, b voiceClip)
}

type voiceClip struct {
    Label   string   // e.g. "libri-1188", "elevenlabs-rachel"
    Samples []float32
}
```

**`libriSpeechFixture`**
- Reads two committed WAVs from
  `core/test/integration/testdata/voices/libri_<id>.wav`.
- Always available; no skip path.

**`elevenLabsFixture`**
- Skipped (not failed) when `ELEVENLABS_API_KEY` env var unset or
  `ffmpeg` not on PATH.
- Hits ElevenLabs TTS twice with two well-known distinct voice IDs
  (Adam + Rachel — canonical demo voices).
- Decodes returned MP3 → 16 kHz mono LE 16-bit PCM WAV via `ffmpeg`
  exec.
- Caches the **decoded WAV** (not the source MP3) under
  `$TMPDIR/voicekeyboard-tse-fixtures/` keyed by
  `voice_id + sha256(text)` so repeat runs don't burn API credits
  or re-decode.

### 2. TSE evaluator

Pure function. No assertions inside.

```go
type tseResult struct {
    SimTarget     float32
    SimInterferer float32
    RMSIn         float32
    RMSOut        float32
}

func evaluateTSE(t *testing.T, voices [2]voiceClip, targetIdx int,
    tseModel, encoderModel string) tseResult
```

Steps inside `evaluateTSE`:
1. Trim both voices to the shorter length.
2. Mix at equal level (sum × 0.5) to produce `mixed`.
3. Compute embeddings for `voices[0]`, `voices[1]`, `mixed` via the
   encoder ONNX.
4. Construct `SpeakerGate` with `voices[targetIdx]`'s embedding as
   reference.
5. Run `Extract(ctx, mixed)` to get `extracted`.
6. Compute embedding of `extracted`.
7. Return `tseResult` populated with the four numbers needed by the
   assertions.

### 3. Test bodies

```go
func TestTSE_ExtractsEnrolledVoiceFromMix(t *testing.T) {
    tseModel := resolveModelPath(t, "TSE_MODEL_PATH", "tse_model.onnx")
    encoderModel := resolveModelPath(t, "SPEAKER_ENCODER_PATH", "speaker_encoder.onnx")
    initOnce(t)

    fixtures := []voiceFixture{
        newLibriSpeechFixture(),
        newElevenLabsFixture(), // self-skips when key absent
    }

    for _, fix := range fixtures {
        t.Run(fix.Name(), func(t *testing.T) {
            a, b := fix.Voices(t)
            for _, dir := range []struct{ name string; targetIdx int }{
                {"target=A", 0}, {"target=B", 1},
            } {
                t.Run(dir.name, func(t *testing.T) {
                    res := evaluateTSE(t, [2]voiceClip{a, b}, dir.targetIdx, tseModel, encoderModel)
                    assertTSEResult(t, res)
                })
            }
        })
    }
}
```

Failure messages include all four numbers + the failed inequality so
regressions are debuggable from log output alone.

## Test matrix

```
TestTSE_ExtractsEnrolledVoiceFromMix/libri_speech/target=A
TestTSE_ExtractsEnrolledVoiceFromMix/libri_speech/target=B
TestTSE_ExtractsEnrolledVoiceFromMix/elevenlabs/target=A   (if API key)
TestTSE_ExtractsEnrolledVoiceFromMix/elevenlabs/target=B   (if API key)
```

Both directions must pass per fixture set. The libri_speech subtests
always run when models are present; elevenlabs subtests skip cleanly
without the API key.

## File layout

```
core/internal/speaker/
  tse_real_voice_test.go        // test bodies + evaluateTSE + assertions
  voice_fixtures_test.go        // libriSpeech + elevenLabs implementations
  (delete) tse_mix_integration_test.go  // the say-based test we wrote and proved useless
core/test/integration/testdata/voices/
  libri_<idA>.wav               // ~100 KB, ~5 s
  libri_<idB>.wav               // ~100 KB, ~5 s
scripts/
  fetch-tse-test-voices.sh      // one-time fixture sourcing, committed but not run by tests
```

Build tag for both test files: `speakerbeam`. The `darwin` constraint
on the previous `say`-based test goes away because LibriSpeech +
ElevenLabs are both platform-independent.

## Fixture sourcing

`scripts/fetch-tse-test-voices.sh`:
1. Downloads LibriSpeech `dev-clean` (it's small enough — ~300 MB
   — to download fully on demand; we don't keep it around).
2. Picks two clearly distinct speakers (recommended: one female +
   one male, since cross-gender pairs give the largest acoustic
   distance for ECAPA). Specific speaker IDs chosen at script time
   from `dev-clean/SPEAKERS.TXT`; the script logs which it picked
   so the choice is reproducible from the script output.
3. Picks one ~5 s utterance per speaker, transcodes to 16 kHz mono LE
   16-bit PCM via `ffmpeg`, writes to
   `core/test/integration/testdata/voices/libri_<speakerID>.wav`.
4. Idempotent (re-running overwrites cleanly).

The script is committed but not invoked by `go test`. The committed
WAVs are the test inputs. Reproducibility lives in the script.

## Out of scope

- **`say`-voice path** — proven useless; deleted. The sine-tone
  `TestTSE_ReducesInterfererRMS` stays as a separate layer of
  coverage (proves TSE pipeline doesn't crash on synthetic input)
  even though it's not a real correctness check.
- **SI-SDR signal-domain metric** — would need clean-target ground
  truth. LibriSpeech path has it (the original clip); ElevenLabs path
  doesn't (TTS introduces randomness). Sticking to embedding cosine
  keeps both paths symmetric. Adding SI-SDR as a third LibriSpeech-only
  assertion is a follow-up if cosine alone proves noisy.
- **CI integration** — the test runs locally via
  `go test -tags speakerbeam ./internal/speaker/`. Wiring it into
  the existing GitHub Actions workflow is a separate change.
- **Multi-fixture comparative reporting** — e.g., "ElevenLabs gave
  better separation than LibriSpeech." Each fixture's subtest
  pass/fails independently; no cross-fixture analysis.

## Risks and mitigations

| Risk | Mitigation |
|---|---|
| 0.40 / 0.30 thresholds turn out to be too strict for our specific TSE model variant. | Initial run will surface concrete numbers; thresholds are constants in one place, easy to retune once with a written rationale. |
| ElevenLabs voices Adam + Rachel happen to embed close to each other (TTS voices may share characteristics across providers). | The diagnostic test we already have can be extended to print the cross-speaker cosine for the chosen ElevenLabs voices on first run. If too high, swap to a different pair. The LibriSpeech path is the always-on safety net regardless. |
| LibriSpeech license attribution. | Add a short `LICENSE.md` in `testdata/voices/` citing LibriSpeech (CC BY 4.0) + the speaker IDs and chapter/utterance numbers used. |
| ElevenLabs API surface changes / rate-limits. | Caching by `voice_id + sha256(text)` means typical local runs hit cache. The path is opt-in via env var; outages don't block default `go test`. |
| Bundled WAVs grow stale or get corrupted. | The fetch script regenerates from canonical source. SHA256 of each WAV could be stored in a sidecar to detect corruption — small future addition if needed. |

## Success metric

After implementation:
- `go test -tags speakerbeam -run TestTSE_ExtractsEnrolledVoiceFromMix
  ./internal/speaker/` passes locally for the LibriSpeech subtest in
  both directions.
- A deliberate regression — e.g., feeding a constant zero embedding
  as the reference — makes the test fail with a log message that
  identifies which assertion broke and the four numbers explaining
  why.
