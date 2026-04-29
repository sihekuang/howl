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

func (e *engine) buildPipeline() error {
	tr, err := transcribe.NewWhisperCpp(transcribe.WhisperOptions{
		ModelPath: e.cfg.WhisperModelPath,
		Language:  e.cfg.Language,
	})
	if err != nil {
		return err
	}
	cleaner := llm.NewAnthropic(llm.AnthropicOptions{
		APIKey: e.cfg.LLMAPIKey,
		Model:  e.cfg.LLMModel,
	})
	dy := dict.NewFuzzy(e.cfg.CustomDict, 1)

	var d denoise.Denoiser
	if e.cfg.NoiseSuppression {
		d = newDeepFilterOrPassthrough(e.cfg.DeepFilterModelPath)
	} else {
		d = denoise.NewPassthrough()
	}

	cap := audio.NewMalgoCapture()
	e.pipeline = pipeline.New(cap, d, tr, dy, cleaner)
	return nil
}
