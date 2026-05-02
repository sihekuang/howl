package denoise

import (
	"context"

	"github.com/voice-keyboard/core/internal/audio"
)

// Stage adapts a frame-oriented Denoiser (480-sample input, 480-sample
// output) into an audio.Stage that accepts variable-sized input by
// buffering. Residual sub-frame samples are returned, zero-padded, on
// Flush so the tail of an utterance isn't lost.
type Stage struct {
	d   Denoiser
	buf []float32
}

// NewStage wraps an existing Denoiser. Takes ownership of d for Close.
func NewStage(d Denoiser) *Stage {
	return &Stage{d: d}
}

func (s *Stage) Name() string    { return "denoise" }
func (s *Stage) OutputRate() int { return 0 } // preserves input rate

func (s *Stage) Process(_ context.Context, in []float32) ([]float32, error) {
	if len(in) == 0 {
		return nil, nil
	}
	s.buf = append(s.buf, in...)
	if len(s.buf) < FrameSize {
		return nil, nil
	}
	frames := len(s.buf) / FrameSize
	out := make([]float32, 0, frames*FrameSize)
	for i := 0; i < frames; i++ {
		dn := s.d.Process(s.buf[i*FrameSize : (i+1)*FrameSize])
		out = append(out, dn...)
	}
	// Slide remainder to head of buffer.
	rem := len(s.buf) - frames*FrameSize
	copy(s.buf, s.buf[frames*FrameSize:])
	s.buf = s.buf[:rem]
	return out, nil
}

func (s *Stage) Flush(_ context.Context) ([]float32, error) {
	if len(s.buf) == 0 {
		return nil, nil
	}
	pad := make([]float32, FrameSize)
	copy(pad, s.buf)
	s.buf = s.buf[:0]
	return s.d.Process(pad), nil
}

func (s *Stage) Close() error {
	if s.d == nil {
		return nil
	}
	return s.d.Close()
}

// Compile-time interface satisfaction checks.
var (
	_ audio.Stage   = (*Stage)(nil)
	_ audio.Flusher = (*Stage)(nil)
	_ audio.Closer  = (*Stage)(nil)
)
