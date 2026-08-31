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
// (currently none — howl-cli also has whispercpp) just pass nil for
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
			// Bias whisper toward the user's custom vocabulary so the
			// dictionary helps recognition, not just post-correction.
			InitialPrompt: transcribe.DictionaryPrompt(cfg.CustomDict),
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
	llmOpts := llm.Options{Model: cfg.LLMModel, BaseURL: cfg.LLMBaseURL, Prompt: cfg.LLMPrompt}
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
	p.Prompt = cfg.LLMPrompt
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

// SetContextPrompt forwards to the wrapped transcriber when it supports
// re-biasing, returning what the wrapped call returns — the screen
// terms that actually survived trimming. Returns nil when the wrapped
// transcriber does not implement PromptSetter, so a caller stamping the
// return value into a session manifest never records terms as applied
// when nothing was actually re-biased.
//
// Unreachable today — not fixing a live bug. nonClosingTranscriber is
// only constructed on the replay path (replay.Run, via
// SharedTranscriber), and nothing on that path calls SetContextPrompt.
// The only caller of SetContextPrompt is howl_start_capture, which
// always operates on the live, unwrapped pipeline (buildPipeline never
// sets SharedTranscriber). Kept anyway as defensive plumbing: without
// this override, embedding transcribe.Transcriber (an interface) only
// promotes methods THAT interface declares, so a future
// pipe.Transcriber.(transcribe.PromptSetter) assertion on a
// replay-built pipeline would silently fail even when the WRAPPED
// concrete transcriber implements PromptSetter. This method exists so
// that trap isn't waiting for whoever adds such a caller later.
func (n nonClosingTranscriber) SetContextPrompt(dictTerms, screenTerms []string) []string {
	if ps, ok := n.Transcriber.(transcribe.PromptSetter); ok {
		return ps.SetContextPrompt(dictTerms, screenTerms)
	}
	return nil
}

// PreviewContextPrompt forwards to the wrapped transcriber when it
// supports re-biasing. Explicit for the same reason SetContextPrompt
// above is: embedding transcribe.Transcriber (an interface) promotes
// only the methods THAT interface declares, so without this the
// PromptSetter assertion would fail on a replay-built pipeline even
// when the wrapped concrete transcriber implements it.
//
// The zero plan returned when the wrapped transcriber is not a
// PromptSetter still carries the caps: they are compile-time constants,
// and a diagnostic reporting a budget of 0 tokens would be a worse lie
// than reporting an empty prompt against the real budget.
func (n nonClosingTranscriber) PreviewContextPrompt(dictTerms, screenTerms []string) transcribe.ContextPromptPlan {
	if ps, ok := n.Transcriber.(transcribe.PromptSetter); ok {
		return ps.PreviewContextPrompt(dictTerms, screenTerms)
	}
	return transcribe.ContextPromptPlan{
		MaxScreenPromptTokens: transcribe.MaxScreenPromptTokens,
		MaxPromptTokens:       transcribe.MaxPromptTokens,
	}
}
