package audio

import (
	"context"
	"errors"
	"fmt"
	"sync"
	"time"
	"unsafe"

	"github.com/gen2brain/malgo"
)

const malgoChannels = 1

// stopTimeout bounds how long Stop will wait for the cleanup goroutine
// to finish tearing down the malgo device and context.
const stopTimeout = 2 * time.Second

var _ Capture = (*MalgoCapture)(nil)

// MalgoCapture captures PCM from the default system microphone using
// miniaudio (via the malgo Go bindings). It produces float32 mono frames
// at the requested sample rate.
type MalgoCapture struct {
	mu       sync.Mutex
	ctxMalgo *malgo.AllocatedContext
	device   *malgo.Device
	out      chan []float32
	cancel   context.CancelFunc
	done     chan struct{} // closed when the cleanup goroutine has fully run
}

func NewMalgoCapture() *MalgoCapture {
	return &MalgoCapture{}
}

func (m *MalgoCapture) Start(ctx context.Context, sampleRate int) (<-chan []float32, error) {
	m.mu.Lock()
	defer m.mu.Unlock()

	if m.device != nil {
		return nil, errors.New("malgo capture: already started")
	}

	mctx, err := malgo.InitContext(nil, malgo.ContextConfig{}, func(message string) {})
	if err != nil {
		return nil, fmt.Errorf("malgo init context: %w", err)
	}

	cfg := malgo.DefaultDeviceConfig(malgo.Capture)
	cfg.Capture.Format = malgo.FormatF32
	cfg.Capture.Channels = malgoChannels
	cfg.SampleRate = uint32(sampleRate)
	cfg.Alsa.NoMMap = 1

	subCtx, cancel := context.WithCancel(ctx)
	out := make(chan []float32, 32)

	onRecv := func(_, in []byte, frameCount uint32) {
		// `in` is interleaved float32 mono. We reinterpret bytes as
		// float32 via unsafe.Slice (Go 1.17+), then copy out so the
		// caller owns the buffer.
		if frameCount == 0 || len(in) < int(frameCount)*4 {
			return
		}
		header := (*float32)(unsafe.Pointer(&in[0]))
		view := unsafe.Slice(header, int(frameCount))
		samples := make([]float32, frameCount)
		copy(samples, view)
		select {
		case out <- samples:
		case <-subCtx.Done():
		}
	}

	deviceCallbacks := malgo.DeviceCallbacks{Data: onRecv}
	device, err := malgo.InitDevice(mctx.Context, cfg, deviceCallbacks)
	if err != nil {
		_ = mctx.Uninit()
		mctx.Free()
		cancel()
		close(out)
		return nil, fmt.Errorf("malgo init device: %w", err)
	}
	if err := device.Start(); err != nil {
		device.Uninit()
		_ = mctx.Uninit()
		mctx.Free()
		cancel()
		close(out)
		return nil, fmt.Errorf("malgo start: %w", err)
	}

	done := make(chan struct{})
	m.ctxMalgo = mctx
	m.device = device
	m.out = out
	m.cancel = cancel
	m.done = done

	// stop+cleanup goroutine. Closes done last so Stop can wait on it.
	go func() {
		defer close(done)
		<-subCtx.Done()
		m.mu.Lock()
		defer m.mu.Unlock()
		if m.device != nil {
			m.device.Uninit()
			m.device = nil
		}
		if m.ctxMalgo != nil {
			_ = m.ctxMalgo.Uninit()
			m.ctxMalgo.Free()
			m.ctxMalgo = nil
		}
		if m.out != nil {
			close(m.out)
			m.out = nil
		}
		m.cancel = nil
		m.done = nil
	}()

	return out, nil
}

// Stop signals the capture to shut down and blocks (up to stopTimeout)
// until the cleanup goroutine has fully torn down the malgo device and
// context. Synchronous semantics make it safe to call Start again
// immediately after Stop returns without racing the previous Stop.
func (m *MalgoCapture) Stop() error {
	m.mu.Lock()
	cancel := m.cancel
	done := m.done
	if cancel != nil {
		cancel()
		m.cancel = nil
	}
	m.mu.Unlock()
	if done == nil {
		return nil
	}
	select {
	case <-done:
		return nil
	case <-time.After(stopTimeout):
		return errors.New("malgo capture: stop timed out")
	}
}
