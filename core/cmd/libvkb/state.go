//go:build whispercpp

package main

import (
	"context"
	"log"
	"path/filepath"
	"sync"

	"github.com/voice-keyboard/core/internal/audio"
	"github.com/voice-keyboard/core/internal/config"
	"github.com/voice-keyboard/core/internal/denoise"
	"github.com/voice-keyboard/core/internal/dict"
	"github.com/voice-keyboard/core/internal/llm"
	"github.com/voice-keyboard/core/internal/pipeline"
	"github.com/voice-keyboard/core/internal/recorder"
	"github.com/voice-keyboard/core/internal/resample"
	"github.com/voice-keyboard/core/internal/sessions"
	"github.com/voice-keyboard/core/internal/speaker"
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

	// sessions stores captured per-dictation folders under
	// /tmp/voicekeyboard/sessions/. Initialized once in vkb_init;
	// the Pipeline tab + C ABI exports read from this Store.
	sessions *sessions.Store

	// activeSessionID + activeSessionDir hold the currently-recording
	// session metadata between vkb_start_capture (where the recorder
	// is constructed) and the capture goroutine's defer (where the
	// session.json manifest is written).
	activeSessionID  string
	activeSessionDir string
	// activeRecorder is the recorder.Session for the currently in-flight
	// capture. nil between captures. Set by openSessionRecorder (called
	// from vkb_start_capture); the capture goroutine's defer Closes it
	// and nils it out after the manifest write.
	activeRecorder *recorder.Session

	// pushCh is the audio frame channel for the current capture cycle.
	// vkb_push_audio sends into it; the pipeline goroutine drains it;
	// vkb_stop_capture closes it to signal end-of-input. Nil between
	// cycles. dropCount counts vkb_push_audio invocations that found a
	// full channel (used to issue at most one warning event per cycle).
	pushCh    chan []float32
	dropCount int
	pushCount int

	cancel context.CancelFunc

	events chan event

	lastErr string
}

// event is the JSON payload emitted via vkb_poll_event. Kind values:
//
//	"chunk"     — streaming LLM text delta in Text; emitted repeatedly
//	              during cleanup so the host can type at the cursor as
//	              tokens arrive. The full cleaned text is the
//	              concatenation of every chunk in order.
//	"result"    — final cleaned text in Text. When chunks were streamed,
//	              this is just a state-transition marker (text equals
//	              the concatenation of chunks).
//	"warning"   — non-fatal degradation (e.g. LLM failure); Msg has detail,
//	              and a "result" event with the dict-corrected fallback
//	              text is emitted alongside it
//	"error"     — terminal failure for this capture cycle; Msg has detail
//	"cancelled" — the in-flight pipeline was cancelled by vkb_cancel_capture
//	              before producing a result. No "result" event follows.
//	"level"     — periodic RMS level (~30 Hz), RMS field carries the value
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
//
// buildPipeline does NOT construct the per-dictation session recorder —
// that's done by openSessionRecorder, called per vkb_start_capture, so
// each dictation gets its own session folder.
func (e *engine) buildPipeline() (*pipeline.Pipeline, error) {
	tr, err := transcribe.NewWhisperCpp(transcribe.WhisperOptions{
		ModelPath: e.cfg.WhisperModelPath,
		Language:  e.cfg.Language,
	})
	if err != nil {
		return nil, err
	}
	provider, err := llm.ProviderByName(e.cfg.LLMProvider)
	if err != nil {
		_ = tr.Close()
		return nil, err
	}
	// Mirror vkb-cli/pipe.go's gating: only forward the configured API
	// key to providers that declare they need one. Defense-in-depth —
	// today's only NeedsAPIKey=false provider (Ollama) ignores the
	// field anyway, but a future "self-hosted gateway with optional
	// bearer token" provider could otherwise silently leak the user's
	// Anthropic key. The Swift layer also empties LLMAPIKey when the
	// active provider isn't Anthropic, so this is belt-and-braces.
	opts := llm.Options{
		Model:   e.cfg.LLMModel,
		BaseURL: e.cfg.LLMBaseURL,
	}
	if provider.NeedsAPIKey {
		opts.APIKey = e.cfg.LLMAPIKey
	}
	cleaner, err := provider.New(opts)
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

	p := pipeline.New(tr, dy, cleaner)
	p.FrameStages = []audio.Stage{
		denoise.NewStage(d),
		resample.NewDecimate3(),
	}

	if e.cfg.TSEEnabled {
		backend, beErr := speaker.BackendByName(e.cfg.TSEBackend)
		if beErr != nil {
			// Same policy as tseErr below: don't fail the whole configure;
			// surface via vkb_last_error and run without TSE.
			log.Printf("[vkb] buildPipeline: TSE backend lookup failed, continuing without TSE: %v", beErr)
			e.setLastError("tse: " + beErr.Error())
			return p, nil
		}
		// TSEModelPath is the back-compat per-file path; we use its parent
		// directory as the modelsDir and let the backend resolve filenames.
		modelsDir := filepath.Dir(e.cfg.TSEModelPath)
		tse, tseErr := pipeline.LoadTSE(
			backend,
			e.cfg.TSEProfileDir,
			modelsDir,
			e.cfg.ONNXLibPath,
			e.cfg.TSEThresholdValue(),
		)
		if tseErr != nil {
			log.Printf("[vkb] buildPipeline: TSE load failed, continuing without TSE: %v", tseErr)
			// Note: we deliberately don't fail the whole configure call.
			// User keeps a working pipeline; the warning surfaces via
			// vkb_last_error and the next configure attempt can fix it.
			e.setLastError("tse: " + tseErr.Error())
		} else if tse != nil {
			p.ChunkStages = []audio.Stage{tse}
			log.Printf("[vkb] buildPipeline: TSE loaded (profile=%s)", e.cfg.TSEProfileDir)
		} else {
			log.Printf("[vkb] buildPipeline: TSE enabled but no enrollment found at %s", e.cfg.TSEProfileDir)
		}
	}

	return p, nil
}
