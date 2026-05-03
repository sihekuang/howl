package speaker

import (
	"context"
	"fmt"
	"log"
	"math"

	"github.com/voice-keyboard/core/internal/audio"
	ort "github.com/yalue/onnxruntime_go"
)

// SpeakerGate implements TSEExtractor using the combined tse_model.onnx.
//
// The model separates mixed audio into 2 sources (ConvTasNet Libri2Mix
// sep_noisy 16k), embeds each source with the Wespeaker ECAPA-TDNN-512
// encoder (Kaldi Fbank front-end + L2-norm baked into the same ONNX), and
// hard-selects the source whose embedding has the higher cosine similarity
// to the enrolled speaker embedding. It returns actual extracted audio,
// not a gated/zeroed copy.
//
// Inputs:  mixed         float32[1, T]   — 16 kHz mono audio
// Output:  extracted     float32[1, T]   — separated audio for enrolled speaker
//
// Optional similarity gate: when Threshold > 0 AND an EncoderPath is
// loaded, the extracted output is re-embedded post-extract; if the
// cosine similarity to the enrolled reference falls below Threshold,
// the chunk is silenced (zeros) — useful for resisting hallucinations
// in noisy rooms when the enrolled speaker isn't actually talking.
type SpeakerGate struct {
	session *ort.DynamicAdvancedSession
	ref     []float32 // L2-normalised enrollment embedding, captured at construction

	// threshold — when > 0 AND encoder is loaded, the post-Extract
	// cosine similarity gate fires. Below the threshold, Extract
	// returns zeros same length as input. 0 disables gating entirely.
	threshold float32

	// encoderSession — speaker encoder ONNX session, loaded at
	// construction if EncoderPath is provided. Used to re-embed the
	// extracted output for similarity computation. nil disables the
	// post-extract similarity gate even if threshold > 0.
	encoderSession *ort.DynamicAdvancedSession
	encoderDim     int

	// lastSimilarity — most recent cosine similarity computed in
	// Extract, exposed via LastSimilarity() for event emission.
	// 1.0 means the gate didn't run (encoder absent or threshold == 0).
	lastSimilarity float32
}

// SpeakerGateOptions configures NewSpeakerGate.
type SpeakerGateOptions struct {
	// ModelPath is the combined TSE ONNX (required).
	ModelPath string
	// Reference is the L2-normalised enrolled speaker embedding (required).
	Reference []float32
	// Threshold gates extracted output to zeros when post-extract cosine
	// similarity falls below this value. 0 disables gating.
	Threshold float32
	// EncoderPath is the speaker encoder ONNX, used to re-embed the
	// extracted audio for similarity computation. Empty disables the gate.
	EncoderPath string
	// EncoderDim is the encoder's output dimensionality (e.g. 192 for ECAPA).
	// Required if EncoderPath is set.
	EncoderDim int
}

// NewSpeakerGate loads the TSE model and binds the enrollment reference.
// Call InitONNXRuntime before this. opts.Reference must be non-empty.
//
// If opts.EncoderPath is set, also loads the speaker encoder ONNX so
// post-extract similarity gating works (gated by opts.Threshold > 0).
func NewSpeakerGate(opts SpeakerGateOptions) (*SpeakerGate, error) {
	if len(opts.Reference) == 0 {
		return nil, fmt.Errorf("speakergate: empty reference embedding")
	}
	captured := make([]float32, len(opts.Reference))
	copy(captured, opts.Reference)
	session, err := ort.NewDynamicAdvancedSession(
		opts.ModelPath,
		[]string{"mixed", "ref_embedding"},
		[]string{"extracted"},
		nil,
	)
	if err != nil {
		return nil, fmt.Errorf("speakergate: load %q: %w", opts.ModelPath, err)
	}
	g := &SpeakerGate{
		session:        session,
		ref:            captured,
		threshold:      opts.Threshold,
		encoderDim:     opts.EncoderDim,
		lastSimilarity: 1.0,
	}
	if opts.EncoderPath != "" {
		encSess, err := ort.NewDynamicAdvancedSession(
			opts.EncoderPath,
			[]string{"audio"},
			[]string{"embedding"},
			nil,
		)
		if err != nil {
			_ = session.Destroy()
			return nil, fmt.Errorf("speakergate: load encoder %q: %w", opts.EncoderPath, err)
		}
		g.encoderSession = encSess
	}
	return g, nil
}

func (g *SpeakerGate) Name() string    { return "tse" }
func (g *SpeakerGate) OutputRate() int { return 0 } // preserves 16 kHz input

// Process satisfies audio.Stage. Equivalent to Extract.
func (g *SpeakerGate) Process(ctx context.Context, mixed []float32) ([]float32, error) {
	return g.Extract(ctx, mixed)
}

// LastSimilarity returns the most recent cosine similarity computed by
// Extract. Returns 1.0 if the gate didn't run (no encoder configured
// or threshold is 0).
func (g *SpeakerGate) LastSimilarity() float32 {
	if g == nil {
		return 0
	}
	return g.lastSimilarity
}

// Extract runs speaker extraction inference using the bound reference.
//   - mixed: 16 kHz mono PCM chunk.
//
// If a similarity gate is configured (threshold > 0 AND encoder loaded),
// the extracted output is re-embedded; if cosine similarity to the
// reference falls below threshold, the chunk is silenced.
func (g *SpeakerGate) Extract(_ context.Context, mixed []float32) ([]float32, error) {
	mixedT, err := ort.NewTensor(ort.NewShape(1, int64(len(mixed))), mixed)
	if err != nil {
		return nil, fmt.Errorf("speakergate: mixed tensor: %w", err)
	}
	defer mixedT.Destroy()

	refT, err := ort.NewTensor(ort.NewShape(1, int64(len(g.ref))), g.ref)
	if err != nil {
		return nil, fmt.Errorf("speakergate: ref tensor: %w", err)
	}
	defer refT.Destroy()

	outT, err := ort.NewEmptyTensor[float32](ort.NewShape(1, int64(len(mixed))))
	if err != nil {
		return nil, fmt.Errorf("speakergate: output tensor: %w", err)
	}
	defer outT.Destroy()

	if err := g.session.Run([]ort.Value{mixedT, refT}, []ort.Value{outT}); err != nil {
		return nil, fmt.Errorf("speakergate: inference: %w", err)
	}

	out := make([]float32, len(mixed))
	copy(out, outT.GetData())

	// Threshold gate — only runs when configured + encoder loaded.
	if g.threshold > 0 && g.encoderSession != nil {
		emb, err := g.encodeExtracted(out)
		if err != nil {
			// Encoder failed; log + bypass gate so we don't eat user audio.
			log.Printf("[vkb] speakergate: encode for similarity failed (bypassing gate): %v", err)
			g.lastSimilarity = 1.0
			return out, nil
		}
		sim := cosineSimilarity(emb, g.ref)
		g.lastSimilarity = sim
		return applyThreshold(out, sim, g.threshold), nil
	}
	g.lastSimilarity = 1.0
	return out, nil
}

// encodeExtracted runs the speaker encoder on the extracted audio.
func (g *SpeakerGate) encodeExtracted(audio []float32) ([]float32, error) {
	audioT, err := ort.NewTensor(ort.NewShape(1, int64(len(audio))), audio)
	if err != nil {
		return nil, fmt.Errorf("encoder: audio tensor: %w", err)
	}
	defer audioT.Destroy()
	embT, err := ort.NewEmptyTensor[float32](ort.NewShape(1, int64(g.encoderDim)))
	if err != nil {
		return nil, fmt.Errorf("encoder: emb tensor: %w", err)
	}
	defer embT.Destroy()
	if err := g.encoderSession.Run([]ort.Value{audioT}, []ort.Value{embT}); err != nil {
		return nil, fmt.Errorf("encoder: inference: %w", err)
	}
	out := make([]float32, g.encoderDim)
	copy(out, embT.GetData())
	return out, nil
}

// applyThreshold returns zeros same length as in if similarity is below
// threshold AND threshold is positive. Otherwise returns in unchanged.
func applyThreshold(in []float32, similarity, threshold float32) []float32 {
	if threshold > 0 && similarity < threshold {
		return make([]float32, len(in))
	}
	return in
}

// cosineSimilarity assumes a is L2-normalized (the enrolled reference is)
// but computes the norm for b on the fly (the extracted-audio embedding
// isn't normalized inside the model).
func cosineSimilarity(a, b []float32) float32 {
	if len(a) != len(b) {
		return 0
	}
	var dot, normB float64
	for i := range a {
		dot += float64(a[i]) * float64(b[i])
		normB += float64(b[i]) * float64(b[i])
	}
	if normB == 0 {
		return 0
	}
	return float32(dot / math.Sqrt(normB))
}

// Close releases the ONNX sessions.
func (g *SpeakerGate) Close() error {
	if g.encoderSession != nil {
		_ = g.encoderSession.Destroy()
		g.encoderSession = nil
	}
	return g.session.Destroy()
}

// Compile-time interface checks.
var _ audio.Stage = (*SpeakerGate)(nil)
var _ TSEExtractor = (*SpeakerGate)(nil)
