package speaker

import (
	"strings"
	"testing"
)

func TestBackendByName_EmptyReturnsDefault(t *testing.T) {
	b, err := BackendByName("")
	if err != nil {
		t.Fatalf("BackendByName(\"\"): %v", err)
	}
	if b != Default {
		t.Errorf("got %v, want Default", b)
	}
}

func TestBackendByName_KnownName(t *testing.T) {
	b, err := BackendByName("ecapa")
	if err != nil {
		t.Fatalf("BackendByName(ecapa): %v", err)
	}
	if b.Name != "ecapa" {
		t.Errorf("Name = %q, want ecapa", b.Name)
	}
	if b.EmbeddingDim != 192 {
		t.Errorf("EmbeddingDim = %d, want 192", b.EmbeddingDim)
	}
}

func TestBackendByName_UnknownReturnsError(t *testing.T) {
	_, err := BackendByName("nonexistent")
	if err == nil {
		t.Fatalf("expected error for unknown backend, got nil")
	}
	if !strings.Contains(err.Error(), "unknown backend") {
		t.Errorf("error %q does not mention 'unknown backend'", err)
	}
}

func TestBackendNames_IncludesECAPASorted(t *testing.T) {
	names := BackendNames()
	if len(names) == 0 {
		t.Fatalf("BackendNames returned empty")
	}
	found := false
	for _, n := range names {
		if n == "ecapa" {
			found = true
			break
		}
	}
	if !found {
		t.Errorf("BackendNames %v missing 'ecapa'", names)
	}
	for i := 1; i < len(names); i++ {
		if names[i-1] > names[i] {
			t.Errorf("BackendNames not sorted: %v", names)
			break
		}
	}
}

func TestBackend_PathHelpers(t *testing.T) {
	enc := ECAPA.EncoderPath("/tmp/models")
	want := "/tmp/models/speaker_encoder.onnx"
	if enc != want {
		t.Errorf("EncoderPath = %q, want %q", enc, want)
	}
	tse := ECAPA.TSEPath("/tmp/models")
	want = "/tmp/models/tse_model.onnx"
	if tse != want {
		t.Errorf("TSEPath = %q, want %q", tse, want)
	}
}
