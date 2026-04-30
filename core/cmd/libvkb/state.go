package main

import (
	"context"
	"sync"

	"github.com/voice-keyboard/core/internal/config"
	"github.com/voice-keyboard/core/internal/denoise"
	"github.com/voice-keyboard/core/internal/dict"
	"github.com/voice-keyboard/core/internal/llm"
	"github.com/voice-keyboard/core/internal/pipeline"
	"github.com/voice-keyboard/core/internal/transcribe"
)

// pushBufferFrames bounds the audio push channel. At 48kHz/480-sample
// frames that's ~10ms per frame, so 200 frames = ~2s of audio. If the
// pipeline ever falls behind, vkb_push_audio drops with a warning event
// rather than blocking the audio thread.
const pushBufferFrames = 200

type engine struct {
	mu       sync.Mutex
	cfg      config.Config
	pipeline *pipeline.Pipeline

	// pushCh is the audio frame channel for the current capture cycle.
	// vkb_push_audio sends into it; the pipeline goroutine drains it;
	// vkb_stop_capture closes it to signal end-of-input. Nil between
	// cycles. dropCount counts vkb_push_audio invocations that found a
	// full channel (used to issue at most one warning event per cycle).
	pushCh    chan []float32
	dropCount int

	cancel context.CancelFunc

	events chan event

	lastErr string
}

// event is the JSON payload emitted via vkb_poll_event. Kind values:
//
//	"result"  — final cleaned text in Text
//	"warning" — non-fatal degradation (e.g. LLM failure); Msg has detail,
//	            and a "result" event with the dict-corrected fallback
//	            text is emitted alongside it
//	"error"   — terminal failure for this capture cycle; Msg has detail
//	"level"   — periodic RMS level (~30 Hz), RMS field carries the value
type event struct {
	Kind string  `json:"kind"`
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
	cleaner, err := llm.NewAnthropic(llm.AnthropicOptions{
		APIKey: e.cfg.LLMAPIKey,
		Model:  e.cfg.LLMModel,
	})
	if err != nil {
		_ = tr.Close()
		return nil, err
	}
	dy := dict.NewFuzzy(e.cfg.CustomDict, 1)

	var d denoise.Denoiser
	if !e.cfg.DisableNoiseSuppression {
		d = newDeepFilterOrPassthrough(e.cfg.DeepFilterModelPath)
	} else {
		d = denoise.NewPassthrough()
	}

	// Audio capture is no longer the core's responsibility: the host
	// (Swift app via vkb_push_audio, or vkb-cli via direct Go API)
	// pushes frames in.
	return pipeline.New(d, tr, dy, cleaner), nil
}
