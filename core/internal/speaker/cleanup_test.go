package speaker

import (
	"context"
	"testing"
)

func TestPassthrough_ReturnsInputUnchanged(t *testing.T) {
	in := []float32{0.1, -0.2, 0.3, 0.0, 0.5}
	p := NewPassthrough()
	defer p.Close()

	out, err := p.Process(context.Background(), in)
	if err != nil {
		t.Fatalf("Process: %v", err)
	}
	if len(out) != len(in) {
		t.Fatalf("len(out)=%d, want %d", len(out), len(in))
	}
	for i := range in {
		if out[i] != in[i] {
			t.Errorf("out[%d]=%f, want %f", i, out[i], in[i])
		}
	}
}

func TestPassthrough_ReturnsCopyNotAlias(t *testing.T) {
	in := []float32{1.0, 2.0, 3.0}
	p := NewPassthrough()
	defer p.Close()

	out, _ := p.Process(context.Background(), in)
	out[0] = 999
	if in[0] != 1.0 {
		t.Errorf("Process aliased input slice; mutating output mutated input")
	}
}

func TestPassthrough_Name(t *testing.T) {
	if got := NewPassthrough().Name(); got != "passthrough" {
		t.Errorf("Name() = %q, want %q", got, "passthrough")
	}
}
