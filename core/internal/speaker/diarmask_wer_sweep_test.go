//go:build cleanupeval && whispercpp

package speaker

import (
	"context"
	"fmt"
	"math"
	"testing"

	"github.com/voice-keyboard/core/internal/transcribe"
)

// TestDiarMask_WERSweep quantifies the OG (TSE) flow vs the diarization
// (diar_mask) flow by WORD ERROR RATE — the metric that actually decides a
// dictation cleanup — across an SNR sweep and multi-voice conditions on
// synthesized speech.
//
// The reference is always the target's known sentence. Each candidate's output
// is transcribed with whisper.cpp (the production ASR) and scored with the
// existing computeWER. diar_mask runs on an ORACLE segmenter (ground-truth
// timeline), so its numbers are an upper bound, not a realistic diarizer.
//
// Honest by construction: diar_mask's selectTarget needs EXCLUSIVE (non-
// overlapping) frames per track, so on FULL-OVERLAP conditions it degenerates
// to passthrough (it cannot separate concurrent speech — only TSE can). The
// sweep includes those conditions so the comparison is not stacked.
//
// Run: go test -tags 'cleanupeval whispercpp' ./internal/speaker/ \
//        -run TestDiarMask_WERSweep -v   (set WHISPER_MODEL_PATH if needed)
func TestDiarMask_WERSweep(t *testing.T) {
	encoderPath := resolveModelPath(t, "SPEAKER_ENCODER_PATH", "speaker_encoder.onnx")
	tsePath := resolveModelPath(t, "TSE_MODEL_PATH", "tse_model.onnx")
	whisperPath := resolveModelPath(t, "WHISPER_MODEL_PATH", "ggml-small.en.bin")
	initONNXOnce(t)

	transcriber, err := transcribe.NewWhisperCpp(transcribe.WhisperOptions{ModelPath: whisperPath, Language: "en"})
	if err != nil {
		t.Fatalf("whisper: %v", err)
	}
	defer transcriber.Close()

	const targetText = "The quick brown fox jumps over the lazy dog."
	tgt := normTo(synthVoice(t, "Daniel", targetText), 0.08)
	i1 := normTo(synthVoice(t, "Samantha", "She sells seashells down by the rolling seashore."), 0.08)
	i2 := normTo(synthVoice(t, "Karen", "Mister wolf, please tell me what is the time today."), 0.08)
	Lt := len(tgt)

	refA, err := ComputeEmbedding(encoderPath, tgt, 192)
	if err != nil {
		t.Fatalf("embed target: %v", err)
	}
	embed := func(s []float32) ([]float32, error) { return ComputeEmbedding(encoderPath, s, 192) }

	// scaleTo returns clip at the RMS implied by an SNR (dB) relative to the
	// 0.08 target level: positive dB = interferer quieter than target.
	scaleTo := func(clip []float32, snrDB float64) []float32 {
		return normTo(clip, float32(0.08*math.Pow(10, -snrDB/20)))
	}

	type cond struct {
		label string
		mixed []float32
		spk   [][][2]int // oracle per-speaker intervals; nil for clean (single speaker)
	}
	conds := []cond{}

	// 1. clean — target only.
	{
		m := make([]float32, Lt)
		addAt(m, tgt, 0)
		conds = append(conds, cond{"clean (target only)", m, [][][2]int{{{0, Lt}}}})
	}
	// 2-4. full overlap, SNR sweep (target+interferer concurrent throughout).
	for _, snr := range []float64{6, 0, -6} {
		m := make([]float32, Lt)
		addAt(m, tgt, 0)
		in := scaleTo(i1, snr)
		if len(in) > Lt {
			in = in[:Lt]
		}
		addAt(m, in, 0)
		conds = append(conds, cond{fmt.Sprintf("overlap v+v %+ddB", int(snr)), m,
			[][][2]int{{{0, Lt}}, {{0, Lt}}}}) // both active everywhere → no exclusive frames
	}
	// 5-6. intermittent: target, then interferer-only tail. SNR on the tail.
	for _, snr := range []float64{0, -6} {
		tail := 2 * synthSR
		in := scaleTo(i1, snr)
		if len(in) > tail {
			in = in[:tail]
		}
		n := Lt + tail
		m := make([]float32, n)
		addAt(m, tgt, 0)
		addAt(m, in, Lt)
		conds = append(conds, cond{fmt.Sprintf("intermittent v+v %+ddB", int(snr)), m,
			[][][2]int{{{0, Lt}}, {{Lt, Lt + tail}}}})
	}
	// 7. multi-voice intermittent: target, then two interferers babbling in the tail.
	{
		tail := 2 * synthSR
		n := Lt + tail
		m := make([]float32, n)
		addAt(m, tgt, 0)
		a := scaleTo(i1, 0)
		if len(a) > tail {
			a = a[:tail]
		}
		b := scaleTo(i2, 0)
		if len(b) > tail {
			b = b[:tail]
		}
		addAt(m, a, Lt)
		addAt(m, b, Lt+synthSR) // i2 offset 1s so i1 has ≥0.5s exclusive frames (selectTarget needs ≥2 tracks)
		conds = append(conds, cond{"intermittent 3-voice 0dB", m,
			[][][2]int{{{0, Lt}}, {{Lt, Lt + tail}}, {{Lt + synthSR, Lt + tail}}}})
	}

	ctx := context.Background()
	werOf := func(out []float32) (float64, string) {
		hyp, err := transcriber.Transcribe(ctx, out)
		if err != nil {
			t.Fatalf("transcribe: %v", err)
		}
		return computeWER(targetText, hyp) * 100, hyp
	}
	// removedPct: how much of the passthrough energy diar_mask zeroed (0 ⇒ it
	// did not mask anything; high ⇒ it dropped non-target regions).
	removedPct := func(diar, pass []float32) float64 {
		var ed, ep float64
		for i := range pass {
			ep += float64(pass[i]) * float64(pass[i])
			if i < len(diar) {
				ed += float64(diar[i]) * float64(diar[i])
			}
		}
		if ep == 0 {
			return 0
		}
		return 100 * (1 - ed/ep)
	}
	trunc := func(s string, n int) string {
		if len(s) > n {
			return s[:n] + "…"
		}
		return s
	}

	t.Logf("WER sweep | target=Daniel %q | whisper=small.en | diar_mask on ORACLE segmenter", targetText)
	t.Logf("%-26s | %-9s | %-9s | %-9s | %-10s", "condition", "passWER", "tseWER", "diarWER", "diar removed")
	t.Logf("%s", "---------------------------+-----------+-----------+-----------+-----------")

	for _, c := range conds {
		pWER, pHyp := werOf(c.mixed)

		tg, err := NewSpeakerGateAdapter(tsePath, refA)
		if err != nil {
			t.Fatalf("tse: %v", err)
		}
		tOut, err := tg.Process(ctx, c.mixed)
		_ = tg.Close()
		if err != nil {
			t.Fatalf("tse process: %v", err)
		}
		tWER, _ := werOf(tOut)

		oracle := &oracleSegmenter{hop: 256, spkIntervals: c.spk}
		dm, err := NewDiarMask(DiarMaskOptions{Segmenter: oracle, Embed: embed, Reference: refA,
			MinSelectCosine: 0.40, MinExclusiveSeconds: 0.5, FallbackPassthrough: true, BoundaryRampMs: 15})
		if err != nil {
			t.Fatalf("diar: %v", err)
		}
		dOut, err := dm.Process(ctx, c.mixed)
		_ = dm.Close()
		if err != nil {
			t.Fatalf("diar process: %v", err)
		}
		dWER, dHyp := werOf(dOut)

		t.Logf("%-26s | %8.1f%% | %8.1f%% | %8.1f%% | %8.1f%%", c.label, pWER, tWER, dWER, removedPct(dOut, c.mixed))
		t.Logf("    passthru heard: %q", trunc(pHyp, 90))
		t.Logf("    diar_mask heard: %q", trunc(dHyp, 90))
	}
	t.Logf("lower WER = better. 'diar removed' = %% of passthrough energy zeroed (0 ⇒ full overlap, diar can't mask).")
}
