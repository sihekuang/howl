package audio

import (
	"os"
	"path/filepath"
	"testing"
)

func TestReadWAVMono_RoundTripPCM(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "tone.wav")
	const sr = 16000
	const n = 100
	pcm := make([]byte, n*2)
	for i := 0; i < n; i++ {
		v := int16(i * 200)
		pcm[i*2] = byte(uint16(v) & 0xFF)
		pcm[i*2+1] = byte(uint16(v) >> 8)
	}
	const byteRate = sr * 2
	hdr := []byte{
		'R', 'I', 'F', 'F',
		0, 0, 0, 0, // size — patched below
		'W', 'A', 'V', 'E',
		'f', 'm', 't', ' ',
		16, 0, 0, 0,
		1, 0, // PCM
		1, 0, // mono
		byte(sr & 0xFF), byte((sr >> 8) & 0xFF), 0, 0, // sample rate
		byte(byteRate & 0xFF), byte((byteRate >> 8) & 0xFF), 0, 0, // byte rate
		2, 0, // block align
		16, 0, // bits per sample
		'd', 'a', 't', 'a',
		byte(n * 2), 0, 0, 0,
	}
	out := append(hdr, pcm...)
	totalSize := uint32(len(out) - 8)
	out[4] = byte(totalSize)
	out[5] = byte(totalSize >> 8)
	if err := os.WriteFile(p, out, 0o644); err != nil {
		t.Fatal(err)
	}
	got, gotSR, err := ReadWAVMono(p)
	if err != nil {
		t.Fatalf("ReadWAVMono: %v", err)
	}
	if gotSR != sr {
		t.Errorf("sampleRate = %d, want %d", gotSR, sr)
	}
	if len(got) != n {
		t.Errorf("len(samples) = %d, want %d", len(got), n)
	}
}

func TestReadWAVMono_RejectsNonRIFF(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "garbage.wav")
	if err := os.WriteFile(p, []byte("not a wav placeholder padded out to forty four bytes ok"), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, _, err := ReadWAVMono(p); err == nil {
		t.Fatal("expected error for non-RIFF file")
	}
}

func TestReadWAVMono_RejectsMissingFile(t *testing.T) {
	if _, _, err := ReadWAVMono("/no/such/file.wav"); err == nil {
		t.Fatal("expected error for missing file")
	}
}
