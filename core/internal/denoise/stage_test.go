package denoise

import (
	"context"
	"testing"
)

func TestStageMetadata(t *testing.T) {
	s := NewStage(NewPassthrough())
	if s.Name() != "denoise" {
		t.Errorf("Name=%q", s.Name())
	}
	if s.OutputRate() != 0 {
		t.Errorf("OutputRate=%d, want 0 (preserves input)", s.OutputRate())
	}
}

func TestStageBuffers480Frames(t *testing.T) {
	s := NewStage(NewPassthrough())
	// 1000 samples → emits 2 frames (960 samples), buffers 40.
	out, err := s.Process(context.Background(), make([]float32, 1000))
	if err != nil {
		t.Fatalf("Process: %v", err)
	}
	if len(out) != 960 {
		t.Errorf("Process out=%d, want 960", len(out))
	}
	flush, err := s.Flush(context.Background())
	if err != nil {
		t.Fatalf("Flush: %v", err)
	}
	// Residual 40 samples are zero-padded to 480 and emitted as one frame.
	if len(flush) != 480 {
		t.Errorf("Flush out=%d, want 480", len(flush))
	}
}

func TestStageEmptyInput(t *testing.T) {
	s := NewStage(NewPassthrough())
	out, _ := s.Process(context.Background(), nil)
	if len(out) != 0 {
		t.Errorf("nil input produced %d samples", len(out))
	}
	flush, _ := s.Flush(context.Background())
	if len(flush) != 0 {
		t.Errorf("Flush with empty buffer produced %d samples", len(flush))
	}
}

func TestStageMultipleProcessCalls(t *testing.T) {
	s := NewStage(NewPassthrough())
	out1, _ := s.Process(context.Background(), make([]float32, 300))
	out2, _ := s.Process(context.Background(), make([]float32, 300))
	// 300+300=600 → emit 480, buffer 120.
	if len(out1) != 0 {
		t.Errorf("first call out=%d, want 0", len(out1))
	}
	if len(out2) != 480 {
		t.Errorf("second call out=%d, want 480", len(out2))
	}
}
