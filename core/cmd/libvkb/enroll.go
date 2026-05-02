//go:build whispercpp

package main

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"github.com/voice-keyboard/core/internal/resample"
	"github.com/voice-keyboard/core/internal/speaker"
)

const targetSampleRate = 16000

// runEnrollCompute decimates 48 kHz samples to 16 kHz, computes the
// speaker embedding, and writes the three enrollment files
// (enrollment.wav, enrollment.emb, speaker.json) to profileDir.
//
// On a fresh profile (empty dir), the function is atomic: either all
// three files land or none do. On re-enrollment over an existing
// profile, the rollback path can leave profileDir in a partially
// updated state — for example if the speaker.json rename fails after
// the wav and emb were already replaced, we delete the new wav/emb but
// the old speaker.json remains pointing at deleted files. In practice
// this is recoverable (the user re-enrolls), and it keeps the contract
// simple. A future change can add full preserve-on-failure semantics
// by renaming old targets to .bak first.
func runEnrollCompute(samples48k []float32, profileDir, encoderPath, onnxLibPath string) error {
	if err := os.MkdirAll(profileDir, 0700); err != nil {
		return fmt.Errorf("enroll: mkdir profile: %w", err)
	}
	if err := speaker.InitONNXRuntime(onnxLibPath); err != nil {
		return fmt.Errorf("enroll: init onnx runtime: %w", err)
	}

	dec := resample.NewDecimate3()
	samples16k, _ := dec.Process(context.Background(), samples48k)
	if len(samples16k) == 0 {
		return fmt.Errorf("enroll: decimation produced no samples")
	}

	// Backend selection lives in the runtime config; for now buildPipeline
	// drives that. The enrollment path always uses the default backend
	// — we don't yet have a path for the host (Swift) to pass a backend
	// name through vkb_enroll_compute. When a second backend ships, that
	// API gains a backend parameter and this resolves it here.
	backend := speaker.Default
	emb, err := speaker.ComputeEmbedding(encoderPath, samples16k, backend.EmbeddingDim)
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

	if err := speaker.SaveWAV(wavTmp, samples16k, targetSampleRate); err != nil {
		cleanup()
		return fmt.Errorf("enroll: save wav: %w", err)
	}
	if err := speaker.SaveEmbedding(embTmp, emb); err != nil {
		cleanup()
		return fmt.Errorf("enroll: save emb: %w", err)
	}
	wavPath := filepath.Join(profileDir, "enrollment.wav")
	embPath := filepath.Join(profileDir, "enrollment.emb")
	durationS := float64(len(samples16k)) / float64(targetSampleRate)
	p := speaker.Profile{
		Version:    1,
		RefAudio:   wavPath,
		EnrolledAt: time.Now().UTC(),
		DurationS:  durationS,
	}
	if err := speaker.WriteProfileTo(jsonTmp, p); err != nil {
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
