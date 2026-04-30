package speaker

import (
	"context"
	"fmt"
	"path/filepath"
	"time"
	"unsafe"

	"github.com/gen2brain/malgo"
)

// sourceFunc is the function signature for opening a mic source.
// Matches the production malgoSource; replaced by fakeSource.start in tests.
type sourceFunc func(ctx context.Context, sampleRate int) (<-chan []float32, error)

// Enroller records mic audio and saves enrollment artifacts to a directory.
type Enroller struct {
	sampleRate int
	source     sourceFunc
}

// NewEnroller returns an Enroller backed by the default system microphone.
func NewEnroller(sampleRate int) *Enroller {
	return &Enroller{
		sampleRate: sampleRate,
		source:     malgoSource,
	}
}

// Record captures audio for up to duration (or until ctx is cancelled),
// then writes enrollment.wav and speaker.json to dir.
func (e *Enroller) Record(ctx context.Context, dir string, duration time.Duration) error {
	recCtx, cancel := context.WithTimeout(ctx, duration)
	defer cancel()

	ch, err := e.source(recCtx, e.sampleRate)
	if err != nil {
		return fmt.Errorf("enroller: start mic: %w", err)
	}

	var samples []float32
	for s := range ch {
		samples = append(samples, s...)
	}
	if len(samples) == 0 {
		return fmt.Errorf("enroller: no audio captured")
	}

	wavPath := filepath.Join(dir, "enrollment.wav")
	if err := SaveWAV(wavPath, samples, e.sampleRate); err != nil {
		return fmt.Errorf("enroller: save wav: %w", err)
	}

	durationS := float64(len(samples)) / float64(e.sampleRate)
	p := Profile{
		Version:    1,
		RefAudio:   wavPath,
		EnrolledAt: time.Now().UTC(),
		DurationS:  durationS,
	}
	if err := SaveProfile(dir, p); err != nil {
		return fmt.Errorf("enroller: save profile: %w", err)
	}
	return nil
}

// malgoSource opens the default system mic via miniaudio.
func malgoSource(ctx context.Context, sampleRate int) (<-chan []float32, error) {
	mctx, err := malgo.InitContext(nil, malgo.ContextConfig{}, func(string) {})
	if err != nil {
		return nil, fmt.Errorf("malgo init context: %w", err)
	}

	cfg := malgo.DefaultDeviceConfig(malgo.Capture)
	cfg.Capture.Format = malgo.FormatF32
	cfg.Capture.Channels = 1
	cfg.SampleRate = uint32(sampleRate)
	cfg.Alsa.NoMMap = 1

	out := make(chan []float32, 64)

	onRecv := func(_, in []byte, frameCount uint32) {
		if frameCount == 0 || len(in) < int(frameCount)*4 {
			return
		}
		header := (*float32)(unsafe.Pointer(&in[0]))
		view := unsafe.Slice(header, int(frameCount))
		buf := make([]float32, frameCount)
		copy(buf, view)
		select {
		case out <- buf:
		case <-ctx.Done():
		}
	}

	device, err := malgo.InitDevice(mctx.Context, cfg, malgo.DeviceCallbacks{Data: onRecv})
	if err != nil {
		_ = mctx.Uninit()
		mctx.Free()
		return nil, fmt.Errorf("malgo init device: %w", err)
	}
	if err := device.Start(); err != nil {
		device.Uninit()
		_ = mctx.Uninit()
		mctx.Free()
		return nil, fmt.Errorf("malgo start: %w", err)
	}

	go func() {
		defer close(out)
		<-ctx.Done()
		device.Stop()
		device.Uninit()
		_ = mctx.Uninit()
		mctx.Free()
	}()

	return out, nil
}
