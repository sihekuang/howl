//go:build whispercpp

package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"github.com/voice-keyboard/core/internal/resample"
	"github.com/voice-keyboard/core/internal/speaker"
)

// runEnrollCompute decimates 48 kHz samples to 16 kHz, computes the
// speaker embedding, and atomically writes the three enrollment files
// (enrollment.wav, enrollment.emb, speaker.json) to profileDir.
//
// Returns nil on success; on any error, profileDir is left as it was
// (no partial files written).
func runEnrollCompute(samples48k []float32, profileDir, encoderPath, onnxLibPath string) error {
	if err := os.MkdirAll(profileDir, 0755); err != nil {
		return fmt.Errorf("enroll: mkdir profile: %w", err)
	}
	if err := speaker.InitONNXRuntime(onnxLibPath); err != nil {
		return fmt.Errorf("enroll: init onnx runtime: %w", err)
	}

	dec := resample.NewDecimate3()
	samples16k := dec.Process(samples48k)
	if len(samples16k) == 0 {
		return fmt.Errorf("enroll: decimation produced no samples")
	}

	emb, err := speaker.ComputeEmbedding(encoderPath, samples16k)
	if err != nil {
		return fmt.Errorf("enroll: compute embedding: %w", err)
	}

	return writeEnrollmentFiles(profileDir, samples16k, emb)
}

// writeEnrollmentFiles atomically writes the three artefacts.
// Each file is written as <name>.tmp then renamed; on any failure the
// .tmp files for this call are cleaned up.
func writeEnrollmentFiles(profileDir string, samples16k []float32, emb []float32) error {
	wavTmp := filepath.Join(profileDir, "enrollment.wav.tmp")
	embTmp := filepath.Join(profileDir, "enrollment.emb.tmp")
	jsonTmp := filepath.Join(profileDir, "speaker.json.tmp")

	cleanup := func() {
		os.Remove(wavTmp)
		os.Remove(embTmp)
		os.Remove(jsonTmp)
	}

	if err := speaker.SaveWAV(wavTmp, samples16k, 16000); err != nil {
		cleanup()
		return fmt.Errorf("enroll: save wav: %w", err)
	}
	if err := speaker.SaveEmbedding(embTmp, emb); err != nil {
		cleanup()
		return fmt.Errorf("enroll: save emb: %w", err)
	}
	wavPath := filepath.Join(profileDir, "enrollment.wav")
	embPath := filepath.Join(profileDir, "enrollment.emb")
	durationS := float64(len(samples16k)) / 16000.0
	p := speaker.Profile{
		Version:    1,
		RefAudio:   wavPath,
		EnrolledAt: time.Now().UTC(),
		DurationS:  durationS,
	}
	if err := saveProfileTmp(jsonTmp, p); err != nil {
		cleanup()
		return fmt.Errorf("enroll: save profile: %w", err)
	}

	if err := os.Rename(wavTmp, wavPath); err != nil {
		cleanup()
		return fmt.Errorf("enroll: rename wav: %w", err)
	}
	if err := os.Rename(embTmp, embPath); err != nil {
		os.Remove(wavPath) // wav landed; roll it back
		cleanup()
		return fmt.Errorf("enroll: rename emb: %w", err)
	}
	if err := os.Rename(jsonTmp, filepath.Join(profileDir, "speaker.json")); err != nil {
		os.Remove(wavPath)
		os.Remove(embPath)
		cleanup()
		return fmt.Errorf("enroll: rename profile: %w", err)
	}
	return nil
}

// saveProfileTmp writes a Profile to an explicit path (temp file) using
// the same JSON format as speaker.SaveProfile.
//
// We can't use speaker.SaveProfile directly because it writes to
// <dir>/speaker.json (no path override), and we need to write to .tmp
// first for atomic rename. If speaker.SaveProfile's format ever changes,
// keep this in sync.
func saveProfileTmp(path string, p speaker.Profile) error {
	data, err := json.MarshalIndent(p, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(path, data, 0644)
}
