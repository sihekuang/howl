//go:build cleanupeval

package speaker

import (
	"context"
	"os"
	"path/filepath"
	"testing"

	"github.com/voice-keyboard/core/internal/audio"
)

// TestDiarMask_SynthRealSegmenter is the real-model counterpart to
// TestDiarMask_SynthEndToEnd. It runs the SAME synthesized Daniel+Samantha
// mixture (known timeline) through diar_mask twice — once with the oracle
// segmenter (ground truth from the timeline) and once with the REAL pyannote
// ONNX segmenter — and reports the retention / interferer-leak / cosine
// metrics side by side.
//
// This closes the verification gap: the oracle test proves the masking/select
// logic given perfect diarization; this proves the WHOLE path (real pyannote
// diarization → cosine SELECT → time MASK) on real speech with the exported
// model. It skips cleanly when pyannote_seg.onnx is absent.
//
// Run:
//   PYANNOTE_SEG_PATH=.../pyannote_seg.onnx \
//   SPEAKER_ENCODER_PATH=.../speaker_encoder.onnx \
//   go test -tags cleanupeval ./internal/speaker/ -run TestDiarMask_SynthRealSegmenter -v
func TestDiarMask_SynthRealSegmenter(t *testing.T) {
	encoderPath := resolveModelPath(t, "SPEAKER_ENCODER_PATH", "speaker_encoder.onnx")
	segPath := resolveModelPath(t, "PYANNOTE_SEG_PATH", "pyannote_seg.onnx") // t.Skip if absent
	initONNXOnce(t)

	const (
		seg   = 2 * synthSR // 2 s segment
		total = 4 * seg     // 8 s: A[0,2) | A+B[2,4) | B[4,6) | A[6,8)
	)

	// Same two distinct voices + texts as the oracle test, for apples-to-apples.
	aFull := synthVoice(t, "Daniel",
		"The quick brown fox jumps over the lazy dog while the morning sun rises slowly "+
			"above the quiet hills and the river winds gently through the green valley below.")
	bFull := synthVoice(t, "Samantha",
		"She sells seashells by the seashore on a bright summer afternoon as the children "+
			"build tall sandcastles and the seagulls circle high above the rolling ocean waves.")
	if len(aFull) < 3*seg || len(bFull) < 2*seg {
		t.Fatalf("synthesized clips too short: A=%d B=%d", len(aFull), len(bFull))
	}
	aFull = normTo(aFull, 0.08)
	bFull = normTo(bFull, 0.08)

	a1, a2, a3 := aFull[0:seg], aFull[seg:2*seg], aFull[2*seg:3*seg]
	b1, b2 := bFull[0:seg], bFull[seg:2*seg]

	mixed := make([]float32, total)
	cleanA := make([]float32, total)
	addAt(mixed, a1, 0)
	addAt(cleanA, a1, 0)
	addAt(mixed, a2, 1*seg) // overlap
	addAt(cleanA, a2, 1*seg)
	addAt(mixed, b1, 1*seg) // overlap
	addAt(mixed, b2, 2*seg) // B-only
	addAt(mixed, a3, 3*seg)
	addAt(cleanA, a3, 3*seg)

	aActive := [][2]int{{0, 2 * seg}, {3 * seg, 4 * seg}}
	aOnly := [][2]int{{0, 1 * seg}, {3 * seg, 4 * seg}}
	bOnly := [][2]int{{2 * seg, 3 * seg}}
	bActive := [][2]int{{1 * seg, 3 * seg}}

	refA, err := ComputeEmbedding(encoderPath, aFull, 192)
	if err != nil {
		t.Fatalf("ComputeEmbedding(A): %v", err)
	}
	refB, err := ComputeEmbedding(encoderPath, bFull, 192)
	if err != nil {
		t.Fatalf("ComputeEmbedding(B): %v", err)
	}

	embed := func(s []float32) ([]float32, error) { return ComputeEmbedding(encoderPath, s, 192) }
	mkDiar := func(sg Segmenter) *DiarMask {
		d, err := NewDiarMask(DiarMaskOptions{
			Segmenter:           sg,
			Embed:               embed,
			Reference:           refA,
			MinSelectCosine:     0.40,
			MinExclusiveSeconds: 0.5,
			FallbackPassthrough: true,
			BoundaryRampMs:      15,
		})
		if err != nil {
			t.Fatalf("NewDiarMask: %v", err)
		}
		return d
	}

	oracle := &oracleSegmenter{hop: 256, spkIntervals: [][][2]int{aActive, bActive}}
	real, err := NewPyannoteSegmenter(segPath)
	if err != nil {
		t.Fatalf("NewPyannoteSegmenter: %v", err)
	}
	defer real.Close()

	ctx := context.Background()
	dOracle := mkDiar(oracle)
	defer dOracle.Close()
	dReal := mkDiar(real)
	defer dReal.Close()

	outOracle, err := dOracle.Process(ctx, mixed)
	if err != nil {
		t.Fatalf("oracle Process: %v", err)
	}
	outReal, err := dReal.Process(ctx, mixed)
	if err != nil {
		t.Fatalf("real pyannote Process: %v", err)
	}

	if dump := os.Getenv("DIAR_SYNTH_DUMP_DIR"); dump != "" {
		_ = os.MkdirAll(dump, 0o755)
		_ = audio.WriteWAVMono(filepath.Join(dump, "mixed.wav"), mixed, synthSR)
		_ = audio.WriteWAVMono(filepath.Join(dump, "diar_oracle.wav"), outOracle, synthSR)
		_ = audio.WriteWAVMono(filepath.Join(dump, "diar_real.wav"), outReal, synthSR)
		t.Logf("dumped mixed/diar_oracle/diar_real WAVs under %s", dump)
	}

	type m struct{ retAOnly, retAActive, leakB, cosA, cosB float64 }
	report := func(name string, out []float32) m {
		r := m{
			retAOnly:   ratioRMS(out, cleanA, aOnly),
			retAActive: ratioRMS(out, cleanA, aActive),
			leakB:      ratioRMS(out, mixed, bOnly),
		}
		if e, err := ComputeEmbedding(encoderPath, out, 192); err == nil {
			r.cosA = float64(cosineSimilarity(refA, e))
			r.cosB = float64(cosineSimilarity(refB, e))
		}
		t.Logf("%-22s | retentionA-only=%.3f  retentionA-active=%.3f  B-only-leak=%.3f  cosA=%.3f  cosB=%.3f",
			name, r.retAOnly, r.retAActive, r.leakB, r.cosA, r.cosB)
		return r
	}

	t.Logf("REAL-segmenter eval | A=Daniel(target) B=Samantha(interferer) | 8s: A[0-2] A+B[2-4] B[4-6] A[6-8]")
	pass := report("passthrough", mixed)
	orc := report("diar_mask(oracle)", outOracle)
	rl := report("diar_mask(REAL pyannote)", outReal)
	t.Logf("oracle last-similarity=%.3f  real last-similarity=%.3f", dOracle.LastSimilarity(), dReal.LastSimilarity())
	_ = orc

	// Core claims for the REAL segmenter. Thresholds are looser than the oracle
	// test's because real diarization boundaries are fuzzier than ground truth —
	// the point is that the WHOLE path still keeps the target and rejects the
	// interferer, not that it matches the oracle exactly.
	if rl.retAActive < 0.85 {
		t.Errorf("real-seg cut the target: retentionA-active=%.3f < 0.85", rl.retAActive)
	}
	if rl.retAOnly < pass.retAOnly-0.10 {
		t.Errorf("real-seg cut the target vs passthrough: real=%.3f passthrough=%.3f", rl.retAOnly, pass.retAOnly)
	}
	if rl.leakB > 0.20 {
		t.Errorf("real-seg leaked the interferer: B-only-leak=%.3f > 0.20", rl.leakB)
	}
	if rl.cosA <= rl.cosB {
		t.Errorf("real-seg output not target-dominant: cosA=%.3f <= cosB=%.3f", rl.cosA, rl.cosB)
	}
}
