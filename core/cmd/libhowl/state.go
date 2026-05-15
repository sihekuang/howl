//go:build whispercpp

package main

import (
	"context"
	"sync"
	"time"

	"github.com/voice-keyboard/core/internal/config"
	"github.com/voice-keyboard/core/internal/pipeline"
	pipelinebuild "github.com/voice-keyboard/core/internal/pipeline/build"
	"github.com/voice-keyboard/core/internal/recorder"
	"github.com/voice-keyboard/core/internal/sessions"
)

// pushBufferFrames bounds the audio push channel. At 48kHz/480-sample
// frames that's ~10ms per frame, so 200 frames = ~2s of audio. If the
// pipeline ever falls behind, howl_push_audio drops with a warning event
// rather than blocking the audio thread.
const pushBufferFrames = 200

type engine struct {
	mu       sync.Mutex
	cfg      config.Config
	pipeline *pipeline.Pipeline

	// sessions stores captured per-dictation folders under
	// /tmp/voicekeyboard/sessions/. Initialized once in howl_init;
	// the Pipeline tab + C ABI exports read from this Store.
	sessions *sessions.Store

	// activeSessionID + activeSessionDir hold the currently-recording
	// session metadata between howl_start_capture (where the recorder
	// is constructed) and the capture goroutine's defer (where the
	// session.json manifest is written).
	activeSessionID  string
	activeSessionDir string
	// activeRecorder is the recorder.Session for the currently in-flight
	// capture. nil between captures. Set by openSessionRecorder (called
	// from howl_start_capture); the capture goroutine's defer Closes it
	// and nils it out after the manifest write.
	activeRecorder *recorder.Session

	// pushCh is the audio frame channel for the current capture cycle.
	// howl_push_audio sends into it; the pipeline goroutine drains it;
	// howl_stop_capture closes it to signal end-of-input. Nil between
	// cycles. dropCount counts howl_push_audio invocations that found a
	// full channel (used to issue at most one warning event per cycle).
	pushCh    chan []float32
	dropCount int
	pushCount int

	// cancel aborts the in-flight pipeline as a user-driven cancel
	// (howl_cancel_capture). cancelWithCause is the underlying
	// cause-aware cancel — used by the post-stop watchdog timer so the
	// goroutine can tell timer-fired from user-fired cancellation via
	// context.Cause(ctx). Both nil between cycles.
	cancel          context.CancelFunc
	cancelWithCause context.CancelCauseFunc

	// timeoutAfterStop is copied from cfg.PipelineTimeoutValue() at
	// howl_start_capture. 0 disables the watchdog. The recording phase
	// itself is unbounded — the timer doesn't start until
	// howl_stop_capture, so it covers only Whisper drain + LLM cleanup,
	// where stage hangs actually happen.
	timeoutAfterStop time.Duration
	// stopTimer is the post-stop watchdog. Started by howl_stop_capture
	// when timeoutAfterStop > 0; stopped by the goroutine's defer on
	// normal exit and by howl_cancel_capture on user cancel.
	stopTimer *time.Timer

	events chan event

	lastErr string
}

// event is the JSON payload emitted via howl_poll_event. Kind values:
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
//	"cancelled" — the in-flight pipeline was cancelled by howl_cancel_capture
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
// race between howl_configure (writer) and howl_start_capture (reader).
//
// buildPipeline does NOT construct the per-dictation session recorder —
// that's done by openSessionRecorder, called per howl_start_capture, so
// each dictation gets its own session folder.
func (e *engine) buildPipeline() (*pipeline.Pipeline, error) {
	return pipelinebuild.FromOptions(pipelinebuild.Options{
		Config:        e.cfg,
		NewDeepFilter: newDeepFilterOrPassthrough,
		SetLastError:  func(msg string) { e.setLastError(msg) },
	})
}
