package main

import (
	"context"
	"sync"

	"github.com/voice-keyboard/core/internal/audio"
	"github.com/voice-keyboard/core/internal/config"
	"github.com/voice-keyboard/core/internal/denoise"
	"github.com/voice-keyboard/core/internal/dict"
	"github.com/voice-keyboard/core/internal/llm"
	"github.com/voice-keyboard/core/internal/pipeline"
	"github.com/voice-keyboard/core/internal/transcribe"
)

type engine struct {
	mu       sync.Mutex
	cfg      config.Config
	pipeline *pipeline.Pipeline

	stopCh chan struct{}
	cancel context.CancelFunc

	events chan event

	lastErr string
}

type event struct {
	Kind string  `json:"kind"` // "level" | "result" | "error"
	RMS  float32 `json:"rms,omitempty"`
	Text string  `json:"text,omitempty"`
	Msg  string  `json:"msg,omitempty"`
}

var (
	gMu     sync.Mutex
	gEngine *engine
)

func getEngine() *engine {
	gMu.Lock()
	defer gMu.Unlock()
	return gEngine
}

func setEngine(e *engine) {
	gMu.Lock()
	defer gMu.Unlock()
	gEngine = e
}

func (e *engine) setLastError(msg string) {
	e.mu.Lock()
	e.lastErr = msg
	e.mu.Unlock()
}

// buildPipeline assembles a fresh *pipeline.Pipeline from e.cfg without
// mutating engine state. The caller is responsible for assigning the
// returned pipeline to e.pipeline under e.mu. This avoids a TSAN-visible
// race between vkb_configure (writer) and vkb_start_capture (reader).
func (e *engine) buildPipeline() (*pipeline.Pipeline, error) {
	tr, err := transcribe.NewWhisperCpp(transcribe.WhisperOptions{
		ModelPath: e.cfg.WhisperModelPath,
		Language:  e.cfg.Language,
	})
	if err != nil {
		return nil, err
	}
	cleaner := llm.NewAnthropic(llm.AnthropicOptions{
		APIKey: e.cfg.LLMAPIKey,
		Model:  e.cfg.LLMModel,
	})
	dy := dict.NewFuzzy(e.cfg.CustomDict, 1)

	var d denoise.Denoiser
	if !e.cfg.DisableNoiseSuppression {
		d = newDeepFilterOrPassthrough(e.cfg.DeepFilterModelPath)
	} else {
		d = denoise.NewPassthrough()
	}

	cap := audio.NewMalgoCapture()
	return pipeline.New(cap, d, tr, dy, cleaner), nil
}
