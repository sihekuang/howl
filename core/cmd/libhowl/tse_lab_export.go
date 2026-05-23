//go:build whispercpp

package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"context"
	"fmt"
	"path/filepath"

	"github.com/voice-keyboard/core/internal/audio"
	"github.com/voice-keyboard/core/internal/speaker"
)

// howl_tse_extract_file runs Target Speaker Extraction on a WAV file
// using the user's enrolled speaker embedding. Used by the Mac app's
// TSE Lab — a debug surface for verifying TSE works on arbitrary
// inputs (e.g. a 2-speaker mixture saved from another tool).
//
// inputPath:   16 kHz mono 16-bit PCM WAV (any duration).
// outputPath:  where to write the extracted WAV (16 kHz mono 16-bit PCM).
// modelsDir:   directory containing tse_model.onnx and speaker_encoder.onnx.
// voiceDir:    directory containing enrollment.emb (raw little-endian
//              float32 array of length backend.EmbeddingDim, written by
//              howl_enroll_compute → speaker.SaveEmbedding).
// onnxLibPath: absolute path to libonnxruntime.dylib.
//
// Synchronous and self-contained: doesn't touch the engine's pipeline
// state, so it's safe to call alongside an in-flight capture. The only
// shared mutation is InitONNXRuntime (idempotent across the process).
//
// Returns 0 on success, -1 on failure. On failure, howl_last_error
// returns a human-readable description (which the caller must free
// via howl_free_string).
//
//export howl_tse_extract_file
func howl_tse_extract_file(inputPath, outputPath, modelsDir, voiceDir, onnxLibPath *C.char) C.int {
	e := getEngine()
	if e == nil {
		// No engine — we can't surface the error via setLastError, but
		// returning -1 is the most we can do. The caller should have
		// howl_init'd first; this matches the contract of every other
		// engine-touching export.
		return -1
	}
	if inputPath == nil || outputPath == nil || modelsDir == nil || voiceDir == nil || onnxLibPath == nil {
		e.setLastError("howl_tse_extract_file: NULL argument")
		return -1
	}

	in := C.GoString(inputPath)
	out := C.GoString(outputPath)
	models := C.GoString(modelsDir)
	voice := C.GoString(voiceDir)
	onnxLib := C.GoString(onnxLibPath)
	if in == "" || out == "" || models == "" || voice == "" || onnxLib == "" {
		e.setLastError("howl_tse_extract_file: empty argument")
		return -1
	}

	if err := runTSEExtractFile(in, out, models, voice, onnxLib); err != nil {
		e.setLastError("howl_tse_extract_file: " + err.Error())
		return -1
	}
	return 0
}

// runTSEExtractFile is the testable Go-level body of howl_tse_extract_file.
// Splitting it out keeps the C ABI thin (string marshalling + error code)
// and lets unit tests exercise the pipeline without going through cgo.
func runTSEExtractFile(inputPath, outputPath, modelsDir, voiceDir, onnxLibPath string) error {
	samples, sr, err := audio.ReadWAVMono(inputPath)
	if err != nil {
		return fmt.Errorf("read input wav: %w", err)
	}
	if sr != targetSampleRate {
		return fmt.Errorf("input sample rate %d != %d", sr, targetSampleRate)
	}
	if len(samples) == 0 {
		return fmt.Errorf("input wav is empty")
	}

	backend := speaker.Default
	embPath := filepath.Join(voiceDir, "enrollment.emb")
	ref, err := speaker.LoadEmbedding(embPath, backend.EmbeddingDim)
	if err != nil {
		return fmt.Errorf("load enrollment: %w", err)
	}

	if err := speaker.InitONNXRuntime(onnxLibPath); err != nil {
		return fmt.Errorf("init onnx runtime: %w", err)
	}

	tse, err := speaker.NewSpeakerGate(speaker.SpeakerGateOptions{
		ModelPath: backend.TSEPath(modelsDir),
		Reference: ref,
	})
	if err != nil {
		return fmt.Errorf("new speaker gate: %w", err)
	}
	defer tse.Close()

	extracted, err := tse.Extract(context.Background(), samples)
	if err != nil {
		return fmt.Errorf("extract: %w", err)
	}

	if err := audio.WriteWAVMono(outputPath, extracted, targetSampleRate); err != nil {
		return fmt.Errorf("write output wav: %w", err)
	}
	return nil
}
