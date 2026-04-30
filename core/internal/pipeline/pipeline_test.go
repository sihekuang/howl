package pipeline

import (
	"context"
	"errors"
	"sync"
	"testing"
	"time"

	"github.com/voice-keyboard/core/internal/denoise"
	"github.com/voice-keyboard/core/internal/dict"
)

type fakeTranscriber struct {
	out string
	err error
}

func (f *fakeTranscriber) Transcribe(ctx context.Context, _ []float32) (string, error) {
	return f.out, f.err
}
func (f *fakeTranscriber) Close() error { return nil }

type fakeCleaner struct {
	out string
	err error
}

func (f *fakeCleaner) Clean(ctx context.Context, _ string, _ []string) (string, error) {
	return f.out, f.err
}

// pushChan returns a closed channel pre-loaded with `samples` chunked
// into `chunkSize`-sample frames, simulating Swift pushing frames in.
func pushChan(samples []float32, chunkSize int) <-chan []float32 {
	ch := make(chan []float32, len(samples)/chunkSize+2)
	for i := 0; i < len(samples); i += chunkSize {
		end := i + chunkSize
		if end > len(samples) {
			end = len(samples)
		}
		ch <- samples[i:end]
	}
	close(ch)
	return ch
}

func TestPipeline_HappyPath(t *testing.T) {
	src := make([]float32, 24000)
	d := denoise.NewPassthrough()
	dy := dict.NewFuzzy([]string{"WebRTC"}, 1)
	tr := &fakeTranscriber{out: "hello webrt world"}
	cl := &fakeCleaner{out: "Hello, WebRTC world."}

	p := New(d, tr, dy, cl)

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	res, err := p.Run(ctx, pushChan(src, denoise.FrameSize))
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if res.Cleaned != "Hello, WebRTC world." {
		t.Errorf("Cleaned = %q", res.Cleaned)
	}
	if res.Raw != "hello webrt world" {
		t.Errorf("Raw = %q", res.Raw)
	}
}

func TestPipeline_LLMErrorFallsBackToDictText(t *testing.T) {
	src := make([]float32, 24000)
	d := denoise.NewPassthrough()
	dy := dict.NewFuzzy([]string{"WebRTC"}, 1)
	tr := &fakeTranscriber{out: "use webrt please"}
	cl := &fakeCleaner{err: errors.New("network down")}

	p := New(d, tr, dy, cl)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	res, err := p.Run(ctx, pushChan(src, denoise.FrameSize))
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if res.Cleaned != "use WebRTC please" {
		t.Errorf("Cleaned should fall back to dict-corrected raw; got %q", res.Cleaned)
	}
	if res.LLMError == nil {
		t.Errorf("LLMError should be set when LLM fails")
	}
}

func TestPipeline_LevelCallbackFires(t *testing.T) {
	src := make([]float32, 24000) // 0.5s @ 48kHz
	for i := range src {
		src[i] = 0.5
	}
	d := denoise.NewPassthrough()
	dy := dict.NewFuzzy(nil, 1)
	tr := &fakeTranscriber{out: "hi"}
	cl := &fakeCleaner{out: "hi"}

	p := New(d, tr, dy, cl)
	var levels []float32
	var levelMu sync.Mutex
	p.LevelCallback = func(rms float32) {
		levelMu.Lock()
		levels = append(levels, rms)
		levelMu.Unlock()
	}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	_, err := p.Run(ctx, pushChan(src, denoise.FrameSize))
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	levelMu.Lock()
	defer levelMu.Unlock()
	if len(levels) == 0 {
		t.Fatalf("expected at least one level callback")
	}
	for i, l := range levels {
		if l < 0.4 || l > 0.6 {
			t.Errorf("level[%d] = %f, expected ~0.5", i, l)
		}
	}
}

func TestPipeline_EmptyTranscriptionYieldsEmptyResult(t *testing.T) {
	src := make([]float32, 240) // half a frame
	d := denoise.NewPassthrough()
	dy := dict.NewFuzzy(nil, 1)
	tr := &fakeTranscriber{out: ""}
	cl := &fakeCleaner{out: "should not be called"}

	p := New(d, tr, dy, cl)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	res, err := p.Run(ctx, pushChan(src, denoise.FrameSize))
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if res.Cleaned != "" {
		t.Errorf("expected empty cleaned for empty raw, got %q", res.Cleaned)
	}
}
