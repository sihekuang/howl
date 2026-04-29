package pipeline

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/voice-keyboard/core/internal/audio"
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

func TestPipeline_HappyPath(t *testing.T) {
	src := make([]float32, 24000)
	cap := audio.NewFakeCapture(src, denoise.FrameSize)
	d := denoise.NewPassthrough()
	dy := dict.NewFuzzy([]string{"WebRTC"}, 1)
	tr := &fakeTranscriber{out: "hello webrt world"}
	cl := &fakeCleaner{out: "Hello, WebRTC world."}

	p := New(cap, d, tr, dy, cl)

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	stop := make(chan struct{})
	close(stop)

	res, err := p.Run(ctx, stop)
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
	cap := audio.NewFakeCapture(src, denoise.FrameSize)
	d := denoise.NewPassthrough()
	dy := dict.NewFuzzy([]string{"WebRTC"}, 1)
	tr := &fakeTranscriber{out: "use webrt please"}
	cl := &fakeCleaner{err: errors.New("network down")}

	p := New(cap, d, tr, dy, cl)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	stop := make(chan struct{})
	close(stop)

	res, err := p.Run(ctx, stop)
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

func TestPipeline_EmptyTranscriptionYieldsEmptyResult(t *testing.T) {
	src := make([]float32, 240) // half a frame
	cap := audio.NewFakeCapture(src, denoise.FrameSize)
	d := denoise.NewPassthrough()
	dy := dict.NewFuzzy(nil, 1)
	tr := &fakeTranscriber{out: ""}
	cl := &fakeCleaner{out: "should not be called"}

	p := New(cap, d, tr, dy, cl)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	stop := make(chan struct{})
	close(stop)

	res, err := p.Run(ctx, stop)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if res.Cleaned != "" {
		t.Errorf("expected empty cleaned for empty raw, got %q", res.Cleaned)
	}
}
