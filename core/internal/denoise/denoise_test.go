package denoise

import "testing"

func TestPassthrough_ReturnsCopyUnchanged(t *testing.T) {
	in := make([]float32, FrameSize)
	for i := range in {
		in[i] = float32(i) / float32(FrameSize)
	}
	p := NewPassthrough()
	out := p.Process(in)
	if len(out) != FrameSize {
		t.Fatalf("out length = %d, want %d", len(out), FrameSize)
	}
	for i := range in {
		if out[i] != in[i] {
			t.Errorf("sample %d: got %f, want %f", i, out[i], in[i])
		}
	}
	out[0] = 999
	if in[0] == 999 {
		t.Errorf("Process must return a copy, not the same slice")
	}
}
