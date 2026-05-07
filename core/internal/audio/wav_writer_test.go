package audio

import (
	"math"
	"os"
	"path/filepath"
	"testing"
)

// TestWriteWAVMono_Roundtrip writes a known signal, reads it back via
// ReadWAVMono, and asserts the samples match within int16 quantisation
// noise. Verifies the writer produces a file the existing reader can
// parse.
func TestWriteWAVMono_Roundtrip(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "tone.wav")

	const sr = 16000
	const n = 8000 // 0.5 s
	in := make([]float32, n)
	for i := range in {
		in[i] = 0.5 * float32(math.Sin(2*math.Pi*440*float64(i)/float64(sr)))
	}

	if err := WriteWAVMono(path, in, sr); err != nil {
		t.Fatalf("WriteWAVMono: %v", err)
	}
	if st, err := os.Stat(path); err != nil {
		t.Fatalf("Stat: %v", err)
	} else if st.Size() < 44 {
		t.Fatalf("WAV file too small: %d bytes", st.Size())
	}

	out, srOut, err := ReadWAVMono(path)
	if err != nil {
		t.Fatalf("ReadWAVMono: %v", err)
	}
	if srOut != sr {
		t.Fatalf("sample rate roundtrip: got %d want %d", srOut, sr)
	}
	if len(out) != len(in) {
		t.Fatalf("sample count roundtrip: got %d want %d", len(out), len(in))
	}
	const tol = 1.0 / 32768.0 * 2 // 2 quantisation steps headroom
	for i := range in {
		if d := in[i] - out[i]; d > tol || d < -tol {
			t.Fatalf("sample %d roundtrip: in=%.6f out=%.6f diff=%.6f tol=%.6f",
				i, in[i], out[i], d, tol)
		}
	}
}

// TestWriteWAVMono_Clamps verifies samples outside [-1, 1] are
// clamped, not wrapped (which would produce loud pops).
func TestWriteWAVMono_Clamps(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "clamped.wav")
	in := []float32{2.0, -2.0, 0.0, 1.5, -1.5}
	if err := WriteWAVMono(path, in, 16000); err != nil {
		t.Fatalf("WriteWAVMono: %v", err)
	}
	out, _, err := ReadWAVMono(path)
	if err != nil {
		t.Fatalf("ReadWAVMono: %v", err)
	}
	if len(out) != len(in) {
		t.Fatalf("len roundtrip: %d != %d", len(out), len(in))
	}
	// Clamped values: 2 -> 1, -2 -> -1, 1.5 -> 1, -1.5 -> -1.
	// int16 representation: 1.0 -> 32767/32768 ≈ 0.99997 due to MaxInt16 quantisation.
	const tol = 1.0 / 32768.0 * 2
	wantSign := []float32{1, -1, 0, 1, -1}
	for i, w := range wantSign {
		if w == 0 {
			if d := out[i]; d > tol || d < -tol {
				t.Fatalf("zero sample %d: got %.6f", i, d)
			}
			continue
		}
		// expect ±0.99997 (within tol)
		if (w > 0 && out[i] < 1-tol*2) || (w < 0 && out[i] > -1+tol*2) {
			t.Fatalf("clamp sample %d: in=%.2f out=%.6f", i, in[i], out[i])
		}
	}
}
