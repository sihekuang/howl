package audio

import (
	"context"
	"errors"
	"sync"
)

// FakeCapture replays a fixed buffer in fixed-size frames. Used in tests
// to drive the pipeline deterministically without hardware.
type FakeCapture struct {
	src       []float32
	frameSize int

	mu     sync.Mutex
	cancel context.CancelFunc
}

func NewFakeCapture(src []float32, frameSize int) *FakeCapture {
	return &FakeCapture{src: src, frameSize: frameSize}
}

func (f *FakeCapture) Start(ctx context.Context, sampleRate int) (<-chan []float32, error) {
	if f.frameSize <= 0 {
		return nil, errors.New("fake capture: frameSize must be > 0")
	}
	subCtx, cancel := context.WithCancel(ctx)
	f.mu.Lock()
	if f.cancel != nil {
		f.cancel() // cancel any prior goroutine to avoid leak on re-entry
	}
	f.cancel = cancel
	f.mu.Unlock()

	out := make(chan []float32, 4)
	go func() {
		defer close(out)
		for i := 0; i < len(f.src); i += f.frameSize {
			end := i + f.frameSize
			if end > len(f.src) {
				end = len(f.src)
			}
			frame := make([]float32, end-i)
			copy(frame, f.src[i:end])
			select {
			case out <- frame:
			case <-subCtx.Done():
				return
			}
		}
	}()
	return out, nil
}

func (f *FakeCapture) Stop() error {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.cancel != nil {
		f.cancel()
		f.cancel = nil
	}
	return nil
}
