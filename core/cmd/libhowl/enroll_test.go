//go:build whispercpp

package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestWriteEnrollmentFiles_AllThreeWritten(t *testing.T) {
	dir := t.TempDir()
	samples16k := make([]float32, 16000)
	for i := range samples16k {
		samples16k[i] = float32(i) / 16000
	}
	emb := make([]float32, 256)
	for i := range emb {
		emb[i] = 0.0625 // ‖e‖ = 1.0
	}

	if err := writeEnrollmentFiles(dir, samples16k, emb); err != nil {
		t.Fatalf("writeEnrollmentFiles: %v", err)
	}

	for _, name := range []string{"enrollment.wav", "enrollment.emb", "speaker.json"} {
		path := filepath.Join(dir, name)
		fi, err := os.Stat(path)
		if err != nil {
			t.Errorf("%s missing: %v", name, err)
			continue
		}
		if fi.Size() == 0 {
			t.Errorf("%s is empty", name)
		}
	}

	// No .tmp files should remain.
	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatalf("ReadDir: %v", err)
	}
	for _, e := range entries {
		if filepath.Ext(e.Name()) == ".tmp" {
			t.Errorf("leftover temp file: %s", e.Name())
		}
	}
}

func TestWriteEnrollmentFiles_NoPartialOnFailure(t *testing.T) {
	// Use a non-existent parent dir to force failure on the first write.
	dir := filepath.Join(t.TempDir(), "does-not-exist", "nope")
	samples16k := make([]float32, 16000)
	emb := make([]float32, 256)

	err := writeEnrollmentFiles(dir, samples16k, emb)
	if err == nil {
		t.Fatal("expected error for missing parent dir, got nil")
	}
	// dir doesn't exist, so nothing to clean up; just sanity-check no panic.
}
