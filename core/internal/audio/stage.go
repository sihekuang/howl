// core/internal/audio/stage.go
package audio

import "context"

// Stage is one step in the audio processing chain. The framework calls
// Process for each batch of samples flowing through. All stages produce
// []float32 mono PCM in [-1, 1].
//
// Sample-rate transitions are implicit: each stage advertises OutputRate
// (or 0 to mean "same as input"). The composer is responsible for
// arranging stages so adjacent rates line up — there is no graph-time
// validation.
type Stage interface {
	// Name is a stable identifier used for logging and recording filenames.
	// Should be a single short token, lowercase, no spaces (e.g. "denoise").
	Name() string

	// OutputRate returns the sample rate of Process output, or 0 if the
	// stage preserves whatever rate it received.
	OutputRate() int

	// Process consumes a batch of samples and returns an output batch.
	// Stages MAY buffer internally and return fewer/zero samples per call;
	// the framework calls Flush at end-of-input to drain residuals.
	Process(ctx context.Context, in []float32) ([]float32, error)
}

// Flusher is optionally implemented by stages that buffer input internally.
// The framework calls Flush after the input stream closes; the returned
// samples are appended to the stage's output as if Process had returned them.
type Flusher interface {
	Flush(ctx context.Context) ([]float32, error)
}

// Closer is optionally implemented by stages that own resources. Pipeline
// calls Close on shutdown; safe to call multiple times.
type Closer interface {
	Close() error
}
