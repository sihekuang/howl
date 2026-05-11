//go:build speakerbeam

package speaker

import (
	"context"
	"testing"
)

// TestTSE_NoiseRobustness_MultiVoice tests against multi-voice "TV-
// like" noise. ConvTasNet only separates into 2 channels, so a 3+
// source input forces the model to fit multiple voices into one
// channel — the failure mode users actually report ("TSE doesn't
// work against background TV"). Same SNR sweep, but the noise track
// is libri_1462 + a time-reversed copy of itself summed = effectively
// 2 voices in the noise.
func TestTSE_NoiseRobustness_MultiVoice(t *testing.T) {
	tseModel := resolveModelPath(t, "TSE_MODEL_PATH", "tse_model.onnx")
	encoderModel := resolveModelPath(t, "SPEAKER_ENCODER_PATH", "speaker_encoder.onnx")
	initONNXOnce(t)

	a, b := newLibriSpeechFixture().Voices(t)
	n := len(a.Samples)
	if len(b.Samples) < n {
		n = len(b.Samples)
	}
	target := a.Samples[:n]

	// "TV noise" = libri_1462 + time-reversed libri_1462. Two voices
	// that sound distinctly different to the encoder, simulating two
	// people talking on a TV.
	noise := make([]float32, n)
	for i := range noise {
		noise[i] = b.Samples[i] + b.Samples[n-1-i]
	}
	// Renormalise so noise has comparable energy to a single voice.
	noiseRMS := rms(noise)
	if noiseRMS > 0 {
		for i := range noise {
			noise[i] *= 0.05 / noiseRMS
		}
	}

	const ecapaDim = 192
	embedTarget, err := ComputeEmbedding(encoderModel, target, ecapaDim)
	if err != nil {
		t.Fatalf("ComputeEmbedding(target): %v", err)
	}
	embedClean := embedTarget

	t.Logf("\nMulti-voice noise (2 stacked voices)")
	t.Logf("%-8s | %-9s | %-9s | %-7s | %-7s", "SNR(dB)", "simTarget", "simInter", "RMSIn", "RMSOut")
	t.Logf("%s", "---------+-----------+-----------+---------+---------")

	for _, snrDB := range []float64{12, 6, 0, -6, -12, -18} {
		mixed := mixAtSNR(target, noise, snrDB)

		tse, err := NewSpeakerGate(SpeakerGateOptions{ModelPath: tseModel, Reference: embedTarget})
		if err != nil {
			t.Fatalf("NewSpeakerGate: %v", err)
		}
		extracted, err := tse.Extract(context.Background(), mixed)
		_ = tse.Close()
		if err != nil {
			t.Fatalf("Extract: %v", err)
		}
		embedExtracted, err := ComputeEmbedding(encoderModel, extracted, ecapaDim)
		if err != nil {
			t.Fatalf("ComputeEmbedding(extracted): %v", err)
		}
		embedNoise, _ := ComputeEmbedding(encoderModel, noise, ecapaDim)

		simTarget := cosineSimilarity(embedExtracted, embedClean)
		simNoise := cosineSimilarity(embedExtracted, embedNoise)

		t.Logf("%-+8.0f | %-9.4f | %-9.4f | %-7.4f | %-7.4f",
			snrDB, simTarget, simNoise, rms(mixed), rms(extracted))
	}
}

// TestTSE_NoiseRobustness_SNRSweep is a DIAGNOSTIC measurement, not a
// pass/fail regression guard. Sweeps target-vs-interferer SNR from
// +12 dB (target much louder) to -18 dB (target much quieter) and
// logs SimTarget / SimInterferer / RMS at each step so we can see at
// what SNR TSE selection breaks.
//
// User observation we're trying to characterise: TSE doesn't work
// well against background TV noise. TV is multi-voice + variable
// spectral content, but as a first cut we use libri_1462 as a
// stand-in for "a louder competing voice" and find the SNR threshold.
//
// Always passes (no assertions); just logs.
func TestTSE_NoiseRobustness_SNRSweep(t *testing.T) {
	tseModel := resolveModelPath(t, "TSE_MODEL_PATH", "tse_model.onnx")
	encoderModel := resolveModelPath(t, "SPEAKER_ENCODER_PATH", "speaker_encoder.onnx")
	initONNXOnce(t)

	a, b := newLibriSpeechFixture().Voices(t)
	n := len(a.Samples)
	if len(b.Samples) < n {
		n = len(b.Samples)
	}
	target := a.Samples[:n]
	interferer := b.Samples[:n]

	const ecapaDim = 192
	embedTarget, err := ComputeEmbedding(encoderModel, target, ecapaDim)
	if err != nil {
		t.Fatalf("ComputeEmbedding(target): %v", err)
	}
	embedClean, _ := ComputeEmbedding(encoderModel, target, ecapaDim) // for measuring

	t.Logf("\n%-8s | %-9s | %-9s | %-7s | %-7s", "SNR(dB)", "simTarget", "simInter", "RMSIn", "RMSOut")
	t.Logf("%s", "---------+-----------+-----------+---------+---------")

	for _, snrDB := range []float64{12, 6, 0, -6, -12, -18} {
		// scale interferer relative to target so target_rms / interferer_rms ≈ 10^(snr/20).
		// equivalently, multiply interferer by 10^(-snr/20).
		mixed := mixAtSNR(target, interferer, snrDB)

		tse, err := NewSpeakerGate(SpeakerGateOptions{ModelPath: tseModel, Reference: embedTarget})
		if err != nil {
			t.Fatalf("NewSpeakerGate: %v", err)
		}
		extracted, err := tse.Extract(context.Background(), mixed)
		_ = tse.Close()
		if err != nil {
			t.Fatalf("Extract: %v", err)
		}

		embedExtracted, err := ComputeEmbedding(encoderModel, extracted, ecapaDim)
		if err != nil {
			t.Fatalf("ComputeEmbedding(extracted): %v", err)
		}

		simTarget := cosineSimilarity(embedExtracted, embedClean)
		simInter, _ := ComputeEmbedding(encoderModel, interferer, ecapaDim)
		simInterferer := cosineSimilarity(embedExtracted, simInter)

		t.Logf("%-+8.0f | %-9.4f | %-9.4f | %-7.4f | %-7.4f",
			snrDB, simTarget, simInterferer, rms(mixed), rms(extracted))
	}
}
