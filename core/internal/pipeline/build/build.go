//go:build whispercpp

// Package build constructs a fresh *pipeline.Pipeline from a
// config.Config. Lives in its own sub-package because it pulls in
// transcribe (whispercpp build tag) which the rest of pipeline avoids.
//
// Used by libhowl's engine for the live pipeline + by the replay
// package for transient per-preset pipelines in a Compare run.
package build

import (
	"log"
	"path/filepath"

	"github.com/voice-keyboard/core/internal/audio"
	"github.com/voice-keyboard/core/internal/config"
	"github.com/voice-keyboard/core/internal/denoise"
	"github.com/voice-keyboard/core/internal/dict"
	"github.com/voice-keyboard/core/internal/llm"
	"github.com/voice-keyboard/core/internal/pipeline"
	"github.com/voice-keyboard/core/internal/resample"
	"github.com/voice-keyboard/core/internal/speaker"
	"github.com/voice-keyboard/core/internal/transcribe"
)

// Options configures FromOptions.
type Options struct {
	Config        config.Config
	NewDeepFilter func(string) denoise.Denoiser
	SetLastError  func(string)
	// SharedTranscriber, when non-nil, is used instead of constructing
	// a fresh whisper. Caller owns its lifetime — the pipeline's Close()
	// will not release it.
	SharedTranscriber transcribe.Transcriber
}

// FromOptions builds a *pipeline.Pipeline from a config plus injectable
// dependencies. Callers without the build-tagged transcribe path
// (currently none — howl also has whispercpp) just pass nil for
// SharedTranscriber and let FromOptions construct one.
func FromOptions(opts Options) (*pipeline.Pipeline, error) {
	cfg := opts.Config
	setLastError := opts.SetLastError
	if setLastError == nil {
		setLastError = func(string) {}
	}
	newDF := opts.NewDeepFilter
	if newDF == nil {
		newDF = func(string) denoise.Denoiser { return denoise.NewPassthrough() }
	}

	var tr transcribe.Transcriber
	if opts.SharedTranscriber != nil {
		tr = nonClosingTranscriber{Transcriber: opts.SharedTranscriber}
	} else {
		t, err := transcribe.NewWhisperCpp(transcribe.WhisperOptions{
			ModelPath: cfg.WhisperModelPath,
			Language:  cfg.Language,
		})
		if err != nil {
			return nil, err
		}
		tr = t
	}

	provider, err := llm.ProviderByName(cfg.LLMProvider)
	if err != nil {
		_ = tr.Close()
		return nil, err
	}
	llmOpts := llm.Options{Model: cfg.LLMModel, BaseURL: cfg.LLMBaseURL}
	if provider.NeedsAPIKey {
		llmOpts.APIKey = cfg.LLMAPIKey
	}
	cleaner, err := provider.New(llmOpts)
	if err != nil {
		_ = tr.Close()
		return nil, err
	}
	dy := dict.NewFuzzy(cfg.CustomDict, 1)

	var d denoise.Denoiser
	if !cfg.DisableNoiseSuppression {
		d = newDF(cfg.DeepFilterModelPath)
	} else {
		d = denoise.NewPassthrough()
	}

	p := pipeline.New(tr, dy, cleaner)
	p.FrameStages = []audio.Stage{
		denoise.NewStage(d),
		resample.NewDecimate3(),
	}

	if cfg.TSEEnabled {
		backend, beErr := speaker.BackendByName(cfg.TSEBackend)
		if beErr != nil {
			log.Printf("[howl] build.FromOptions: TSE backend lookup failed, continuing without TSE: %v", beErr)
			setLastError("tse: " + beErr.Error())
			return p, nil
		}
		modelsDir := filepath.Dir(cfg.TSEModelPath)
		tse, tseErr := pipeline.LoadTSE(backend, cfg.TSEProfileDir, modelsDir, cfg.ONNXLibPath, cfg.TSEThresholdValue())
		if tseErr != nil {
			log.Printf("[howl] build.FromOptions: TSE load failed, continuing without TSE: %v", tseErr)
			setLastError("tse: " + tseErr.Error())
		} else if tse != nil {
			p.ChunkStages = []audio.Stage{tse}
			log.Printf("[howl] build.FromOptions: TSE loaded (profile=%s)", cfg.TSEProfileDir)
		} else {
			log.Printf("[howl] build.FromOptions: TSE enabled but no enrollment found at %s", cfg.TSEProfileDir)
		}
	}
	return p, nil
}

// nonClosingTranscriber adapts a Transcriber so the pipeline's Close()
// doesn't release the shared instance — the caller (replay.Run) manages
// its lifetime so it can be reused across multiple presets.
type nonClosingTranscriber struct {
	transcribe.Transcriber
}

func (n nonClosingTranscriber) Close() error { return nil }
