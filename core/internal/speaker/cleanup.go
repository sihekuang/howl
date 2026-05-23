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
