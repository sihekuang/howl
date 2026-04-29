// Package audio provides PCM capture from the microphone. The Capture
// interface is satisfied by malgo (real hardware) in production and by
// the FakeCapture (replays a buffer) in tests.
package audio

import "context"

type Capture interface {
	// Start begins capturing PCM frames at the given sample rate, mono,
	// returning a channel that yields []float32 frames until Stop is
	// called or ctx is cancelled. Frame size is implementation-defined;
	// consumers must handle variable sizes.
	Start(ctx context.Context, sampleRate int) (<-chan []float32, error)

	// Stop ends an in-progress capture. Safe to call multiple times.
	Stop() error
}
