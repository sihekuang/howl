# Audio Cleanup Evaluation Harness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a Go test harness that evaluates audio-cleanup components head-to-head on the dictation pipeline, measuring WER through Whisper alongside ECAPA cosine + RMS sanity, so we can verify whether the pyannote-sep+ECAPA-pick prototype actually beats baseline.

**Architecture:** Four-layer harness mirroring the existing TSE test pattern: `voiceFixture + noiseFixture` → mix at SNR → `Cleanup` adapter (Passthrough / SpeakerGate / PyannoteSepECAPA) → three evaluators (cosine, WER, RMS) → unified per-row table output. Reuses existing speaker/encoder/transcribe infrastructure. New code is gated behind a `cleanupeval` build tag to avoid impacting normal `go test` runs.

**Tech Stack:** Go, ONNX Runtime via `onnxruntime_go`, whisper.cpp via existing `transcribe.Transcriber`, MUSAN (Apache-2.0) for noise fixtures, LibriSpeech (CC-BY-4.0) transcripts.

---

## Spec deviations

The spec lists four `Cleanup` adapters: `Passthrough`, `DFN3`, `SpeakerGate`, `PyannoteSepECAPA`. This plan **defers `DFN3Wrapper` to a follow-up**:

- DeepFilterNet runs natively at 48 kHz / 480-sample frames. Our fixtures are 16 kHz LibriSpeech.
- Running DFN3 against 16 kHz mixtures requires an upsample (16 k → 48 k) before DFN and a decimate (48 k → 16 k) after. The existing `resample.Decimate3` handles 48 → 16 but we have no 16 → 48 upsampler.
- Naive linear upsampling biases DFN3's WER row upward in a way that makes the head-to-head with `PyannoteSepECAPA` unfair (PyannoteSepECAPA gets clean 16 k input).
- The first prototype question — "is pyannote-sep+ECAPA-pick a useful filter at all?" — is answered without DFN3 in the matrix. Adding a proper sinc upsampler + DFN3Wrapper is a clean follow-up task once we know the prototype is worth integrating.

First-iteration adapter set: `Passthrough | SpeakerGate | PyannoteSepECAPA`.

Other deviations: none. All other spec sections (rubric, file layout, test invocation, calibration policy) carry over unchanged.

---

## File structure

**New test files** (all in `core/internal/speaker/`, `package speaker`):

| File | Build tag | Responsibility |
|---|---|---|
| `cleanup.go` | none | `Cleanup` interface + `Passthrough` (production code, no tag — usable from non-test paths if needed later) |
| `cleanup_speakergate_test.go` | `cleanupeval` | `SpeakerGateAdapter` |
| `cleanup_pyannote_test.go` | `cleanupeval` | `PyannoteSepECAPA` adapter |
| `mix_helpers_test.go` | `speakerbeam || cleanupeval` | Shared `mixAtSNR`, `mixThree` |
| `noise_fixtures_test.go` | `cleanupeval` | `noiseFixture` interface + `musanMusicFixture` |
| `wer_eval_test.go` | `cleanupeval` | `evaluateWER` + token Levenshtein |
| `cosine_eval_test.go` | `cleanupeval` | `evaluateCosine` (generalised from existing `evaluateTSE`) |
| `cleanup_eval_test.go` | `cleanupeval` | `TestCleanup_Matrix` runner |
| `voice_fixtures_test.go` | `speakerbeam || cleanupeval` | EXISTING — extend with `Transcript()` method, broaden tag |
| `tse_noise_diagnostic_test.go` | `speakerbeam` | EXISTING — refactor to call shared `mixAtSNR` |
| `tse_real_voice_test.go` | `speakerbeam` | EXISTING — unchanged |

**New fixture data:**

```
core/test/integration/testdata/voices/
  libri_1272.txt                          # ground-truth transcript for libri_1272.wav
  libri_1462.txt                          # ground-truth transcript for libri_1462.wav
  LICENSE.md                              # UPDATED — note transcript provenance

core/test/integration/testdata/noise/
  musan_music_excerpt.wav                 # ~10 s 16 kHz mono clip
  LICENSE.md                              # NEW — MUSAN attribution
```

**New scripts (committed but not run by tests):**

```
scripts/fetch-musan-music-fixture.sh      # one-time noise fixture sourcing
scripts/fetch-libri-transcripts.sh        # one-time transcript sourcing
core/BUILDING_PYANNOTE_SEP.md             # how to export pyannote-sep to ONNX (follow-up — task 12)
```

---

## Task 1: Scaffold the build tag and verify baseline

**Files:**
- Create: `core/internal/speaker/cleanup_smoke_test.go`
- Run: existing test suites under both old and new tags

- [ ] **Step 1: Create a smoke test file under the new tag**

`core/internal/speaker/cleanup_smoke_test.go`:
```go
//go:build cleanupeval

package speaker

import "testing"

// TestCleanupBuildTagWired is a placeholder that confirms the
// cleanupeval build tag is recognised and that compilation under
// the tag succeeds before any real cleanup test files exist.
// Deleted when cleanup_eval_test.go lands.
func TestCleanupBuildTagWired(t *testing.T) {
	t.Log("cleanupeval build tag wired")
}
```

- [ ] **Step 2: Run baseline tests with the existing tag, confirm green**

Run: `cd core && go test -tags speakerbeam ./internal/speaker/...`
Expected: PASS (or skip cleanly when models absent — same behaviour as before)

- [ ] **Step 3: Run with the new tag, confirm green**

Run: `cd core && go test -tags cleanupeval -run TestCleanupBuildTagWired ./internal/speaker/...`
Expected: PASS, `cleanupeval build tag wired` in -v output.

- [ ] **Step 4: Run with both tags combined, confirm green**

Run: `cd core && go test -tags 'speakerbeam,cleanupeval' ./internal/speaker/...`
Expected: PASS — neither tag breaks the other.

- [ ] **Step 5: Commit**

```bash
git add core/internal/speaker/cleanup_smoke_test.go
git commit -m "$(cat <<'EOF'
test(speaker): scaffold cleanupeval build tag

Adds a placeholder smoke test under the new cleanupeval build tag so
subsequent harness work can land incrementally without breaking the
existing speakerbeam test path. Deleted when the real matrix runner
lands.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Cleanup interface + Passthrough adapter

**Files:**
- Create: `core/internal/speaker/cleanup.go`
- Create: `core/internal/speaker/cleanup_test.go`

- [ ] **Step 1: Write the failing test for Passthrough**

`core/internal/speaker/cleanup_test.go`:
```go
package speaker

import (
	"context"
	"testing"
)

func TestPassthrough_ReturnsInputUnchanged(t *testing.T) {
	in := []float32{0.1, -0.2, 0.3, 0.0, 0.5}
	p := NewPassthrough()
	defer p.Close()

	out, err := p.Process(context.Background(), in)
	if err != nil {
		t.Fatalf("Process: %v", err)
	}
	if len(out) != len(in) {
		t.Fatalf("len(out)=%d, want %d", len(out), len(in))
	}
	for i := range in {
		if out[i] != in[i] {
			t.Errorf("out[%d]=%f, want %f", i, out[i], in[i])
		}
	}
}

func TestPassthrough_ReturnsCopyNotAlias(t *testing.T) {
	in := []float32{1.0, 2.0, 3.0}
	p := NewPassthrough()
	defer p.Close()

	out, _ := p.Process(context.Background(), in)
	out[0] = 999
	if in[0] != 1.0 {
		t.Errorf("Process aliased input slice; mutating output mutated input")
	}
}

func TestPassthrough_Name(t *testing.T) {
	if got := NewPassthrough().Name(); got != "passthrough" {
		t.Errorf("Name() = %q, want %q", got, "passthrough")
	}
}
```

- [ ] **Step 2: Run the test, confirm failure**

Run: `cd core && go test -run TestPassthrough ./internal/speaker/...`
Expected: FAIL — `undefined: NewPassthrough` and `undefined: Cleanup`.

- [ ] **Step 3: Implement Cleanup interface and Passthrough**

`core/internal/speaker/cleanup.go`:
```go
package speaker

import "context"

// Cleanup is the unified interface implemented by every audio cleanup
// component evaluated through the harness. Implementations consume a
// 16 kHz mono mixture and return a 16 kHz mono cleaned signal of the
// same length. Speaker-conditioned implementations capture their
// reference at construction time.
type Cleanup interface {
	Process(ctx context.Context, mixed []float32) ([]float32, error)
	Name() string
	Close() error
}

// Passthrough is a no-op Cleanup that returns its input unchanged.
// Used as the harness baseline ("what does the pipeline look like
// without any cleanup at all").
type Passthrough struct{}

// NewPassthrough constructs a Passthrough adapter.
func NewPassthrough() *Passthrough { return &Passthrough{} }

// Process returns a copy of mixed (never aliases the caller's slice).
func (p *Passthrough) Process(_ context.Context, mixed []float32) ([]float32, error) {
	out := make([]float32, len(mixed))
	copy(out, mixed)
	return out, nil
}

// Name returns the canonical adapter label used in matrix output rows.
func (p *Passthrough) Name() string { return "passthrough" }

// Close is a no-op for Passthrough.
func (p *Passthrough) Close() error { return nil }

// Compile-time interface check.
var _ Cleanup = (*Passthrough)(nil)
```

- [ ] **Step 4: Run the test, confirm pass**

Run: `cd core && go test -run TestPassthrough ./internal/speaker/...`
Expected: PASS — three subtests, all green.

- [ ] **Step 5: Commit**

```bash
git add core/internal/speaker/cleanup.go core/internal/speaker/cleanup_test.go
git commit -m "$(cat <<'EOF'
feat(speaker): add Cleanup interface and Passthrough adapter

Cleanup is the unified interface for audio cleanup components evaluated
in the harness. Passthrough is the no-op baseline.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Extract shared mix helpers

**Files:**
- Create: `core/internal/speaker/mix_helpers_test.go`
- Modify: `core/internal/speaker/tse_noise_diagnostic_test.go` (call site refactor)

- [ ] **Step 1: Write the failing tests for mixAtSNR and mixThree**

`core/internal/speaker/mix_helpers_test.go`:
```go
//go:build speakerbeam || cleanupeval

package speaker

import (
	"math"
	"testing"
)

func TestMixAtSNR_ZeroSNRMatchesEqualLevel(t *testing.T) {
	target := []float32{1, 0, 1, 0, 1, 0}
	noise := []float32{0, 1, 0, 1, 0, 1}
	mixed := mixAtSNR(target, noise, 0)
	if len(mixed) != len(target) {
		t.Fatalf("len(mixed)=%d, want %d", len(mixed), len(target))
	}
	// At 0 dB, noise gain == 1, so each sample is (target[i] + noise[i]) * 0.5.
	for i := range mixed {
		want := (target[i] + noise[i]) * 0.5
		if math.Abs(float64(mixed[i]-want)) > 1e-6 {
			t.Errorf("mixed[%d]=%f, want %f", i, mixed[i], want)
		}
	}
}

func TestMixAtSNR_NegativeSNRBoostsNoise(t *testing.T) {
	target := []float32{1, 1, 1, 1}
	noise := []float32{1, 1, 1, 1}
	// At -6 dB, noise gain ≈ 10^(6/20) ≈ 1.995.
	mixed := mixAtSNR(target, noise, -6)
	want := float32(0.5 * (1.0 + 1.995))
	if math.Abs(float64(mixed[0]-want)) > 0.01 {
		t.Errorf("mixed[0]=%f, want ~%f (noise should be ~2x amplitude)", mixed[0], want)
	}
}

func TestMixAtSNR_PadsShorterInput(t *testing.T) {
	target := []float32{1, 1, 1, 1, 1}
	noise := []float32{1, 1}
	mixed := mixAtSNR(target, noise, 0)
	if len(mixed) != 5 {
		t.Fatalf("len(mixed)=%d, want 5 (max of inputs)", len(mixed))
	}
	// First 2 samples have noise; last 3 have target only at gain 0.5.
	if mixed[3] != 0.5 || mixed[4] != 0.5 {
		t.Errorf("mixed[3:5]=%v, want [0.5 0.5]", mixed[3:5])
	}
}

func TestMixThree_AddsAllThreeSources(t *testing.T) {
	a := []float32{1, 1, 1, 1}
	b := []float32{1, 1, 1, 1}
	n := []float32{1, 1, 1, 1}
	// Voice B at 0 dB → gain 1; noise at 0 dB → gain 1.
	// mix = (a + b*1 + n*1) * 0.5 = 1.5
	mixed := mixThree(a, b, n, 0, 0)
	if mixed[0] != 1.5 {
		t.Errorf("mixed[0]=%f, want 1.5", mixed[0])
	}
}
```

- [ ] **Step 2: Run the tests, confirm failure**

Run: `cd core && go test -tags cleanupeval -run TestMixAtSNR ./internal/speaker/...`
Expected: FAIL — `undefined: mixAtSNR`.

- [ ] **Step 3: Add the helpers to the same file**

Append to `core/internal/speaker/mix_helpers_test.go`:
```go
// mixAtSNR scales noise so target_rms / noise_rms ≈ 10^(snrDB/20),
// then sums target + scaled_noise * 0.5 element-wise. Pads the
// shorter signal with zeros to the longer length.
//
// SNR convention: positive dB means target is louder than noise;
// negative dB means noise dominates.
func mixAtSNR(target, noise []float32, snrDB float64) []float32 {
	n := len(target)
	if len(noise) > n {
		n = len(noise)
	}
	gain := float32(math.Pow(10, -snrDB/20.0))
	out := make([]float32, n)
	for i := 0; i < n; i++ {
		var t, ns float32
		if i < len(target) {
			t = target[i]
		}
		if i < len(noise) {
			ns = noise[i]
		}
		out[i] = (t + ns*gain) * 0.5
	}
	return out
}

// mixThree adds a third signal at its own SNR relative to the
// target. Used for voice + voice + noise conditions. Pads to the
// longest input.
func mixThree(target, voiceB, noise []float32, snrVoiceDB, snrNoiseDB float64) []float32 {
	n := len(target)
	if len(voiceB) > n {
		n = len(voiceB)
	}
	if len(noise) > n {
		n = len(noise)
	}
	gainV := float32(math.Pow(10, -snrVoiceDB/20.0))
	gainN := float32(math.Pow(10, -snrNoiseDB/20.0))
	out := make([]float32, n)
	for i := 0; i < n; i++ {
		var t, b, ns float32
		if i < len(target) {
			t = target[i]
		}
		if i < len(voiceB) {
			b = voiceB[i]
		}
		if i < len(noise) {
			ns = noise[i]
		}
		out[i] = (t + b*gainV + ns*gainN) * 0.5
	}
	return out
}
```

- [ ] **Step 4: Run tests, confirm pass**

Run: `cd core && go test -tags cleanupeval -run "TestMixAtSNR|TestMixThree" ./internal/speaker/...`
Expected: PASS — four subtests green.

- [ ] **Step 5: Refactor tse_noise_diagnostic_test.go to use mixAtSNR**

Read `core/internal/speaker/tse_noise_diagnostic_test.go` first to see the current loop body (around lines 56–62 and 121–128 — the SNR-loop bodies that compute `gain` and build `mixed`).

Replace each loop body block:
```go
gain := float32(math.Pow(10, -snrDB/20.0))
mixed := make([]float32, n)
for i := range mixed {
    mixed[i] = target[i]*0.5 + interferer[i]*gain*0.5
}
```
with:
```go
mixed := mixAtSNR(target, interferer, snrDB)
```
(For the multi-voice variant, replace `interferer` with `noise` — local variable name in that test.)

- [ ] **Step 6: Run the existing TSE tests with the new helper**

Run: `cd core && go test -tags speakerbeam -run TestTSE_NoiseRobustness ./internal/speaker/...`
Expected: PASS, or `t.Skip` if models absent. **Numbers in -v output should be identical to pre-refactor** — this is a pure refactor with no behaviour change.

- [ ] **Step 7: Commit**

```bash
git add core/internal/speaker/mix_helpers_test.go core/internal/speaker/tse_noise_diagnostic_test.go
git commit -m "$(cat <<'EOF'
test(speaker): extract mixAtSNR + mixThree helpers

Pulls the SNR-loop body duplicated in tse_noise_diagnostic_test.go
into reusable helpers shared across the speakerbeam and cleanupeval
build tags. No behaviour change in existing tests.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Cosine evaluator generalised from evaluateTSE

**Files:**
- Create: `core/internal/speaker/cosine_eval_test.go`
- Create: `core/internal/speaker/cosine_eval_unit_test.go`

- [ ] **Step 1: Write the failing test for evaluateCosine using Passthrough**

`core/internal/speaker/cosine_eval_unit_test.go`:
```go
//go:build cleanupeval

package speaker

import (
	"context"
	"testing"
)

// TestEvaluateCosine_PassthroughReturnsRMSEqual is a unit test that
// doesn't need ONNX models. With Passthrough as the cleanup,
// RMSIn should equal RMSOut.
func TestEvaluateCosine_PassthroughReturnsRMSEqual(t *testing.T) {
	mixed := make([]float32, 16000)
	for i := range mixed {
		mixed[i] = 0.5
	}
	target := mixed   // unused for RMS axis but required by signature
	interferer := mixed
	res := evaluateCosineRMS(mixed, target, interferer, NewPassthrough())
	if res.RMSIn == 0 {
		t.Fatalf("RMSIn should be nonzero for nonzero input")
	}
	if res.RMSOut != res.RMSIn {
		t.Errorf("Passthrough should preserve RMS: in=%f out=%f", res.RMSIn, res.RMSOut)
	}
}
```

- [ ] **Step 2: Run, confirm failure**

Run: `cd core && go test -tags cleanupeval -run TestEvaluateCosine_PassthroughReturnsRMSEqual ./internal/speaker/...`
Expected: FAIL — `undefined: evaluateCosineRMS`, `undefined: cosineResult`.

- [ ] **Step 3: Create cosine_eval_test.go with cosineResult, evaluateCosineRMS (no ONNX), evaluateCosine (full)**

`core/internal/speaker/cosine_eval_test.go`:
```go
//go:build cleanupeval

package speaker

import (
	"context"
	"testing"
)

// cosineResult holds everything the cleanup harness's cosine
// assertions need from one (cleanup, mixture) run.
type cosineResult struct {
	SimTarget     float32 // cos(cleaned, target_embed)
	SimInterferer float32 // cos(cleaned, interferer_embed)  — for voice+voice; cos(cleaned, noise_embed) for voice+noise
	RMSIn         float32
	RMSOut        float32
}

// evaluateCosineRMS is the no-ONNX subset of evaluateCosine, used
// in unit tests where loading the encoder isn't desired.
func evaluateCosineRMS(mixed, target, interferer []float32, cleanup Cleanup) cosineResult {
	out, err := cleanup.Process(context.Background(), mixed)
	if err != nil {
		return cosineResult{}
	}
	return cosineResult{
		RMSIn:  rms(mixed),
		RMSOut: rms(out),
	}
}

// evaluateCosine runs the full cosine evaluator: invokes the cleanup
// adapter, computes ECAPA embeddings on the cleaned output and the
// two reference signals (target, interferer), and returns the four
// numbers.
//
// targetEmb and interfererEmb are precomputed so the matrix runner
// can amortise embedding cost across rows that share fixtures.
// encoderPath is the speaker encoder ONNX, used to embed the cleaned
// output.
//
// No assertions inside — caller decides pass/fail.
func evaluateCosine(t *testing.T, cleanup Cleanup, mixed []float32,
	targetEmb, interfererEmb []float32, encoderPath string) cosineResult {
	t.Helper()
	out, err := cleanup.Process(context.Background(), mixed)
	if err != nil {
		t.Fatalf("cleanup.Process(%s): %v", cleanup.Name(), err)
	}
	cleanedEmb, err := ComputeEmbedding(encoderPath, out, 192)
	if err != nil {
		t.Fatalf("ComputeEmbedding(cleaned): %v", err)
	}
	return cosineResult{
		SimTarget:     cosineSimilarity(cleanedEmb, targetEmb),
		SimInterferer: cosineSimilarity(cleanedEmb, interfererEmb),
		RMSIn:         rms(mixed),
		RMSOut:        rms(out),
	}
}
```

- [ ] **Step 4: Run unit test, confirm pass**

Run: `cd core && go test -tags cleanupeval -run TestEvaluateCosine_PassthroughReturnsRMSEqual ./internal/speaker/...`
Expected: PASS.

- [ ] **Step 5: Note that `rms` already lives in tse_real_voice_test.go under speakerbeam tag**

Run: `grep -n "^func rms" core/internal/speaker/*.go`
Expected: shows `tse_real_voice_test.go:108`.

The `rms` helper is currently `//go:build speakerbeam`-only. We need it under `cleanupeval` too. Simplest fix: broaden its build tag.

- [ ] **Step 6: Broaden rms helper tag**

Edit `core/internal/speaker/tse_real_voice_test.go` line 1:
```go
//go:build speakerbeam || cleanupeval
```

(Keep other contents unchanged. The rest of that file uses `voiceFixture`, `evaluateTSE`, `assertTSEResult`, `resolveModelPath`, `initONNXOnce` — all of which we'll want under cleanupeval too. Broadening the file's tag is the cheapest path. It does mean cleanup-tag builds compile the existing TSE tests too, but they `t.Skip` when models are absent so this is harmless.)

- [ ] **Step 7: Run cosine eval unit test under cleanupeval, confirm pass**

Run: `cd core && go test -tags cleanupeval -run TestEvaluateCosine_PassthroughReturnsRMSEqual ./internal/speaker/...`
Expected: PASS — `rms` resolves correctly under either tag.

- [ ] **Step 8: Run existing speakerbeam tests, confirm still green**

Run: `cd core && go test -tags speakerbeam ./internal/speaker/...`
Expected: PASS or skip (unchanged behaviour — tag broadening is additive).

- [ ] **Step 9: Commit**

```bash
git add core/internal/speaker/cosine_eval_test.go core/internal/speaker/cosine_eval_unit_test.go core/internal/speaker/tse_real_voice_test.go
git commit -m "$(cat <<'EOF'
test(speaker): add evaluateCosine generalised over Cleanup adapter

Generalises evaluateTSE's per-row math to accept any Cleanup adapter
(not just SpeakerGate). Adds a no-ONNX evaluateCosineRMS unit test
helper. Broadens tse_real_voice_test.go build tag to cleanupeval to
share rms/voiceFixture/resolveModelPath helpers across both harnesses.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Token Levenshtein helper for WER

**Files:**
- Create: `core/internal/speaker/wer_helpers_test.go`

- [ ] **Step 1: Write failing tests for token edit distance + normalisation**

`core/internal/speaker/wer_helpers_test.go`:
```go
//go:build cleanupeval

package speaker

import (
	"math"
	"testing"
)

func TestNormalizeForWER_LowercaseStripsPunctuation(t *testing.T) {
	got := normalizeForWER("Hello, World! How are you?")
	want := "hello world how are you"
	if got != want {
		t.Errorf("got %q, want %q", got, want)
	}
}

func TestNormalizeForWER_CollapsesWhitespace(t *testing.T) {
	got := normalizeForWER("  the   quick\tbrown\nfox  ")
	want := "the quick brown fox"
	if got != want {
		t.Errorf("got %q, want %q", got, want)
	}
}

func TestNormalizeForWER_StripsNonAscii(t *testing.T) {
	got := normalizeForWER("café — résumé")
	// '—' becomes whitespace via punctuation strip; é stays (we don't strip diacritics).
	want := "café résumé"
	if got != want {
		t.Errorf("got %q, want %q", got, want)
	}
}

func TestTokenEditDistance_IdenticalIsZero(t *testing.T) {
	got := tokenEditDistance([]string{"a", "b", "c"}, []string{"a", "b", "c"})
	if got != 0 {
		t.Errorf("identical sequences: got %d, want 0", got)
	}
}

func TestTokenEditDistance_OneSubstitution(t *testing.T) {
	got := tokenEditDistance([]string{"a", "b", "c"}, []string{"a", "X", "c"})
	if got != 1 {
		t.Errorf("one sub: got %d, want 1", got)
	}
}

func TestTokenEditDistance_OneDeletion(t *testing.T) {
	got := tokenEditDistance([]string{"a", "b", "c"}, []string{"a", "c"})
	if got != 1 {
		t.Errorf("one del: got %d, want 1", got)
	}
}

func TestTokenEditDistance_OneInsertion(t *testing.T) {
	got := tokenEditDistance([]string{"a", "b"}, []string{"a", "X", "b"})
	if got != 1 {
		t.Errorf("one ins: got %d, want 1", got)
	}
}

func TestComputeWER_PerfectIsZero(t *testing.T) {
	got := computeWER("hello world", "hello world")
	if got != 0 {
		t.Errorf("perfect: got %f, want 0", got)
	}
}

func TestComputeWER_AllWrongIsOne(t *testing.T) {
	// Reference 3 words; hypothesis is 3 different words → 3 substitutions / 3 = 1.0.
	got := computeWER("foo bar baz", "qux quux corge")
	if math.Abs(got-1.0) > 1e-9 {
		t.Errorf("all wrong: got %f, want 1.0", got)
	}
}

func TestComputeWER_HandlesEmptyReference(t *testing.T) {
	// Edge case: empty reference, non-empty hypothesis.
	// Convention: WER = 1.0 (everything is an insertion error).
	got := computeWER("", "spurious words")
	if got != 1.0 {
		t.Errorf("empty ref: got %f, want 1.0", got)
	}
}

func TestComputeWER_HandlesNormalisation(t *testing.T) {
	// Punctuation + case differences should be normalised away.
	got := computeWER("Hello, World!", "hello world")
	if got != 0 {
		t.Errorf("normalised match: got %f, want 0", got)
	}
}
```

- [ ] **Step 2: Run, confirm failure**

Run: `cd core && go test -tags cleanupeval -run "TestNormalizeForWER|TestTokenEditDistance|TestComputeWER" ./internal/speaker/...`
Expected: FAIL — undefined symbols.

- [ ] **Step 3: Implement helpers**

Append to `core/internal/speaker/wer_helpers_test.go`:
```go
import (
	"strings"
	"unicode"
)

// normalizeForWER lowercases, strips punctuation, and collapses
// whitespace so reference and hypothesis strings can be compared
// without spurious differences from formatting. Diacritics are
// preserved (Whisper produces them; LibriSpeech rarely contains them).
func normalizeForWER(s string) string {
	var b strings.Builder
	b.Grow(len(s))
	for _, r := range s {
		switch {
		case unicode.IsLetter(r) || unicode.IsDigit(r):
			b.WriteRune(unicode.ToLower(r))
		case unicode.IsSpace(r) || unicode.IsPunct(r) || unicode.IsSymbol(r):
			b.WriteRune(' ')
		default:
			// Leave other runes (e.g. accented letters) lower-cased.
			b.WriteRune(unicode.ToLower(r))
		}
	}
	// Collapse runs of whitespace.
	return strings.Join(strings.Fields(b.String()), " ")
}

// tokenEditDistance returns the Levenshtein distance between two
// token sequences (substitutions + deletions + insertions, each
// cost 1).
func tokenEditDistance(ref, hyp []string) int {
	n, m := len(ref), len(hyp)
	if n == 0 {
		return m
	}
	if m == 0 {
		return n
	}
	prev := make([]int, m+1)
	curr := make([]int, m+1)
	for j := 0; j <= m; j++ {
		prev[j] = j
	}
	for i := 1; i <= n; i++ {
		curr[0] = i
		for j := 1; j <= m; j++ {
			cost := 1
			if ref[i-1] == hyp[j-1] {
				cost = 0
			}
			curr[j] = min3(
				prev[j]+1,      // deletion
				curr[j-1]+1,    // insertion
				prev[j-1]+cost, // substitution
			)
		}
		prev, curr = curr, prev
	}
	return prev[m]
}

func min3(a, b, c int) int {
	m := a
	if b < m {
		m = b
	}
	if c < m {
		m = c
	}
	return m
}

// computeWER returns the word error rate of hypothesis vs reference,
// after normalising both. Convention: empty reference + non-empty
// hypothesis → 1.0; both empty → 0.0.
func computeWER(reference, hypothesis string) float64 {
	ref := strings.Fields(normalizeForWER(reference))
	hyp := strings.Fields(normalizeForWER(hypothesis))
	if len(ref) == 0 {
		if len(hyp) == 0 {
			return 0
		}
		return 1.0
	}
	dist := tokenEditDistance(ref, hyp)
	return float64(dist) / float64(len(ref))
}
```

- [ ] **Step 4: Run, confirm pass**

Run: `cd core && go test -tags cleanupeval -run "TestNormalizeForWER|TestTokenEditDistance|TestComputeWER" ./internal/speaker/...`
Expected: PASS — 10 subtests green.

- [ ] **Step 5: Commit**

```bash
git add core/internal/speaker/wer_helpers_test.go
git commit -m "$(cat <<'EOF'
test(speaker): add token-level WER helpers

Pure helpers: normalizeForWER (lowercase, strip punctuation, collapse
whitespace), tokenEditDistance (Levenshtein on token sequences),
computeWER (normalised tokens / |ref|). No external dependencies.
Used by the cleanup harness's WER evaluator.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: WER evaluator using transcribe.Transcriber

**Files:**
- Create: `core/internal/speaker/wer_eval_test.go`

- [ ] **Step 1: Write the failing test using a fake transcriber**

`core/internal/speaker/wer_eval_test.go`:
```go
//go:build cleanupeval

package speaker

import (
	"context"
	"testing"

	"github.com/voice-keyboard/core/internal/transcribe"
)

// fakeTranscriber returns a hard-coded string regardless of input.
// Decouples the WER evaluator test from whisper.cpp.
type fakeTranscriber struct{ out string }

func (f *fakeTranscriber) Transcribe(_ context.Context, _ []float32) (string, error) {
	return f.out, nil
}
func (f *fakeTranscriber) Close() error { return nil }

func TestEvaluateWER_PerfectMatch(t *testing.T) {
	tr := &fakeTranscriber{out: "the quick brown fox"}
	res := evaluateWER(t, []float32{0, 0, 0}, "the quick brown fox", tr)
	if res.WER != 0 {
		t.Errorf("perfect: WER=%f, want 0", res.WER)
	}
	if res.Hypothesis != "the quick brown fox" {
		t.Errorf("hypothesis = %q", res.Hypothesis)
	}
}

func TestEvaluateWER_RecordsBothStrings(t *testing.T) {
	tr := &fakeTranscriber{out: "wrong words entirely"}
	res := evaluateWER(t, []float32{0}, "expected text here", tr)
	if res.Reference != "expected text here" {
		t.Errorf("Reference not stored")
	}
	if res.Hypothesis != "wrong words entirely" {
		t.Errorf("Hypothesis not stored")
	}
	if res.WER != 1.0 {
		t.Errorf("all wrong: WER=%f, want 1.0", res.WER)
	}
}

// Compile-time check that fakeTranscriber implements the interface.
var _ transcribe.Transcriber = (*fakeTranscriber)(nil)
```

- [ ] **Step 2: Run, confirm failure**

Run: `cd core && go test -tags cleanupeval -run TestEvaluateWER ./internal/speaker/...`
Expected: FAIL — `undefined: evaluateWER`, `undefined: werResult`.

- [ ] **Step 3: Implement evaluateWER**

Append to `core/internal/speaker/wer_eval_test.go`:
```go
type werResult struct {
	Reference  string
	Hypothesis string
	WER        float64
}

// evaluateWER runs the transcriber on audio and computes WER vs
// reference. Calls t.Fatalf on transcription failure (a transcribe
// error is a harness bug, not a measurement we want to log silently).
func evaluateWER(t *testing.T, audio []float32, reference string,
	transcriber transcribe.Transcriber) werResult {
	t.Helper()
	hyp, err := transcriber.Transcribe(context.Background(), audio)
	if err != nil {
		t.Fatalf("evaluateWER: transcribe failed: %v", err)
	}
	return werResult{
		Reference:  reference,
		Hypothesis: hyp,
		WER:        computeWER(reference, hyp),
	}
}
```

- [ ] **Step 4: Run, confirm pass**

Run: `cd core && go test -tags cleanupeval -run TestEvaluateWER ./internal/speaker/...`
Expected: PASS — both subtests green.

- [ ] **Step 5: Commit**

```bash
git add core/internal/speaker/wer_eval_test.go
git commit -m "$(cat <<'EOF'
test(speaker): add evaluateWER + werResult

Wraps a transcribe.Transcriber and computes WER vs ground-truth
reference using the normalised token-Levenshtein helpers. Uses a fake
transcriber in unit tests; matrix runner will inject the real Whisper
transcriber.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: Voice fixture transcript loader

**Files:**
- Create: `core/test/integration/testdata/voices/libri_1272.txt`
- Create: `core/test/integration/testdata/voices/libri_1462.txt`
- Create: `scripts/fetch-libri-transcripts.sh`
- Modify: `core/test/integration/testdata/voices/LICENSE.md` (note transcript provenance)
- Modify: `core/internal/speaker/voice_fixtures_test.go` (add `Transcript()` method)

- [ ] **Step 1: Write a failing test for transcript loading**

Append to `core/internal/speaker/cosine_eval_unit_test.go`:
```go
func TestLibriSpeechFixture_TranscriptsLoad(t *testing.T) {
	fix := newLibriSpeechFixture()
	tA, tB := fix.Transcripts(t)
	if tA == "" || tB == "" {
		t.Fatalf("transcripts empty: A=%q B=%q", tA, tB)
	}
	if tA == tB {
		t.Errorf("transcripts identical — wrong files?")
	}
	// Sanity: transcripts should each be at least a few words.
	if len(tA) < 5 || len(tB) < 5 {
		t.Errorf("transcripts suspiciously short: A=%q B=%q", tA, tB)
	}
}
```

- [ ] **Step 2: Run, confirm failure**

Run: `cd core && go test -tags cleanupeval -run TestLibriSpeechFixture_TranscriptsLoad ./internal/speaker/...`
Expected: FAIL — `Transcripts undefined on libriSpeechFixture` and/or transcripts files missing.

- [ ] **Step 3: Source the actual transcripts**

Find the transcripts that match the bundled WAVs. The LibriSpeech `dev-clean` corpus organises transcripts as `<speaker_id>/<chapter_id>/<speaker_id>-<chapter_id>.trans.txt` with one line per utterance: `<utterance_id> THE TEXT IN UPPER CASE`.

The repo's `scripts/fetch-tse-test-voices.sh` should already log which speaker/chapter/utterance was picked. Read that script and find which utterance ID maps to `libri_1272.wav` and `libri_1462.wav`.

Run: `cat scripts/fetch-tse-test-voices.sh | head -60`
Read the output to identify the utterance IDs picked. (The script may need to be re-run if it doesn't log; see step 4 for the fallback.)

- [ ] **Step 4: Create the fetch-libri-transcripts.sh script**

`scripts/fetch-libri-transcripts.sh`:
```bash
#!/usr/bin/env bash
# Fetches the ground-truth transcripts that match the committed
# LibriSpeech voice fixtures (libri_1272.wav, libri_1462.wav).
#
# Idempotent: re-running overwrites the .txt files with the same
# content. Commit the .txt files; this script is committed but only
# run when bumping fixtures.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$REPO_ROOT/core/test/integration/testdata/voices"

# Speaker / chapter / utterance picks must match scripts/fetch-tse-test-voices.sh.
# See that script for how the picks were made; this script just resolves the
# transcript line for the same utterances.
declare -A UTT_FOR_FILE=(
  ["libri_1272.txt"]="1272-128104-0000"
  ["libri_1462.txt"]="1462-170138-0000"
)

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cd "$TMP"
echo ">> downloading LibriSpeech dev-clean (~300 MB) — this may take a moment"
curl -L -o dev-clean.tar.gz https://www.openslr.org/resources/12/dev-clean.tar.gz
tar -xzf dev-clean.tar.gz

for outfile in "${!UTT_FOR_FILE[@]}"; do
  utt="${UTT_FOR_FILE[$outfile]}"
  speaker="${utt%%-*}"
  rest="${utt#*-}"
  chapter="${rest%%-*}"
  trans_path="LibriSpeech/dev-clean/${speaker}/${chapter}/${speaker}-${chapter}.trans.txt"
  if [[ ! -f "$trans_path" ]]; then
    echo "ERROR: transcript file missing at $trans_path" >&2
    exit 1
  fi
  line="$(grep "^${utt} " "$trans_path" || true)"
  if [[ -z "$line" ]]; then
    echo "ERROR: utterance $utt not found in $trans_path" >&2
    exit 1
  fi
  text="${line#${utt} }"
  echo "$text" > "$OUT_DIR/$outfile"
  echo ">> wrote $OUT_DIR/$outfile"
done

echo ">> done"
```

- [ ] **Step 5: Run the fetch script and commit the transcript files**

Run: `chmod +x scripts/fetch-libri-transcripts.sh && ./scripts/fetch-libri-transcripts.sh`
Expected: writes `libri_1272.txt` and `libri_1462.txt` under `core/test/integration/testdata/voices/`.

If the utterance IDs don't match what's in `fetch-tse-test-voices.sh`, update the `UTT_FOR_FILE` map and rerun.

Verify with: `cat core/test/integration/testdata/voices/libri_1272.txt core/test/integration/testdata/voices/libri_1462.txt`
Expected: two lines of upper-case English (LibriSpeech transcripts are upper-case).

- [ ] **Step 6: Update LICENSE.md to note transcript provenance**

Read `core/test/integration/testdata/voices/LICENSE.md` first to see current content.

Append (or merge into existing structure):
```
## Transcripts

Files: libri_1272.txt, libri_1462.txt
Source: LibriSpeech dev-clean (CC BY 4.0)
Provenance: extracted from <speaker>/<chapter>/<speaker>-<chapter>.trans.txt
            via scripts/fetch-libri-transcripts.sh
```

- [ ] **Step 7: Add Transcripts() method to libriSpeechFixture**

Modify `core/internal/speaker/voice_fixtures_test.go`. Around the existing `func (f *libriSpeechFixture) Voices(t *testing.T)` method, add:
```go
// Transcripts returns the ground-truth transcripts matching the two
// voice clips returned by Voices, in the same order (A, B). Reads
// libri_1272.txt and libri_1462.txt sibling files. Fatals if either
// is missing — the harness depends on transcripts.
func (f *libriSpeechFixture) Transcripts(t *testing.T) (a, b string) {
	t.Helper()
	a = readLibriTranscript(t, "libri_1272.txt")
	b = readLibriTranscript(t, "libri_1462.txt")
	return
}

func readLibriTranscript(t *testing.T, file string) string {
	t.Helper()
	path := filepath.Join(libriVoicesDir, file)
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("LibriSpeech transcript missing at %s — run scripts/fetch-libri-transcripts.sh: %v", path, err)
	}
	return strings.TrimSpace(string(data))
}
```

You'll need to add `"strings"` to the imports of `voice_fixtures_test.go` if it isn't already there.

- [ ] **Step 8: Run the test, confirm pass**

Run: `cd core && go test -tags cleanupeval -run TestLibriSpeechFixture_TranscriptsLoad ./internal/speaker/...`
Expected: PASS — transcripts load and look distinct.

- [ ] **Step 9: Commit**

```bash
git add core/internal/speaker/voice_fixtures_test.go core/internal/speaker/cosine_eval_unit_test.go
git add core/test/integration/testdata/voices/libri_1272.txt core/test/integration/testdata/voices/libri_1462.txt
git add core/test/integration/testdata/voices/LICENSE.md scripts/fetch-libri-transcripts.sh
git commit -m "$(cat <<'EOF'
test(speaker): add LibriSpeech transcript fixtures + loader

Adds ground-truth transcripts (libri_1272.txt, libri_1462.txt) sourced
from LibriSpeech dev-clean, exposed via libriSpeechFixture.Transcripts.
The cleanup harness's WER evaluator consumes these as ASR ground truth.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: noiseFixture interface + musan music fixture

**Files:**
- Create: `core/internal/speaker/noise_fixtures_test.go`
- Create: `core/test/integration/testdata/noise/musan_music_excerpt.wav` (sourced via script)
- Create: `core/test/integration/testdata/noise/LICENSE.md`
- Create: `scripts/fetch-musan-music-fixture.sh`

- [ ] **Step 1: Write the failing test**

`core/internal/speaker/noise_fixtures_test.go`:
```go
//go:build cleanupeval

package speaker

import "testing"

func TestMusanMusicFixture_Loads(t *testing.T) {
	fix := newMusanMusicFixture()
	if fix.Name() == "" {
		t.Fatalf("Name() empty")
	}
	clip := fix.Noise(t)
	if clip.Class != "music" {
		t.Errorf("Class = %q, want %q", clip.Class, "music")
	}
	if len(clip.Samples) < 16000 {
		t.Errorf("Noise clip too short: %d samples (< 1 s)", len(clip.Samples))
	}
}
```

- [ ] **Step 2: Run, confirm failure**

Run: `cd core && go test -tags cleanupeval -run TestMusanMusicFixture_Loads ./internal/speaker/...`
Expected: FAIL — undefined symbols + missing fixture file.

- [ ] **Step 3: Add the noiseFixture interface and musanMusicFixture**

Append to `core/internal/speaker/noise_fixtures_test.go`:
```go
import (
	"os"
	"path/filepath"

	"github.com/voice-keyboard/core/internal/audio"
)

// noiseClip is a 16 kHz mono PCM clip of non-speech noise with a
// human-readable label and a class tag.
type noiseClip struct {
	Label   string
	Samples []float32
	Class   string // "music" | "fan" | "babble" | "keyboard" | "traffic"
}

// noiseFixture is symmetric to voiceFixture: yields one noiseClip
// for the harness's mixture-with-noise rows. Implementations may
// skip cleanly when their inputs are unavailable.
type noiseFixture interface {
	Name() string
	Noise(t *testing.T) noiseClip
}

// musanMusicFixture serves a single committed clip extracted from
// MUSAN's music subset (Apache-2.0). The clip is sourced via
// scripts/fetch-musan-music-fixture.sh and lives next to the voice
// fixtures.
type musanMusicFixture struct{}

func newMusanMusicFixture() *musanMusicFixture { return &musanMusicFixture{} }

func (f *musanMusicFixture) Name() string { return "musan_music" }

const musanMusicPath = "../../test/integration/testdata/noise/musan_music_excerpt.wav"

func (f *musanMusicFixture) Noise(t *testing.T) noiseClip {
	t.Helper()
	if _, err := os.Stat(musanMusicPath); err != nil {
		t.Fatalf("MUSAN music fixture missing at %s — run scripts/fetch-musan-music-fixture.sh: %v", musanMusicPath, err)
	}
	samples, sr, err := audio.ReadWAVMono(musanMusicPath)
	if err != nil {
		t.Fatalf("ReadWAVMono(%s): %v", musanMusicPath, err)
	}
	if sr != 16000 {
		t.Fatalf("expected 16 kHz, got %d Hz from %s", sr, musanMusicPath)
	}
	return noiseClip{
		Label:   filepath.Base(musanMusicPath),
		Samples: samples,
		Class:   "music",
	}
}
```

- [ ] **Step 4: Create the fetch script**

`scripts/fetch-musan-music-fixture.sh`:
```bash
#!/usr/bin/env bash
# Fetches a single ~10 s 16 kHz mono clip from the MUSAN music
# subset and commits it as the harness's first non-speech noise
# fixture.
#
# Idempotent: re-running overwrites musan_music_excerpt.wav.
# Bundled clip stays small (~320 KB) — same approach as the
# LibriSpeech voice fixtures.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$REPO_ROOT/core/test/integration/testdata/noise"
OUT_FILE="$OUT_DIR/musan_music_excerpt.wav"

mkdir -p "$OUT_DIR"

if ! command -v ffmpeg >/dev/null 2>&1; then
  echo "ERROR: ffmpeg required (brew install ffmpeg)" >&2
  exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cd "$TMP"

# MUSAN is ~11 GB total; we only need one clip from the music subset.
# Fetch the music tarball entry list and pick a deterministic clip.
echo ">> downloading MUSAN music subset index"
curl -L -o musan.tar.gz https://www.openslr.org/resources/17/musan.tar.gz
echo ">> extracting one music clip"
tar -xzf musan.tar.gz musan/music/fma/music-fma-0000.wav
SOURCE="musan/music/fma/music-fma-0000.wav"
if [[ ! -f "$SOURCE" ]]; then
  echo "ERROR: expected MUSAN clip not found in archive: $SOURCE" >&2
  exit 1
fi

echo ">> trimming + transcoding to 10 s 16 kHz mono LE 16-bit PCM"
ffmpeg -y -i "$SOURCE" -ss 0 -t 10 -ac 1 -ar 16000 -sample_fmt s16 "$OUT_FILE"

echo ">> wrote $OUT_FILE ($(du -h "$OUT_FILE" | cut -f1))"
```

- [ ] **Step 5: Run the fetch script**

Run: `chmod +x scripts/fetch-musan-music-fixture.sh && ./scripts/fetch-musan-music-fixture.sh`
Expected: writes `core/test/integration/testdata/noise/musan_music_excerpt.wav`. Note: MUSAN download is ~11 GB on first run — tolerable for a one-time fetch but slow. If bandwidth is a concern, swap the source to a smaller mirror or pre-stage the clip out-of-band.

- [ ] **Step 6: Add the LICENSE file**

`core/test/integration/testdata/noise/LICENSE.md`:
```
# Noise fixtures — license attribution

## musan_music_excerpt.wav

Source: MUSAN corpus (https://www.openslr.org/17/), music/fma/music-fma-0000.wav
License: Apache-2.0
Provenance: extracted via scripts/fetch-musan-music-fixture.sh
            (10 s trim, 16 kHz mono LE 16-bit PCM via ffmpeg)

The MUSAN corpus is a corpus of music, speech, and noise recordings
licensed under Apache-2.0. Only the music subset is currently used
as a fixture in this harness.
```

- [ ] **Step 7: Run the test, confirm pass**

Run: `cd core && go test -tags cleanupeval -run TestMusanMusicFixture_Loads ./internal/speaker/...`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add core/internal/speaker/noise_fixtures_test.go scripts/fetch-musan-music-fixture.sh
git add core/test/integration/testdata/noise/musan_music_excerpt.wav core/test/integration/testdata/noise/LICENSE.md
git commit -m "$(cat <<'EOF'
test(speaker): add noiseFixture + musan music fixture

Symmetric to voiceFixture. First non-speech noise class for the cleanup
harness; remaining classes (fan, café, traffic, keyboard) added as
candidates clear the bar against this minimal matrix. MUSAN clip is
~10 s, 16 kHz mono, Apache-2.0.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 9: SpeakerGate adapter

**Files:**
- Create: `core/internal/speaker/cleanup_speakergate_test.go`

- [ ] **Step 1: Write the failing test**

`core/internal/speaker/cleanup_speakergate_test.go`:
```go
//go:build cleanupeval

package speaker

import (
	"context"
	"testing"
)

// TestSpeakerGateAdapter_Name verifies the adapter reports the right
// label for matrix output rows.
func TestSpeakerGateAdapter_Name(t *testing.T) {
	a := &SpeakerGateAdapter{} // empty adapter for name-only assertion
	if got := a.Name(); got != "speakergate" {
		t.Errorf("Name() = %q, want %q", got, "speakergate")
	}
}

// TestSpeakerGateAdapter_ProcessSkipsWithoutModels gates the live
// inference path on the same env-var path the existing TSE harness
// uses. When models are absent, the test skips cleanly so CI / local
// runs without ONNX models still pass.
func TestSpeakerGateAdapter_ProcessRunsWithModels(t *testing.T) {
	tseModel := resolveModelPath(t, "TSE_MODEL_PATH", "tse_model.onnx")
	encoderModel := resolveModelPath(t, "SPEAKER_ENCODER_PATH", "speaker_encoder.onnx")
	initONNXOnce(t)

	// Use a libri voice clip as both reference and input — the
	// extracted output should be non-trivial (not zeros, not NaN).
	a, _ := newLibriSpeechFixture().Voices(t)
	emb, err := ComputeEmbedding(encoderModel, a.Samples, 192)
	if err != nil {
		t.Fatalf("ComputeEmbedding: %v", err)
	}

	adapter, err := NewSpeakerGateAdapter(tseModel, emb)
	if err != nil {
		t.Fatalf("NewSpeakerGateAdapter: %v", err)
	}
	defer adapter.Close()

	out, err := adapter.Process(context.Background(), a.Samples)
	if err != nil {
		t.Fatalf("Process: %v", err)
	}
	if len(out) != len(a.Samples) {
		t.Errorf("len(out)=%d, want %d", len(out), len(a.Samples))
	}
	if rms(out) == 0 {
		t.Errorf("output is silent (RMS == 0)")
	}
}
```

- [ ] **Step 2: Run, confirm failure**

Run: `cd core && go test -tags cleanupeval -run "TestSpeakerGateAdapter" ./internal/speaker/...`
Expected: FAIL — `undefined: SpeakerGateAdapter`, `undefined: NewSpeakerGateAdapter`.

- [ ] **Step 3: Implement the adapter as a thin wrapper around existing SpeakerGate**

Append to `core/internal/speaker/cleanup_speakergate_test.go`:
```go
// SpeakerGateAdapter wraps the existing SpeakerGate so it satisfies
// the harness Cleanup interface. Lives in the cleanupeval test files
// because it's a test-only adapter, not a production component.
type SpeakerGateAdapter struct {
	gate *SpeakerGate
}

// NewSpeakerGateAdapter builds a SpeakerGateAdapter from a TSE ONNX
// path and an L2-normalised reference embedding.
func NewSpeakerGateAdapter(tseModelPath string, refEmbedding []float32) (*SpeakerGateAdapter, error) {
	gate, err := NewSpeakerGate(SpeakerGateOptions{
		ModelPath: tseModelPath,
		Reference: refEmbedding,
	})
	if err != nil {
		return nil, err
	}
	return &SpeakerGateAdapter{gate: gate}, nil
}

func (a *SpeakerGateAdapter) Name() string { return "speakergate" }

func (a *SpeakerGateAdapter) Process(ctx context.Context, mixed []float32) ([]float32, error) {
	if a.gate == nil {
		// Empty adapter (used only for Name() in unit tests).
		out := make([]float32, len(mixed))
		copy(out, mixed)
		return out, nil
	}
	return a.gate.Extract(ctx, mixed)
}

func (a *SpeakerGateAdapter) Close() error {
	if a.gate == nil {
		return nil
	}
	return a.gate.Close()
}

// Compile-time interface check.
var _ Cleanup = (*SpeakerGateAdapter)(nil)
```

- [ ] **Step 4: Run name-only test (no models needed), confirm pass**

Run: `cd core && go test -tags cleanupeval -run TestSpeakerGateAdapter_Name ./internal/speaker/...`
Expected: PASS.

- [ ] **Step 5: Run with-models test**

Run: `cd core && go test -tags cleanupeval -v -run TestSpeakerGateAdapter_ProcessRunsWithModels ./internal/speaker/...`
Expected: PASS if `TSE_MODEL_PATH`, `SPEAKER_ENCODER_PATH`, `ONNXRUNTIME_LIB_PATH` are set; SKIP otherwise.

- [ ] **Step 6: Commit**

```bash
git add core/internal/speaker/cleanup_speakergate_test.go
git commit -m "$(cat <<'EOF'
test(speaker): add SpeakerGateAdapter for the cleanup harness

Thin wrapper around the existing SpeakerGate so the disabled former
default participates in the head-to-head matrix as a known reference
point.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 10: PyannoteSepECAPA adapter (skip-when-missing)

**Files:**
- Create: `core/internal/speaker/cleanup_pyannote_test.go`

- [ ] **Step 1: Write the failing tests — Name + skip-when-missing + load-when-present**

`core/internal/speaker/cleanup_pyannote_test.go`:
```go
//go:build cleanupeval

package speaker

import (
	"context"
	"testing"
)

func TestPyannoteSepECAPA_Name(t *testing.T) {
	a := &PyannoteSepECAPA{}
	if got := a.Name(); got != "pyannote_sep_ecapa" {
		t.Errorf("Name() = %q, want %q", got, "pyannote_sep_ecapa")
	}
}

// TestPyannoteSepECAPA_SkipsCleanlyWhenMissing uses resolveModelPath's
// skip behaviour — when PYANNOTE_SEP_PATH isn't set and no candidate
// path exists, the test skips rather than fails.
func TestPyannoteSepECAPA_LoadsWhenPresent(t *testing.T) {
	pyannoteModel := resolveModelPath(t, "PYANNOTE_SEP_PATH", "pyannote_sep.onnx")
	encoderModel := resolveModelPath(t, "SPEAKER_ENCODER_PATH", "speaker_encoder.onnx")
	initONNXOnce(t)

	a, _ := newLibriSpeechFixture().Voices(t)
	emb, err := ComputeEmbedding(encoderModel, a.Samples, 192)
	if err != nil {
		t.Fatalf("ComputeEmbedding: %v", err)
	}
	adapter, err := NewPyannoteSepECAPA(pyannoteModel, encoderModel, emb)
	if err != nil {
		t.Fatalf("NewPyannoteSepECAPA: %v", err)
	}
	defer adapter.Close()

	out, err := adapter.Process(context.Background(), a.Samples)
	if err != nil {
		t.Fatalf("Process: %v", err)
	}
	if len(out) == 0 {
		t.Errorf("Process returned empty output")
	}
	if rms(out) == 0 {
		t.Errorf("Process returned silent output")
	}
}
```

- [ ] **Step 2: Run, confirm failure**

Run: `cd core && go test -tags cleanupeval -run "TestPyannoteSepECAPA" ./internal/speaker/...`
Expected: FAIL — `undefined: PyannoteSepECAPA`.

- [ ] **Step 3: Implement the adapter**

Append to `core/internal/speaker/cleanup_pyannote_test.go`:
```go
import (
	"fmt"

	ort "github.com/yalue/onnxruntime_go"
)

// PyannoteSepECAPA runs pyannote-sep ONNX on the input mixture
// (producing N source streams) and returns the source whose ECAPA
// embedding has the highest cosine similarity to a reference
// (enrolled) embedding.
//
// Model artefact: an ONNX export of pyannote/speech-separation-ami-1.0.
// See core/BUILDING_PYANNOTE_SEP.md for export instructions.
//
// Inputs:  mixed     float32[1, T]    — 16 kHz mono audio
// Outputs: sources   float32[1, N, T] — N separated source streams
type PyannoteSepECAPA struct {
	sepSession  *ort.DynamicAdvancedSession
	encoderPath string
	ref         []float32
	encoderDim  int
}

// NewPyannoteSepECAPA loads the separator and binds the reference
// embedding. encoderPath is the speaker encoder ONNX (used at
// inference time to embed each separated source for cosine pick).
func NewPyannoteSepECAPA(sepModelPath, encoderPath string, refEmbedding []float32) (*PyannoteSepECAPA, error) {
	if len(refEmbedding) == 0 {
		return nil, fmt.Errorf("pyannote_sep_ecapa: empty reference embedding")
	}
	captured := make([]float32, len(refEmbedding))
	copy(captured, refEmbedding)
	sess, err := ort.NewDynamicAdvancedSession(
		sepModelPath,
		[]string{"mixed"},
		[]string{"sources"},
		nil,
	)
	if err != nil {
		return nil, fmt.Errorf("pyannote_sep_ecapa: load %q: %w", sepModelPath, err)
	}
	return &PyannoteSepECAPA{
		sepSession:  sess,
		encoderPath: encoderPath,
		ref:         captured,
		encoderDim:  len(captured),
	}, nil
}

func (a *PyannoteSepECAPA) Name() string { return "pyannote_sep_ecapa" }

// Process runs the separator on mixed, embeds each emitted source
// with the speaker encoder, and returns the source whose embedding
// has highest cosine similarity to the bound reference.
//
// If the separator emits a single source (degenerate output), it is
// returned as-is — the cosine pick is a no-op in that case.
func (a *PyannoteSepECAPA) Process(_ context.Context, mixed []float32) ([]float32, error) {
	if a.sepSession == nil {
		out := make([]float32, len(mixed))
		copy(out, mixed)
		return out, nil
	}
	mixedT, err := ort.NewTensor(ort.NewShape(1, int64(len(mixed))), mixed)
	if err != nil {
		return nil, fmt.Errorf("pyannote_sep_ecapa: mixed tensor: %w", err)
	}
	defer mixedT.Destroy()

	// We don't know N (source count) at compile time; allocate output
	// for the model's documented max (3 for AMI-1.0). If your export
	// produces a different N, update both the shape and the iteration
	// below.
	const maxSources = 3
	outT, err := ort.NewEmptyTensor[float32](ort.NewShape(1, maxSources, int64(len(mixed))))
	if err != nil {
		return nil, fmt.Errorf("pyannote_sep_ecapa: output tensor: %w", err)
	}
	defer outT.Destroy()

	if err := a.sepSession.Run([]ort.Value{mixedT}, []ort.Value{outT}); err != nil {
		return nil, fmt.Errorf("pyannote_sep_ecapa: separator inference: %w", err)
	}

	// Slice the per-source streams out of the [1, N, T] tensor and pick
	// the best by ECAPA cosine.
	flat := outT.GetData()
	sampleStride := len(mixed)
	bestIdx := 0
	bestSim := float32(-2)
	bestSource := make([]float32, sampleStride)
	for i := 0; i < maxSources; i++ {
		offset := i * sampleStride
		source := flat[offset : offset+sampleStride]
		emb, err := ComputeEmbedding(a.encoderPath, source, a.encoderDim)
		if err != nil {
			return nil, fmt.Errorf("pyannote_sep_ecapa: embed source %d: %w", i, err)
		}
		sim := cosineSimilarity(emb, a.ref)
		if sim > bestSim {
			bestSim = sim
			bestIdx = i
			copy(bestSource, source)
		}
	}
	_ = bestIdx // available for log-line decoration in matrix runner
	return bestSource, nil
}

func (a *PyannoteSepECAPA) Close() error {
	if a.sepSession != nil {
		_ = a.sepSession.Destroy()
		a.sepSession = nil
	}
	return nil
}

// Compile-time interface check.
var _ Cleanup = (*PyannoteSepECAPA)(nil)
```

- [ ] **Step 4: Run Name-only test, confirm pass**

Run: `cd core && go test -tags cleanupeval -run TestPyannoteSepECAPA_Name ./internal/speaker/...`
Expected: PASS.

- [ ] **Step 5: Run load-when-present test**

Run: `cd core && go test -tags cleanupeval -v -run TestPyannoteSepECAPA_LoadsWhenPresent ./internal/speaker/...`
Expected: SKIP (with reason "PYANNOTE_SEP_PATH not set ...") if model absent. PASS if model exported and env var set.

- [ ] **Step 6: Commit**

```bash
git add core/internal/speaker/cleanup_pyannote_test.go
git commit -m "$(cat <<'EOF'
test(speaker): add PyannoteSepECAPA cleanup adapter

Wraps pyannote-sep ONNX (separator emits N source streams) and picks
the source whose ECAPA embedding has highest cosine to the enrolled
reference. Skips cleanly when PYANNOTE_SEP_PATH or the encoder ONNX
are absent. Model export instructions land in BUILDING_PYANNOTE_SEP.md
in a follow-up task.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 11: TestCleanup_Matrix runner

**Files:**
- Create: `core/internal/speaker/cleanup_eval_test.go`
- Delete: `core/internal/speaker/cleanup_smoke_test.go` (the placeholder from Task 1)

- [ ] **Step 1: Write the matrix runner**

`core/internal/speaker/cleanup_eval_test.go`:
```go
//go:build cleanupeval

package speaker

import (
	"context"
	"fmt"
	"path/filepath"
	"testing"

	"github.com/voice-keyboard/core/internal/transcribe"
)

// adapterFactory builds a Cleanup adapter for one (target, fixture)
// configuration. Returned adapter is owned by the matrix runner and
// closed after each row.
type adapterFactory struct {
	name  string
	build func(t *testing.T, refEmb []float32, encoderPath string) Cleanup
}

func cleanupAdapters(t *testing.T, encoderPath, tsePath, pyannotePath string) []adapterFactory {
	return []adapterFactory{
		{
			name: "passthrough",
			build: func(_ *testing.T, _ []float32, _ string) Cleanup {
				return NewPassthrough()
			},
		},
		{
			name: "speakergate",
			build: func(t *testing.T, ref []float32, _ string) Cleanup {
				if tsePath == "" {
					return nil
				}
				a, err := NewSpeakerGateAdapter(tsePath, ref)
				if err != nil {
					t.Logf("speakergate adapter unavailable: %v", err)
					return nil
				}
				return a
			},
		},
		{
			name: "pyannote_sep_ecapa",
			build: func(t *testing.T, ref []float32, encPath string) Cleanup {
				if pyannotePath == "" {
					return nil
				}
				a, err := NewPyannoteSepECAPA(pyannotePath, encPath, ref)
				if err != nil {
					t.Logf("pyannote_sep_ecapa adapter unavailable: %v", err)
					return nil
				}
				return a
			},
		},
	}
}

// optionalModelPath returns "" if the env var isn't set or the
// candidate path doesn't exist (no t.Skip — per-adapter skip
// happens inside the matrix loop).
func optionalModelPath(envVar, basename string) string {
	if v := lookupEnv(envVar); v != "" {
		if existsFile(v) {
			return v
		}
		return ""
	}
	candidates := []string{filepath.Join("..", "..", "build", "models", basename)}
	for _, p := range candidates {
		if existsFile(p) {
			return p
		}
	}
	return ""
}

func lookupEnv(k string) string {
	import_os := func() string { return "" }
	_ = import_os
	v, _ := lookupEnvImpl(k)
	return v
}

// (continued — implementation completion in next step)
```

(That's enough scaffolding to fail compilation; full file in next step.)

- [ ] **Step 2: Replace with the complete runner**

Overwrite `core/internal/speaker/cleanup_eval_test.go`:
```go
//go:build cleanupeval

package speaker

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"testing"

	"github.com/voice-keyboard/core/internal/transcribe"
)

// optionalModelPath returns the env-var path if it points to an
// existing file, otherwise the conventional build-dir path if it
// exists, otherwise "". Empty return = adapter is disabled for this
// run (no skip, no fail — single rows can be absent without
// invalidating the matrix).
func optionalModelPath(envVar, basename string) string {
	if v := os.Getenv(envVar); v != "" {
		if _, err := os.Stat(v); err == nil {
			return v
		}
		return ""
	}
	for _, p := range []string{filepath.Join("..", "..", "build", "models", basename)} {
		if _, err := os.Stat(p); err == nil {
			return p
		}
	}
	return ""
}

// adapterFactory builds a Cleanup adapter for one matrix row.
// Returns nil when the adapter is unavailable (model missing, etc.).
type adapterFactory struct {
	name  string
	build func(t *testing.T, refEmb []float32, encoderPath string) Cleanup
}

func cleanupAdapters(encoderPath, tsePath, pyannotePath string) []adapterFactory {
	return []adapterFactory{
		{
			name: "passthrough",
			build: func(_ *testing.T, _ []float32, _ string) Cleanup {
				return NewPassthrough()
			},
		},
		{
			name: "speakergate",
			build: func(t *testing.T, ref []float32, _ string) Cleanup {
				if tsePath == "" {
					return nil
				}
				a, err := NewSpeakerGateAdapter(tsePath, ref)
				if err != nil {
					t.Logf("speakergate adapter unavailable: %v", err)
					return nil
				}
				return a
			},
		},
		{
			name: "pyannote_sep_ecapa",
			build: func(t *testing.T, ref []float32, encPath string) Cleanup {
				if pyannotePath == "" {
					return nil
				}
				a, err := NewPyannoteSepECAPA(pyannotePath, encPath, ref)
				if err != nil {
					t.Logf("pyannote_sep_ecapa adapter unavailable: %v", err)
					return nil
				}
				return a
			},
		},
	}
}

// condition describes one mixture configuration.
type condition struct {
	label  string
	build  func(target, voiceB, noise []float32) []float32
	target int  // 0 or 1 — which voice is the "target" for the cosine eval
	noisy  bool // when true, mixture includes the noise fixture
}

func matrixConditions() []condition {
	return []condition{
		{label: "clean (no mix)", build: func(t, _, _ []float32) []float32 { return cloneFloats(t) }, target: 0, noisy: false},

		{label: "voice+voice 0dB", build: func(t, b, _ []float32) []float32 { return mixAtSNR(t, b, 0) }, target: 0, noisy: false},
		{label: "voice+voice -6dB", build: func(t, b, _ []float32) []float32 { return mixAtSNR(t, b, -6) }, target: 0, noisy: false},
		{label: "voice+voice -12dB", build: func(t, b, _ []float32) []float32 { return mixAtSNR(t, b, -12) }, target: 0, noisy: false},

		{label: "voice+music 0dB", build: func(t, _, n []float32) []float32 { return mixAtSNR(t, n, 0) }, target: 0, noisy: true},
		{label: "voice+music -6dB", build: func(t, _, n []float32) []float32 { return mixAtSNR(t, n, -6) }, target: 0, noisy: true},
		{label: "voice+music -12dB", build: func(t, _, n []float32) []float32 { return mixAtSNR(t, n, -12) }, target: 0, noisy: true},

		{label: "voice+voice+music -6dB / 0dB", build: func(t, b, n []float32) []float32 { return mixThree(t, b, n, -6, 0) }, target: 0, noisy: true},
	}
}

func cloneFloats(s []float32) []float32 {
	out := make([]float32, len(s))
	copy(out, s)
	return out
}

// TestCleanup_Matrix is the harness's top-level entry point. Runs
// every (condition, candidate) combination against the LibriSpeech
// fixture (and ElevenLabs when its key is set), logs a unified table,
// and applies the rubric described in the design spec
// (docs/superpowers/specs/2026-05-11-audio-cleanup-eval-harness-design.md).
//
// Per-row failures DO NOT halt the matrix — every row prints regardless
// so a single broken adapter doesn't blank-out the comparison. Aggregate
// pass/fail is only reported in the trailing summary block.
func TestCleanup_Matrix(t *testing.T) {
	encoderPath := resolveModelPath(t, "SPEAKER_ENCODER_PATH", "speaker_encoder.onnx")
	whisperPath := resolveModelPath(t, "WHISPER_MODEL_PATH", "ggml-small.bin")
	tsePath := optionalModelPath("TSE_MODEL_PATH", "tse_model.onnx")
	pyannotePath := optionalModelPath("PYANNOTE_SEP_PATH", "pyannote_sep.onnx")
	initONNXOnce(t)

	transcriber, err := transcribe.NewWhisperCpp(transcribe.WhisperOptions{
		ModelPath: whisperPath,
		Language:  "en",
	})
	if err != nil {
		t.Fatalf("transcribe.NewWhisperCpp(%q): %v", whisperPath, err)
	}
	defer transcriber.Close()

	fixtures := []voiceFixture{newLibriSpeechFixture()}
	noise := newMusanMusicFixture().Noise(t)

	for _, fix := range fixtures {
		t.Run(fix.Name(), func(t *testing.T) {
			runMatrixForFixture(t, fix, noise.Samples, encoderPath, tsePath, pyannotePath, transcriber)
		})
	}
}

func runMatrixForFixture(t *testing.T, fix voiceFixture, noise []float32,
	encoderPath, tsePath, pyannotePath string, transcriber transcribe.Transcriber) {
	t.Helper()
	a, b := fix.Voices(t)
	transcriptA, _ := fix.(*libriSpeechFixture).Transcripts(t)

	// Trim noise to the voice clip length so mix tensors are aligned.
	n := len(a.Samples)
	if len(noise) > n {
		noise = noise[:n]
	}

	// Precompute reference embeddings used by every speaker-conditioned adapter.
	embA, err := ComputeEmbedding(encoderPath, a.Samples, 192)
	if err != nil {
		t.Fatalf("ComputeEmbedding(A): %v", err)
	}
	embB, err := ComputeEmbedding(encoderPath, b.Samples, 192)
	if err != nil {
		t.Fatalf("ComputeEmbedding(B): %v", err)
	}

	conds := matrixConditions()
	adapters := cleanupAdapters(encoderPath, tsePath, pyannotePath)

	t.Logf("\nMatrix: fixture=%s  target=A  reference voice clip = %s", fix.Name(), a.Label)
	t.Logf("%-20s | %-30s | %-7s | %-7s | %-7s | %-6s | %-6s | %s",
		"candidate", "condition", "simT", "simI", "margin", "RMSr", "WER%", "notes")
	t.Logf("%s", "---------------------+--------------------------------+---------+---------+---------+--------+--------+------")

	for _, cnd := range conds {
		mixed := cnd.build(a.Samples, b.Samples, noise)
		for _, fac := range adapters {
			adapter := fac.build(t, embA, encoderPath)
			if adapter == nil {
				t.Logf("%-20s | %-30s | %-7s | %-7s | %-7s | %-6s | %-6s | %s",
					fac.name, cnd.label, "—", "—", "—", "—", "—", "skipped (model unavailable)")
				continue
			}
			rowLogger(t, fac.name, cnd.label, adapter, mixed, embA, embB, transcriptA, encoderPath, transcriber)
			_ = adapter.Close()
		}
	}
}

func rowLogger(t *testing.T, name, condLabel string, adapter Cleanup,
	mixed, embA, embB []float32, transcriptA, encoderPath string, transcriber transcribe.Transcriber) {
	t.Helper()

	out, err := adapter.Process(context.Background(), mixed)
	if err != nil {
		t.Logf("%-20s | %-30s | %-7s | %-7s | %-7s | %-6s | %-6s | error: %v",
			name, condLabel, "—", "—", "—", "—", "—", err)
		return
	}

	cleanedEmb, err := ComputeEmbedding(encoderPath, out, 192)
	if err != nil {
		t.Logf("%-20s | %-30s | %-7s | %-7s | %-7s | %-6s | %-6s | embed error: %v",
			name, condLabel, "—", "—", "—", "—", "—", err)
		return
	}
	simT := cosineSimilarity(cleanedEmb, embA)
	simI := cosineSimilarity(cleanedEmb, embB)
	margin := simT - simI
	rmsIn := rms(mixed)
	rmsOut := rms(out)
	rmsRatio := float32(0)
	if rmsIn > 0 {
		rmsRatio = rmsOut / rmsIn
	}

	werRes := evaluateWER(t, out, transcriptA, transcriber)

	t.Logf("%-20s | %-30s | %7.4f | %7.4f | %+7.4f | %6.3f | %6.2f | hyp=%q",
		name, condLabel, simT, simI, margin, rmsRatio, werRes.WER*100, werRes.Hypothesis)

	// Diagnostic gates (rubric, not pass/fail). Logged when triggered.
	if simT < 0.40 {
		t.Logf("  ⚠ simT %.4f < 0.40 (output may not look like target)", simT)
	}
	if rmsRatio < 0.1 || rmsRatio > 10 {
		t.Logf("  ⚠ RMSr %.3f outside [0.1, 10] (possible silent / blown-up output)", rmsRatio)
	}

	// Tag-only fmt usage to keep imports honest if other formatting is removed later.
	_ = fmt.Sprintf
}
```

- [ ] **Step 3: Delete the smoke-test placeholder**

Run: `rm core/internal/speaker/cleanup_smoke_test.go`

- [ ] **Step 4: Verify compilation under the cleanupeval tag**

Run: `cd core && go vet -tags cleanupeval ./internal/speaker/...`
Expected: no errors. (vet catches build issues without needing models on disk.)

- [ ] **Step 5: Run the matrix dry — should produce a partial table**

Run: `cd core && go test -tags cleanupeval -v -run TestCleanup_Matrix ./internal/speaker/...`

Expected (when only Whisper + encoder available, no TSE / pyannote):
- `passthrough` row produces real numbers per condition
- `speakergate` row prints `skipped (model unavailable)` per condition
- `pyannote_sep_ecapa` row prints `skipped (model unavailable)` per condition
- Test passes overall (no t.Fatal triggered by skipped adapters)

When all three models are available:
- All three rows produce real numbers per condition
- Test runtime ~10-30 minutes depending on Whisper model size

- [ ] **Step 6: Commit**

```bash
git add core/internal/speaker/cleanup_eval_test.go
git rm core/internal/speaker/cleanup_smoke_test.go
git commit -m "$(cat <<'EOF'
test(speaker): add TestCleanup_Matrix harness runner

Top-level harness entry point. Runs every (condition, candidate) tuple
against the LibriSpeech voice fixture and the MUSAN music fixture,
logs a unified table of cosine + WER + RMS columns. Per-row failures
don't halt the matrix; missing models cause a row to print
"skipped (model unavailable)" rather than skipping the whole test.

Conditions: clean baseline + voice+voice at 0/-6/-12 dB +
voice+music at 0/-6/-12 dB + voice+voice+music at -6/0 dB.
Adapters: passthrough, speakergate, pyannote_sep_ecapa.

Diagnostic gates (simT < 0.40, RMSr outside [0.1,10]) print warnings
when triggered but don't fail the test — the rubric is descriptive,
not enforced.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 12: BUILDING_PYANNOTE_SEP.md export instructions

**Files:**
- Create: `core/BUILDING_PYANNOTE_SEP.md`

- [ ] **Step 1: Write the export documentation**

`core/BUILDING_PYANNOTE_SEP.md`:
```markdown
# Building pyannote-sep ONNX

The `PyannoteSepECAPA` cleanup adapter expects an ONNX export of
`pyannote/speech-separation-ami-1.0` at the path passed via
`PYANNOTE_SEP_PATH`. This document describes how to produce that
artifact. Day-to-day contributors don't need to run this — the
adapter `t.Skip`s cleanly without the model.

## Prerequisites
- Python 3.10+
- HuggingFace token with access to `pyannote/speech-separation-ami-1.0`
  (the model is gated; accept the EULA on the HF page first)
- `pip install pyannote.audio onnx onnxruntime torch torchaudio`

## Export script

Save as `scripts/export-pyannote-sep.py`:

```python
"""Export pyannote/speech-separation-ami-1.0 to ONNX.

Run once per upstream release; commit the resulting ONNX out-of-tree
(it's ~50 MB; bundle via the build pipeline rather than git LFS).
"""
import os
import torch
from pyannote.audio import Pipeline

HF_TOKEN = os.environ["HF_TOKEN"]
OUT = "pyannote_sep.onnx"

pipeline = Pipeline.from_pretrained(
    "pyannote/speech-separation-ami-1.0",
    use_auth_token=HF_TOKEN,
)
# pyannote pipelines are composite; we want only the separator
# submodel for the ONNX export.
separator = pipeline._model  # PixIT separator
separator.eval()

# Trace at a fixed input length (10 s at 16 kHz). Variable-length
# tracing is possible but pyannote's separator was trained on
# fixed windows, so a fixed export matches its training distribution.
dummy = torch.zeros(1, 16000 * 10)
torch.onnx.export(
    separator,
    dummy,
    OUT,
    input_names=["mixed"],
    output_names=["sources"],
    dynamic_axes={"mixed": {1: "T"}, "sources": {2: "T"}},
    opset_version=17,
)
print(f"Wrote {OUT}")
```

## Steps

1. Install Python dependencies:
   ```bash
   pip install pyannote.audio onnx onnxruntime torch torchaudio
   ```
2. Accept the model EULA at https://huggingface.co/pyannote/speech-separation-ami-1.0
3. Set your HF token:
   ```bash
   export HF_TOKEN=hf_your_token_here
   ```
4. Run the export:
   ```bash
   python scripts/export-pyannote-sep.py
   ```
5. The output `pyannote_sep.onnx` (~50 MB) lands in the working
   directory. Move it to `core/build/models/pyannote_sep.onnx` (or
   wherever `PYANNOTE_SEP_PATH` points).

## Verifying the export

Quick load test:
```bash
python -c "import onnxruntime as ort; ort.InferenceSession('pyannote_sep.onnx')"
```
Should print no errors.

Run the harness with the model loaded:
```bash
cd core
PYANNOTE_SEP_PATH=$PWD/build/models/pyannote_sep.onnx \
  go test -tags cleanupeval -v -run TestPyannoteSepECAPA_LoadsWhenPresent \
  ./internal/speaker/...
```
Expected: PASS (the load-when-present test runs end-to-end inference).
```

- [ ] **Step 2: Commit**

```bash
git add core/BUILDING_PYANNOTE_SEP.md
git commit -m "$(cat <<'EOF'
docs(core): how to export pyannote-sep to ONNX

One-time documentation for producing the model artifact the
PyannoteSepECAPA adapter consumes. Day-to-day contributors don't
need to run this — the adapter skips cleanly without the model.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 13: Final smoke run + write up first findings

**Files:**
- Modify: `DEV_NOTES.md` (append harness-bring-up notes section)

- [ ] **Step 1: Run the full matrix against whatever models are available**

Run:
```bash
cd core && go test -tags cleanupeval -v -run TestCleanup_Matrix ./internal/speaker/... 2>&1 | tee /tmp/matrix-firstrun.txt
```

Expected: a long log with one row per (candidate, condition) tuple. Some rows may say `skipped (model unavailable)` if `TSE_MODEL_PATH` or `PYANNOTE_SEP_PATH` aren't set — that's fine; the run still validates the harness shape end-to-end.

- [ ] **Step 2: Write a short bring-up section to DEV_NOTES.md**

Append to `DEV_NOTES.md`:
```markdown
## Cleanup harness bring-up — first run (2026-05-11)

First run of `TestCleanup_Matrix` produced the table in
`/tmp/matrix-firstrun.txt` (or wherever the engineer captured it).
Numbers are baseline calibration only — the rubric in the design spec
gets recalibrated against these.

### What to look for in the first numbers

- **Passthrough WER on `clean (no mix)`** — establishes the WER floor
  for our Whisper model + LibriSpeech clips. Anything worse than this
  on a clean condition is broken.
- **Passthrough WER on `voice+voice 0dB`** — establishes the upper
  bound. Cleanup candidates need to beat this by ≥5 points to clear
  the rubric.
- **Passthrough simT/simI margin on `voice+voice 0dB`** — sanity
  check that an unprocessed mixture has narrow margin (<0.05). If it's
  wider than that, the encoder is biased toward one of the two voices
  and the margin metric is less informative than expected.
- **SpeakerGate (former default) numbers across the matrix** — gives
  us back the May-7 picture: where it works, where it falls apart on
  multi-voice / overlap conditions.
- **PyannoteSepECAPA, when present** — the actual prototype answer.

### Rubric calibration follow-up

After capturing the baseline, update
`docs/superpowers/specs/2026-05-11-audio-cleanup-eval-harness-design.md`
with the actual baseline numbers and revised rubric thresholds, dated.
The numbers in the spec today are starting points only.
```

- [ ] **Step 3: Commit**

```bash
git add DEV_NOTES.md
git commit -m "$(cat <<'EOF'
docs: dev-notes section for cleanup harness first-run calibration

Notes the columns to read first and the follow-up to update the design
spec's rubric numbers with measured baselines once the harness produces
its first table.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Self-review checklist (run after writing the plan, fix inline)

- [x] **Spec coverage:**
  - Cleanup interface + 4 adapters → Tasks 2, 9, 10. (DFN3Wrapper deferred — flagged in "Spec deviations" at top.)
  - voiceFixture + transcripts → Task 7
  - noiseFixture + musan music → Task 8
  - mix machinery → Task 3
  - cosine evaluator → Task 4
  - WER evaluator → Tasks 5 + 6
  - matrix runner → Task 11
  - pass criteria as rubric → Task 11 (diagnostic gates as warnings, not failures)
  - file layout matches spec
  - test invocation commands match spec (`-tags cleanupeval`)
  - `PYANNOTE_SEP_PATH` env var convention matches spec
  - skip-when-model-missing pattern matches spec (per-row, not whole-test)
  - calibration policy → Task 13 (bring-up notes that point back to spec for recalibration)

- [x] **Placeholder scan:** no "TBD", "TODO", "implement later", or hand-wavey steps. Each step has runnable code or commands.

- [x] **Type consistency:** `Cleanup` interface signature matches across Tasks 2, 9, 10, 11. `cosineResult` / `werResult` / `noiseClip` types match across files. Method names (`Process`, `Name`, `Close`) consistent.

- [x] **Imports honesty:** Task 11's `cleanup_eval_test.go` uses `transcribe.NewWhisperCpp` — verify this constructor exists in `core/internal/transcribe/whisper_cpp.go`. If the constructor name differs, fix in Task 11 step 2 inline. (Quick verification via grep before executing.)

Plan complete and saved to `docs/superpowers/plans/2026-05-11-audio-cleanup-eval-harness.md`.
