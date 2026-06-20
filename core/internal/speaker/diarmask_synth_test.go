//go:build cleanupeval

package speaker

import (
	"context"
	"encoding/binary"
	"math"
	"os"
	"os/exec"
	"path/filepath"
	"testing"

	"github.com/voice-keyboard/core/internal/audio"
)

// Automated synthesized-audio evaluation for diar_mask.
//
// It synthesizes two distinct speakers with the macOS `say` TTS (free,
// deterministic, no API key), builds a multi-speaker mixture with a KNOWN
// activity timeline, and runs the real DiarMask pipeline (real ECAPA encoder
// for cosine selection + real masking) against the real TSE SpeakerGate
// baseline on it.
//
// Because we synthesize the mixture we know exactly who speaks when, so the
// segmenter is an *oracle* derived from that timeline (oracleSegmenter). This
// isolates the diar_mask masking/select/retain logic from diarizer error —
// the "oracle diarization" condition DEV_NOTES references. The real pyannote
// segmenter is a drop-in replacement (same Segmenter interface) once
// pyannote_seg.onnx exists; this test does not need it.
//
// Run:
//   go test -tags cleanupeval ./internal/speaker/ -run TestDiarMask_SynthEndToEnd -v
// Optional: set DIAR_SYNTH_DUMP_DIR=/some/dir to write mixed/diar_mask/tse WAVs.

const synthSR = 16000

// oracleSegmenter returns ground-truth per-frame activity from known
// per-speaker sample intervals (absolute within the single ≤10 s window).
type oracleSegmenter struct {
	spkIntervals [][][2]int // [localSpeaker][]{start,end}
	hop          int
}

func (o *oracleSegmenter) Segment(_ context.Context, window []float32) (SpeakerActivity, error) {
	n := len(window)
	nFrames := (n + o.hop - 1) / o.hop
	frames := make([][]bool, nFrames)
	for f := 0; f < nFrames; f++ {
		center := f*o.hop + o.hop/2
		act := make([]bool, diarMaxSpeakers)
		for spk := 0; spk < len(o.spkIntervals) && spk < diarMaxSpeakers; spk++ {
			for _, iv := range o.spkIntervals[spk] {
				if center >= iv[0] && center < iv[1] {
					act[spk] = true
					break
				}
			}
		}
		frames[f] = act
	}
	return SpeakerActivity{Frames: frames, FrameHopSamples: o.hop}, nil
}

func (o *oracleSegmenter) Close() error { return nil }

// synthVoice renders text in the given macOS `say` voice to 16 kHz mono
// float32 PCM via say + ffmpeg. Skips the test cleanly if the tools are absent.
func synthVoice(t *testing.T, voice, text string) []float32 {
	t.Helper()
	sayBin, err := exec.LookPath("say")
	if err != nil {
		t.Skip("say not available — skipping synthesized-audio eval")
	}
	ffBin, err := exec.LookPath("ffmpeg")
	if err != nil {
		t.Skip("ffmpeg not available — skipping synthesized-audio eval")
	}
	dir := t.TempDir()
	aiff := filepath.Join(dir, "v.aiff")
	if out, err := exec.Command(sayBin, "-v", voice, "-o", aiff, text).CombinedOutput(); err != nil {
		t.Fatalf("say -v %s: %v\n%s", voice, err, out)
	}
	raw := filepath.Join(dir, "v.f32")
	if out, err := exec.Command(ffBin, "-nostdin", "-loglevel", "error",
		"-i", aiff, "-ar", "16000", "-ac", "1", "-f", "f32le", raw).CombinedOutput(); err != nil {
		t.Fatalf("ffmpeg decode (%s): %v\n%s", voice, err, out)
	}
	b, err := os.ReadFile(raw)
	if err != nil {
		t.Fatalf("read pcm: %v", err)
	}
	n := len(b) / 4
	s := make([]float32, n)
	for i := 0; i < n; i++ {
		s[i] = math.Float32frombits(binary.LittleEndian.Uint32(b[4*i : 4*i+4]))
	}
	return s
}

// normTo scales s to the target RMS so mixing levels are controlled.
func normTo(s []float32, target float32) []float32 {
	r := rms(s)
	out := make([]float32, len(s))
	if r == 0 {
		return out
	}
	g := target / r
	for i, v := range s {
		out[i] = v * g
	}
	return out
}

// addAt sums clip into dst starting at sample offset off.
func addAt(dst, clip []float32, off int) {
	for i, v := range clip {
		j := off + i
		if j >= 0 && j < len(dst) {
			dst[j] += v
		}
	}
}

// energyOver returns the summed squared energy of sig over the given regions.
func energyOver(sig []float32, regions [][2]int) float64 {
	var e float64
	for _, r := range regions {
		for i := r[0]; i < r[1] && i < len(sig); i++ {
			e += float64(sig[i]) * float64(sig[i])
		}
	}
	return e
}

// ratioRMS returns sqrt(energyOver(num)/energyOver(den)) over regions — an
// amplitude ratio in [0, ~). 1.0 means num carries the same energy as den
// over those regions; 0 means num is silent there.
func ratioRMS(num, den []float32, regions [][2]int) float64 {
	d := energyOver(den, regions)
	if d == 0 {
		return 0
	}
	return math.Sqrt(energyOver(num, regions) / d)
}

// TestDiarMask_SynthEndToEnd is the automated synthesized-audio pipeline.
// It proves the core diar_mask claim on real speech: the enrolled target's
// own audio is preserved (high retention) while the interferer-only region is
// removed (low leakage) — compared head-to-head with the TSE baseline.
func TestDiarMask_SynthEndToEnd(t *testing.T) {
	encoderPath := resolveModelPath(t, "SPEAKER_ENCODER_PATH", "speaker_encoder.onnx")
	tsePath := resolveModelPath(t, "TSE_MODEL_PATH", "tse_model.onnx")
	initONNXOnce(t)

	const (
		seg = 2 * synthSR // 2 s segment
		// timeline (8 s total): A[0,2) | A+B[2,4) | B[4,6) | A[6,8)
		total = 4 * seg
	)

	// Synthesize two distinct voices (different gender + accent → well separated).
	aFull := synthVoice(t, "Daniel",
		"The quick brown fox jumps over the lazy dog while the morning sun rises slowly "+
			"above the quiet hills and the river winds gently through the green valley below.")
	bFull := synthVoice(t, "Samantha",
		"She sells seashells by the seashore on a bright summer afternoon as the children "+
			"build tall sandcastles and the seagulls circle high above the rolling ocean waves.")

	if len(aFull) < 3*seg || len(bFull) < 2*seg {
		t.Fatalf("synthesized clips too short: A=%d B=%d (need A>=%d B>=%d)",
			len(aFull), len(bFull), 3*seg, 2*seg)
	}

	// Equal-level normalization (≈0 dB in the overlap region).
	aFull = normTo(aFull, 0.08)
	bFull = normTo(bFull, 0.08)

	a1, a2, a3 := aFull[0:seg], aFull[seg:2*seg], aFull[2*seg:3*seg]
	b1, b2 := bFull[0:seg], bFull[seg:2*seg]

	// Mixture and the clean-target reference (A placed where A is active).
	mixed := make([]float32, total)
	cleanA := make([]float32, total)
	addAt(mixed, a1, 0)
	addAt(cleanA, a1, 0)
	addAt(mixed, a2, 1*seg) // overlap region
	addAt(cleanA, a2, 1*seg)
	addAt(mixed, b1, 1*seg) // overlap region
	addAt(mixed, b2, 2*seg) // B-only region
	addAt(mixed, a3, 3*seg)
	addAt(cleanA, a3, 3*seg)

	// Region maps (sample intervals).
	aActive := [][2]int{{0, 2 * seg}, {3 * seg, 4 * seg}}
	aOnly := [][2]int{{0, 1 * seg}, {3 * seg, 4 * seg}}
	bOnly := [][2]int{{2 * seg, 3 * seg}}
	bActive := [][2]int{{1 * seg, 3 * seg}}

	// Enrollment: ECAPA embedding of A's clean speech; B's for interferer cosine.
	refA, err := ComputeEmbedding(encoderPath, aFull, 192)
	if err != nil {
		t.Fatalf("ComputeEmbedding(A): %v", err)
	}
	refB, err := ComputeEmbedding(encoderPath, bFull, 192)
	if err != nil {
		t.Fatalf("ComputeEmbedding(B): %v", err)
	}

	// Oracle segmenter from the known timeline.
	oracle := &oracleSegmenter{
		hop: 256,
		spkIntervals: [][][2]int{
			aActive, // local speaker 0 = A
			bActive, // local speaker 1 = B
		},
	}

	// diar_mask under test.
	diar, err := NewDiarMask(DiarMaskOptions{
		Segmenter:           oracle,
		Embed:               func(s []float32) ([]float32, error) { return ComputeEmbedding(encoderPath, s, 192) },
		Reference:           refA,
		MinSelectCosine:     0.40,
		MinExclusiveSeconds: 0.5,
		FallbackPassthrough: true,
		BoundaryRampMs:      15,
	})
	if err != nil {
		t.Fatalf("NewDiarMask: %v", err)
	}
	defer diar.Close()

	// TSE baseline (no gate — pure extraction).
	tse, err := NewSpeakerGateAdapter(tsePath, refA)
	if err != nil {
		t.Fatalf("NewSpeakerGateAdapter: %v", err)
	}
	defer tse.Close()

	ctx := context.Background()
	outDiar, err := diar.Process(ctx, mixed)
	if err != nil {
		t.Fatalf("diar_mask Process: %v", err)
	}
	outTSE, err := tse.Process(ctx, mixed)
	if err != nil {
		t.Fatalf("tse Process: %v", err)
	}

	// Optional WAV dump for listening.
	if dump := os.Getenv("DIAR_SYNTH_DUMP_DIR"); dump != "" {
		_ = os.MkdirAll(dump, 0o755)
		_ = audio.WriteWAVMono(filepath.Join(dump, "mixed.wav"), mixed, synthSR)
		_ = audio.WriteWAVMono(filepath.Join(dump, "cleanA.wav"), cleanA, synthSR)
		_ = audio.WriteWAVMono(filepath.Join(dump, "diar_mask.wav"), outDiar, synthSR)
		_ = audio.WriteWAVMono(filepath.Join(dump, "tse.wav"), outTSE, synthSR)
		t.Logf("dumped mixed/cleanA/diar_mask/tse WAVs under %s", dump)
	}

	// Metrics for one candidate output.
	type synthMetrics struct{ retAOnly, retAActive, leakB, cosA, cosB float64 }
	report := func(name string, out []float32) synthMetrics {
		m := synthMetrics{
			retAOnly:   ratioRMS(out, cleanA, aOnly),
			retAActive: ratioRMS(out, cleanA, aActive),
			leakB:      ratioRMS(out, mixed, bOnly),
		}
		if embOut, e := ComputeEmbedding(encoderPath, out, 192); e == nil {
			m.cosA = float64(cosineSimilarity(refA, embOut))
			m.cosB = float64(cosineSimilarity(refB, embOut))
		}
		t.Logf("%-12s | retentionA-only=%.3f  retentionA-active=%.3f  B-only-leak=%.3f  cosA=%.3f  cosB=%.3f",
			name, m.retAOnly, m.retAActive, m.leakB, m.cosA, m.cosB)
		return m
	}

	t.Logf("synth eval | A=Daniel(target) B=Samantha(interferer) | 8s: A[0-2] A+B[2-4] B[4-6] A[6-8] | equal level")
	t.Logf("%-12s | %s", "candidate", "metrics (1.0 retention = target kept; 0 leak = interferer removed)")
	passM := report("passthrough", mixed)
	_ = report("tse", outTSE) // baseline, logged for comparison
	diarM := report("diar_mask", outDiar)

	// Core claims for diar_mask, asserted against absolute thresholds and the
	// passthrough reference (NOT TSE — TSE reconstructs so its energy ratio can
	// exceed 1.0, which is distortion, not better preservation):
	//
	// 1. Preserves the target's OWN audio in solo (A-only) regions.
	if diarM.retAOnly < 0.90 {
		t.Errorf("diar_mask cut the target: retentionA-only=%.3f < 0.90", diarM.retAOnly)
	}
	// 2. Does not cut the target relative to doing nothing (passthrough) — the
	//    "stops cutting my voice" claim.
	if diarM.retAOnly < passM.retAOnly-0.05 {
		t.Errorf("diar_mask cut the target vs passthrough: diar=%.3f passthrough=%.3f",
			diarM.retAOnly, passM.retAOnly)
	}
	// 3. Removes the interferer-only region.
	if diarM.leakB > 0.05 {
		t.Errorf("diar_mask leaked the interferer: B-only-leak=%.3f > 0.05", diarM.leakB)
	}
	// 4. Interferer rejection: output is pulled away from B vs the raw mix, and
	//    looks more like the target than the interferer.
	if diarM.cosB >= passM.cosB {
		t.Errorf("diar_mask did not reduce interferer similarity: cosB=%.3f >= passthrough cosB=%.3f",
			diarM.cosB, passM.cosB)
	}
	if diarM.cosA <= diarM.cosB {
		t.Errorf("diar_mask output not target-dominant: cosA=%.3f <= cosB=%.3f", diarM.cosA, diarM.cosB)
	}
}
