//go:build speakerbeam

package speaker

import (
	"math"
	"os"
	"testing"
)

func TestComputeEmbedding_NormalisedAndDeterministic(t *testing.T) {
	libPath := os.Getenv("ONNXRUNTIME_LIB_PATH")
	if libPath == "" {
		libPath = "/opt/homebrew/lib/libonnxruntime.dylib"
	}
	if err := InitONNXRuntime(libPath); err != nil {
		t.Fatalf("InitONNXRuntime: %v", err)
	}
	modelPath := os.Getenv("SPEAKER_ENCODER_PATH")
	if modelPath == "" {
		t.Skip("SPEAKER_ENCODER_PATH not set")
	}

	// 1 s of 440 Hz tone at 16 kHz
	samples := make([]float32, 16000)
	for i := range samples {
		samples[i] = 0.3 * float32(math.Sin(2*math.Pi*440*float64(i)/16000))
	}

	emb1, err := ComputeEmbedding(modelPath, samples, Default.EmbeddingDim)
	if err != nil {
		t.Fatalf("ComputeEmbedding (1st): %v", err)
	}
	if len(emb1) != Default.EmbeddingDim {
		t.Fatalf("len(emb) = %d, want %d", len(emb1), Default.EmbeddingDim)
	}

	// L2 norm should be ~1
	var norm float64
	for _, v := range emb1 {
		norm += float64(v) * float64(v)
	}
	norm = math.Sqrt(norm)
	if math.Abs(norm-1.0) > 0.01 {
		t.Errorf("‖emb‖ = %f, want ≈1.0", norm)
	}

	// Determinism: same input → same output
	emb2, err := ComputeEmbedding(modelPath, samples, Default.EmbeddingDim)
	if err != nil {
		t.Fatalf("ComputeEmbedding (2nd): %v", err)
	}
	for i := range emb1 {
		if emb1[i] != emb2[i] {
			t.Fatalf("nondeterministic output at index %d: %f vs %f", i, emb1[i], emb2[i])
		}
	}
}

func TestComputeEmbedding_DifferentInputsDifferentEmbeds(t *testing.T) {
	libPath := os.Getenv("ONNXRUNTIME_LIB_PATH")
	if libPath == "" {
		libPath = "/opt/homebrew/lib/libonnxruntime.dylib"
	}
	if err := InitONNXRuntime(libPath); err != nil {
		t.Fatalf("InitONNXRuntime: %v", err)
	}
	modelPath := os.Getenv("SPEAKER_ENCODER_PATH")
	if modelPath == "" {
		t.Skip("SPEAKER_ENCODER_PATH not set")
	}

	tone := make([]float32, 16000)
	noise := make([]float32, 16000)
	for i := range tone {
		tone[i] = 0.3 * float32(math.Sin(2*math.Pi*440*float64(i)/16000))
		noise[i] = float32((float64(i*1103515245+12345)/2147483647.0)*2 - 1) * 0.3
	}

	a, err := ComputeEmbedding(modelPath, tone, Default.EmbeddingDim)
	if err != nil {
		t.Fatalf("ComputeEmbedding(tone): %v", err)
	}
	b, err := ComputeEmbedding(modelPath, noise, Default.EmbeddingDim)
	if err != nil {
		t.Fatalf("ComputeEmbedding(noise): %v", err)
	}

	// Cosine similarity (both embeddings are unit-length, so just dot product).
	var cos float64
	for i := range a {
		cos += float64(a[i]) * float64(b[i])
	}
	if math.Abs(cos) > 0.95 {
		t.Errorf("cosine(tone,noise) = %f; expected meaningful divergence (<0.95)", cos)
	}
}
