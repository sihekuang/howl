//go:build cleanupeval && whispercpp

package speaker

import (
	"context"
	"fmt"
	"math"
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

func cleanupAdapters(encoderPath, tsePath, pyannotePath, pyannoteSegPath string) []adapterFactory {
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
		{
			name: "diar_mask",
			build: func(t *testing.T, ref []float32, encPath string) Cleanup {
				if pyannoteSegPath == "" {
					return nil
				}
				seg, err := NewPyannoteSegmenter(pyannoteSegPath)
				if err != nil {
					t.Logf("diar_mask segmenter unavailable: %v", err)
					return nil
				}
				d, err := NewDiarMask(DiarMaskOptions{
					Segmenter: seg,
					Embed: func(s []float32) ([]float32, error) {
						return ComputeEmbedding(encPath, s, 192)
					},
					Reference:           ref,
					MinSelectCosine:     0.40,
					MinExclusiveSeconds: 0.75,
					FallbackPassthrough: true,
					BoundaryRampMs:      15,
				})
				if err != nil {
					t.Logf("diar_mask unavailable: %v", err)
					_ = seg.Close()
					return nil
				}
				return d
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
	pyannoteSegPath := optionalModelPath("PYANNOTE_SEG_PATH", "pyannote_seg.onnx")
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
			runMatrixForFixture(t, fix, noise.Samples, encoderPath, tsePath, pyannotePath, pyannoteSegPath, transcriber)
		})
	}
}

func runMatrixForFixture(t *testing.T, fix voiceFixture, noise []float32,
	encoderPath, tsePath, pyannotePath, pyannoteSegPath string, transcriber transcribe.Transcriber) {
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
	adapters := cleanupAdapters(encoderPath, tsePath, pyannotePath, pyannoteSegPath)

	t.Logf("\nMatrix: fixture=%s  target=A  reference voice clip = %s", fix.Name(), a.Label)
	t.Logf("%-20s | %-30s | %-7s | %-7s | %-7s | %-6s | %-6s | %-6s | %s",
		"candidate", "condition", "simT", "simI", "margin", "RMSr", "reten", "WER%", "notes")
	t.Logf("%s", "---------------------+--------------------------------+---------+---------+---------+--------+--------+--------+------")

	for _, cnd := range conds {
		mixed := cnd.build(a.Samples, b.Samples, noise)
		for _, fac := range adapters {
			adapter := fac.build(t, embA, encoderPath)
			if adapter == nil {
				t.Logf("%-20s | %-30s | %-7s | %-7s | %-7s | %-6s | %-6s | %-6s | %s",
					fac.name, cnd.label, "—", "—", "—", "—", "—", "—", "skipped (model unavailable)")
				continue
			}
			rowLogger(t, fac.name, cnd.label, adapter, mixed, a.Samples, embA, embB, transcriptA, encoderPath, transcriber)
			_ = adapter.Close()
		}
	}
}

func rowLogger(t *testing.T, name, condLabel string, adapter Cleanup,
	mixed, cleanTarget, embA, embB []float32, transcriptA, encoderPath string, transcriber transcribe.Transcriber) {
	t.Helper()

	out, err := adapter.Process(context.Background(), mixed)
	if err != nil {
		t.Logf("%-20s | %-30s | %-7s | %-7s | %-7s | %-6s | %-6s | %-6s | error: %v",
			name, condLabel, "—", "—", "—", "—", "—", "—", err)
		return
	}

	cleanedEmb, err := ComputeEmbedding(encoderPath, out, 192)
	if err != nil {
		t.Logf("%-20s | %-30s | %-7s | %-7s | %-7s | %-6s | %-6s | %-6s | embed error: %v",
			name, condLabel, "—", "—", "—", "—", "—", "—", err)
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
	retention := evaluateRetention(out, cleanTarget)

	werRes := evaluateWER(t, out, transcriptA, transcriber)

	t.Logf("%-20s | %-30s | %7.4f | %7.4f | %+7.4f | %6.3f | %6.3f | %6.2f | hyp=%q",
		name, condLabel, simT, simI, margin, rmsRatio, retention, werRes.WER*100, werRes.Hypothesis)

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

// evaluateRetention measures how much of the clean target's own speech energy
// survives in out. 1.0 = nothing of the target was cut; 0.0 = target silenced.
// Only frames where the clean target is voiced count, so interferer-only
// regions don't dilute the score.
func evaluateRetention(out, cleanTarget []float32) float32 {
	n := len(out)
	if len(cleanTarget) < n {
		n = len(cleanTarget)
	}
	if n == 0 {
		return 0
	}
	// Voiced threshold: 10% of the clean target's global RMS.
	thr := rms(cleanTarget[:n]) * 0.1
	var num, den float64
	const frame = 320 // 20 ms @ 16 kHz
	for start := 0; start < n; start += frame {
		end := start + frame
		if end > n {
			end = n
		}
		seg := cleanTarget[start:end]
		if rms(seg) < thr {
			continue // unvoiced target frame — skip
		}
		for i := start; i < end; i++ {
			den += float64(cleanTarget[i]) * float64(cleanTarget[i])
			num += float64(out[i]) * float64(out[i])
		}
	}
	if den == 0 {
		return 0
	}
	r := num / den
	if r < 0 {
		r = 0
	}
	return float32(math.Sqrt(r))
}

func TestEvaluateRetention_FullKeepIsOne(t *testing.T) {
	target := []float32{0, 0.5, 0, 0.7, 0, 0.3}
	// out == cleanTarget over its voiced samples → retention ~1.0
	got := evaluateRetention(target, target)
	if got < 0.99 || got > 1.01 {
		t.Errorf("retention=%f want ~1.0", got)
	}
}

func TestEvaluateRetention_SilencedTargetIsZero(t *testing.T) {
	target := []float32{0, 0.5, 0, 0.7, 0, 0.3}
	out := make([]float32, len(target)) // everything cut
	got := evaluateRetention(out, target)
	if got > 0.01 {
		t.Errorf("retention=%f want ~0.0", got)
	}
}

func TestEvaluateRetention_PartialKeepIsBetween(t *testing.T) {
	// Build a clearly-voiced target: 16 frames of 320 samples each, all above threshold.
	const frameSize = 320
	const nFrames = 16
	target := make([]float32, frameSize*nFrames)
	for i := range target {
		// Alternating +/-0.5 to ensure rms is well above the 10% threshold.
		if i%2 == 0 {
			target[i] = 0.5
		} else {
			target[i] = -0.5
		}
	}

	// out preserves the first half of frames and zeros the second half.
	out := make([]float32, len(target))
	copy(out[:frameSize*(nFrames/2)], target[:frameSize*(nFrames/2)])
	// second half stays zero

	got := evaluateRetention(out, target)
	// Retention = sqrt(kept_energy / total_energy).
	// Half the frames kept → kept_energy / total_energy = 0.5 → retention = ~0.707.
	// We assert a robust range: strictly between 0.3 and 0.95.
	if got <= 0.3 || got >= 0.95 {
		t.Errorf("partial retention=%f; want strictly between 0.3 and 0.95", got)
	}
}
