package speaker

import "context"

// TSEExtractor extracts the target speaker's audio from a mixed signal.
// mixed: 16kHz mono PCM samples from the chunker.
// ref:   enrollment audio (16kHz mono PCM), loaded once from enrollment.wav.
// Returns clean audio of the same length as mixed.
type TSEExtractor interface {
	Extract(ctx context.Context, mixed []float32, ref []float32) ([]float32, error)
}
