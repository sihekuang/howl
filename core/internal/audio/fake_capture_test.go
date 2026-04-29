package audio

import (
	"context"
	"testing"
	"time"
)

func TestFakeCapture_ReplaysBufferAndCloses(t *testing.T) {
	src := make([]float32, 1500)
	for i := range src {
		src[i] = float32(i)
	}
	fake := NewFakeCapture(src, 500)

	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()

	frames, err := fake.Start(ctx, 48000)
	if err != nil {
		t.Fatalf("Start: %v", err)
	}

	var got []float32
	for f := range frames {
		got = append(got, f...)
	}
	if len(got) != len(src) {
		t.Errorf("got %d samples, want %d", len(got), len(src))
	}
	for i := range src {
		if got[i] != src[i] {
			t.Errorf("sample %d = %f, want %f", i, got[i], src[i])
			break
		}
	}
}

func TestFakeCapture_StopHaltsEarly(t *testing.T) {
	src := make([]float32, 10000)
	fake := NewFakeCapture(src, 1000)

	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()

	frames, err := fake.Start(ctx, 48000)
	if err != nil {
		t.Fatalf("Start: %v", err)
	}

	<-frames
	if err := fake.Stop(); err != nil {
		t.Errorf("Stop: %v", err)
	}

	deadline := time.After(500 * time.Millisecond)
	for {
		select {
		case _, ok := <-frames:
			if !ok {
				return
			}
		case <-deadline:
			t.Fatal("frames channel did not close within 500ms after Stop()")
		}
	}
}

func TestFakeCapture_ContextCancelHaltsEarly(t *testing.T) {
	src := make([]float32, 10000)
	fake := NewFakeCapture(src, 1000)

	ctx, cancel := context.WithCancel(context.Background())
	frames, err := fake.Start(ctx, 48000)
	if err != nil {
		t.Fatalf("Start: %v", err)
	}
	<-frames
	cancel()

	deadline := time.After(500 * time.Millisecond)
	for {
		select {
		case _, ok := <-frames:
			if !ok {
				return
			}
		case <-deadline:
			t.Fatal("frames channel did not close within 500ms after ctx cancel")
		}
	}
}
