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

// howl_tse_extract_file runs audio filtering on a WAV file using the
// user's enrolled speaker embedding. Used by the Mac app's TSE Lab — a
// debug surface for verifying speaker isolation works on arbitrary inputs
// (e.g. a 2-speaker mixture saved from another tool).
//
// inputPath:   16 kHz mono 16-bit PCM WAV (any duration).
// outputPath:  where to write the filtered WAV (16 kHz mono 16-bit PCM).
// modelsDir:   directory containing backend model files. For the ecapa
//              backend: tse_model.onnx + speaker_encoder.onnx. For the
//              pyannote backend: pyannote_seg.onnx + speaker_encoder.onnx.
// voiceDir:    directory containing enrollment.emb (raw little-endian
//              float32 array of length backend.EmbeddingDim, written by
//              howl_enroll_compute → speaker.SaveEmbedding).
// onnxLibPath: absolute path to libonnxruntime.dylib.
// backend:     optional backend name ("" / "ecapa" → SpeakerGate
//              separation; "pyannote" → DiarMask diarize+mask). NULL
//              treated as empty (defaults to ecapa).
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
func howl_tse_extract_file(inputPath, outputPath, modelsDir, voiceDir, onnxLibPath, backend *C.char) C.int {
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
	backendName := "" // empty → speaker.Default (ecapa)
	if backend != nil {
		backendName = C.GoString(backend)
	}
	if in == "" || out == "" || models == "" || voice == "" || onnxLib == "" {
		e.setLastError("howl_tse_extract_file: empty argument")
		return -1
	}

	if err := runAudioFilterExtractFile(in, out, models, voice, onnxLib, backendName); err != nil {
		e.setLastError("howl_tse_extract_file: " + err.Error())
		return -1
	}
	return 0
}

// runAudioFilterExtractFile is the testable body of howl_tse_extract_file.
// It dispatches on the named backend's Kind: separation backends run the
// reconstructing SpeakerGate; diarmask backends run DiarMask (diarize →
// cosine SELECT → time MASK). Both read a 16 kHz mono WAV and write one.
func runAudioFilterExtractFile(inputPath, outputPath, modelsDir, voiceDir, onnxLibPath, backendName string) error {
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

	backend, err := speaker.BackendByName(backendName)
	if err != nil {
		return fmt.Errorf("backend: %w", err)
	}
	embPath := filepath.Join(voiceDir, "enrollment.emb")
	ref, err := speaker.LoadEmbedding(embPath, backend.EmbeddingDim)
	if err != nil {
		return fmt.Errorf("load enrollment: %w", err)
	}
	if err := speaker.InitONNXRuntime(onnxLibPath); err != nil {
		return fmt.Errorf("init onnx runtime: %w", err)
	}

	var filtered []float32
	switch backend.Kind {
	case speaker.BackendDiarMask:
		seg, err := speaker.NewPyannoteSegmenter(backend.SegPath(modelsDir))
		if err != nil {
			return fmt.Errorf("new segmenter: %w", err)
		}
		defer seg.Close()
		encPath := backend.EncoderPath(modelsDir)
		dim := backend.EmbeddingDim
		dm, err := speaker.NewDiarMask(speaker.DiarMaskOptions{
			Segmenter: seg,
			Embed:     func(s []float32) ([]float32, error) { return speaker.ComputeEmbedding(encPath, s, dim) },
			Reference: ref,
		})
		if err != nil {
			return fmt.Errorf("new diarmask: %w", err)
		}
		filtered, err = dm.Process(context.Background(), samples)
		if err != nil {
			return fmt.Errorf("diarmask process: %w", err)
		}
	default: // BackendSeparation
		gate, err := speaker.NewSpeakerGate(speaker.SpeakerGateOptions{
			ModelPath:   backend.TSEPath(modelsDir),
			Reference:   ref,
			Threshold:   0.40,
			EncoderPath: backend.EncoderPath(modelsDir),
			EncoderDim:  backend.EmbeddingDim,
		})
		if err != nil {
			return fmt.Errorf("new speaker gate: %w", err)
		}
		defer gate.Close()
		filtered, err = gate.Extract(context.Background(), samples)
		if err != nil {
			return fmt.Errorf("extract: %w", err)
		}
	}

	if err := audio.WriteWAVMono(outputPath, filtered, targetSampleRate); err != nil {
		return fmt.Errorf("write output wav: %w", err)
	}
	return nil
}
