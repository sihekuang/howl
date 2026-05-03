//go:build whispercpp

package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"os"
	"sync"
	"time"
	"unsafe"

	"github.com/voice-keyboard/core/internal/config"
	"github.com/voice-keyboard/core/internal/pipeline"
	"github.com/voice-keyboard/core/internal/sessions"
)

// Mirror Go logs to /tmp/vkb.log so the user can `tail -f` regardless of
// how the app was launched (stderr is invisible when launched from
// Finder / LaunchServices). Best-effort: if file open fails, just keep
// stderr.
func init() {
	if f, err := os.OpenFile("/tmp/vkb.log", os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0644); err == nil {
		log.SetOutput(io.MultiWriter(os.Stderr, f))
	}
	log.SetFlags(log.LstdFlags | log.Lmicroseconds)
	log.Printf("[vkb] libvkb loaded pid=%d", os.Getpid())
}

// vkb_init initializes the engine. Idempotent: calling it again on an
// already-initialized engine is a no-op and returns 0.
//
//export vkb_init
func vkb_init() C.int {
	if getEngine() != nil {
		return 0
	}
	setEngine(&engine{
		events:   make(chan event, 32),
		sessions: sessions.NewStore("/tmp/voicekeyboard/sessions"),
	})
	return 0
}

// vkb_configure parses a JSON-encoded Config and rebuilds the pipeline.
// Returns 0 on success. Non-zero error codes:
//
//	1 = engine not initialized
//	2 = JSON parse error
//	3 = pipeline build error
//	4 = busy: a capture is currently in flight
//
// On any non-zero return, vkb_last_error provides a human-readable
// message (which the caller must free via vkb_free_string).
//
//export vkb_configure
func vkb_configure(jsonC *C.char) C.int {
	e := getEngine()
	if e == nil {
		return 1
	}
	gostr := C.GoString(jsonC)
	var cfg config.Config
	if err := json.Unmarshal([]byte(gostr), &cfg); err != nil {
		e.setLastError("vkb_configure: " + err.Error())
		return 2
	}
	config.WithDefaults(&cfg)

	e.mu.Lock()
	if e.pushCh != nil {
		e.mu.Unlock()
		e.setLastError("vkb_configure: cannot reconfigure while a capture is in flight")
		return 4
	}
	e.cfg = cfg
	e.mu.Unlock()

	// Build the new pipeline first; if it fails, the old one stays in place.
	p, err := e.buildPipeline()
	if err != nil {
		e.setLastError("vkb_configure: " + err.Error())
		return 3
	}
	e.mu.Lock()
	oldPipe := e.pipeline
	e.pipeline = p
	e.mu.Unlock()
	if oldPipe != nil {
		_ = oldPipe.Close()
	}
	return 0
}

// vkb_start_capture begins a single-utterance push-driven capture
// cycle. Returns 0 on successful start, 1 if the engine is not
// initialized or has no pipeline configured, and 2 if a capture is
// already in flight. The host (Swift app or vkb-cli) is then expected
// to feed Float32 mono 48 kHz frames via vkb_push_audio and call
// vkb_stop_capture to signal end-of-input. Result/error events are
// delivered asynchronously via vkb_poll_event.
//
//export vkb_start_capture
func vkb_start_capture() C.int {
	e := getEngine()
	if e == nil {
		return 1
	}
	log.Printf("[vkb] vkb_start_capture: entering")
	e.mu.Lock()
	if e.pipeline == nil {
		e.mu.Unlock()
		log.Printf("[vkb] vkb_start_capture: REJECTED — pipeline is nil")
		return 1
	}
	if e.pushCh != nil {
		e.mu.Unlock()
		log.Printf("[vkb] vkb_start_capture: REJECTED — capture already in flight")
		return 2
	}
	pushCh := make(chan []float32, pushBufferFrames)
	ctx, cancel := context.WithCancel(context.Background())
	pipe := e.pipeline
	e.pushCh = pushCh
	e.cancel = cancel
	e.dropCount = 0
	e.mu.Unlock()

	// Throttle level events to ~30Hz, taking max RMS in each window.
	// Stream LLM cleaned-text deltas to Swift as they arrive via EventLLMDelta.
	const levelHz = 30
	levelInterval := time.Second / levelHz
	var (
		levelMu     sync.Mutex
		levelMax    float32
		levelLastAt = time.Now()
	)
	pipe.Listener = func(ev pipeline.Event) {
		switch ev.Kind {
		case pipeline.EventStageProcessed:
			if ev.Stage != "denoise" {
				return
			}
			levelMu.Lock()
			defer levelMu.Unlock()
			now := time.Now()
			if ev.RMSOut > levelMax {
				levelMax = ev.RMSOut
			}
			if now.Sub(levelLastAt) < levelInterval {
				return
			}
			select {
			case e.events <- event{Kind: "level", RMS: levelMax}:
			default:
			}
			levelMax = 0
			levelLastAt = now
		case pipeline.EventLLMDelta:
			// Each chunk becomes an event{Kind: "chunk", Text: "..."}; Swift types
			// them at the cursor incrementally. Terminal `result` event is
			// still emitted at the end with the full cleaned text (Swift can
			// ignore the text since it's already typed, but the event signals
			// state transition idle ← processing).
			if ev.Text == "" {
				return
			}
			e.events <- event{Kind: "chunk", Text: ev.Text}
		}
	}

	go func() {
		log.Printf("[vkb] capture goroutine: started")
		defer func() {
			if r := recover(); r != nil {
				msg := fmt.Sprintf("panic: %v", r)
				log.Printf("[vkb] capture goroutine: PANIC %s", msg)
				e.events <- event{Kind: "error", Msg: msg}
			}
			// Snapshot session metadata under the lock so we don't race with
			// a concurrent vkb_configure swapping it out.
			e.mu.Lock()
			sessionID := e.activeSessionID
			sessionDir := e.activeSessionDir
			e.activeSessionID = ""
			e.activeSessionDir = ""
			e.pushCh = nil
			e.cancel = nil
			drops := e.dropCount
			pushes := e.pushCount
			e.dropCount = 0
			e.pushCount = 0
			tseEnabled := e.cfg.TSEEnabled // read in the same critical section as session metadata
			e.mu.Unlock()

			// Write session.json — best-effort. A missing manifest just makes
			// the session invisible to the Inspector; the WAVs still exist on
			// disk for ad-hoc inspection.
			if sessionID != "" && sessionDir != "" {
				m := sessions.Manifest{
					Version:     sessions.CurrentManifestVersion,
					ID:          sessionID,
					Preset:      "default", // populated correctly once Slice 2 lands the presets package
					DurationSec: 0,         // TODO: pipeline-side accounting in Slice 4 (replay needs precise duration)
					Stages: []sessions.StageEntry{
						{Name: "denoise", Kind: "frame", WavRel: "denoise.wav", RateHz: 48000},
						{Name: "decimate3", Kind: "frame", WavRel: "decimate3.wav", RateHz: 16000},
					},
					Transcripts: sessions.TranscriptEntries{
						Raw: "raw.txt", Dict: "dict.txt", Cleaned: "cleaned.txt",
					},
				}
				// Add tse stage entry iff it was registered.
				if tseEnabled {
					m.Stages = append(m.Stages, sessions.StageEntry{
						Name: "tse", Kind: "chunk", WavRel: "tse.wav", RateHz: 16000,
					})
				}
				if err := m.Write(sessionDir); err != nil {
					log.Printf("[vkb] capture goroutine: manifest write failed: %v", err)
				} else {
					log.Printf("[vkb] capture goroutine: wrote manifest %s/session.json", sessionDir)
				}
			}

			log.Printf("[vkb] capture goroutine: exited (pushes=%d drops=%d)", pushes, drops)
		}()
		res, err := pipe.Run(ctx, pushCh)
		// Terminal events (error/warning/result) MUST NOT be dropped:
		// if they are, Swift sits forever in `processing`. We accept
		// blocking here — by the time we're stopping, level emission
		// is over and the channel will drain quickly.
		if err != nil {
			if errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) {
				log.Printf("[vkb] capture goroutine: pipeline cancelled")
				e.events <- event{Kind: "cancelled"}
				return
			}
			log.Printf("[vkb] capture goroutine: pipe.Run error: %v", err)
			e.events <- event{Kind: "error", Msg: err.Error()}
			return
		}
		if res.LLMError != nil {
			log.Printf("[vkb] capture goroutine: emitting warning + fallback result")
			e.events <- event{Kind: "warning", Msg: "llm: " + res.LLMError.Error()}
		}
		log.Printf("[vkb] capture goroutine: emitting result (len=%d)", len(res.Cleaned))
		e.events <- event{Kind: "result", Text: res.Cleaned}
		log.Printf("[vkb] capture goroutine: result event delivered")
	}()
	return 0
}

// vkb_push_audio enqueues a chunk of Float32 mono 48 kHz audio for the
// in-flight capture. Non-blocking: if the internal buffer is full the
// frame is dropped and a single "audio buffer full, dropping frames"
// warning is emitted per cycle (audio threads must not block).
//
// Returns:
//
//	0 = enqueued (or dropped, but see warning event)
//	1 = engine not initialized
//	2 = no capture in flight (must call vkb_start_capture first)
//
//export vkb_push_audio
func vkb_push_audio(samples *C.float, count C.int) C.int {
	e := getEngine()
	if e == nil {
		return 1
	}
	if count <= 0 {
		return 0
	}
	e.mu.Lock()
	pushCh := e.pushCh
	e.mu.Unlock()
	if pushCh == nil {
		return 2
	}

	// Copy out of the C buffer into Go memory before sending — the
	// caller may reuse their buffer immediately on return.
	n := int(count)
	cSlice := unsafe.Slice(samples, n)
	frame := make([]float32, n)
	for i := 0; i < n; i++ {
		frame[i] = float32(cSlice[i])
	}

	select {
	case pushCh <- frame:
		// Heartbeat: log every ~30 successful pushes so we can confirm
		// audio is actually flowing into Go.
		e.mu.Lock()
		e.pushCount++
		pc := e.pushCount
		e.mu.Unlock()
		if pc%30 == 1 {
			log.Printf("[vkb] push_audio: heartbeat n=%d total=%d", n, pc)
		}
	default:
		e.mu.Lock()
		e.dropCount++
		first := e.dropCount == 1
		e.mu.Unlock()
		if first {
			select {
			case e.events <- event{Kind: "warning", Msg: "audio buffer full, dropping frames"}:
			default:
			}
		}
	}
	return 0
}

// vkb_stop_capture signals end-of-input for the in-flight capture by
// closing the audio push channel. The pipeline goroutine drains
// remaining frames, runs transcribe/clean, and emits a result event.
// Idempotent: safe to call when no capture is active. Returns 1 if
// the engine is not initialized.
//
//export vkb_stop_capture
func vkb_stop_capture() C.int {
	e := getEngine()
	if e == nil {
		return 1
	}
	e.mu.Lock()
	defer e.mu.Unlock()
	log.Printf("[vkb] vkb_stop_capture: closing push channel")
	if e.pushCh != nil {
		close(e.pushCh)
		e.pushCh = nil
	}
	if e.cancel != nil {
		e.cancel = nil
	}
	return 0
}

// vkb_cancel_capture aborts the in-flight capture, drops any buffered
// audio, and emits a "cancelled" event instead of a "result". Idempotent:
// safe to call when no capture is active. Returns 1 if the engine is
// not initialized, 0 otherwise.
//
//export vkb_cancel_capture
func vkb_cancel_capture() C.int {
	e := getEngine()
	if e == nil {
		return 1
	}
	e.mu.Lock()
	cancel := e.cancel
	if e.pushCh != nil {
		close(e.pushCh)
		e.pushCh = nil
	}
	e.cancel = nil
	e.mu.Unlock()
	if cancel != nil {
		log.Printf("[vkb] vkb_cancel_capture: cancelling in-flight pipeline")
		cancel()
	}
	return 0
}

// vkb_poll_event returns a JSON-encoded event string, or NULL if no
// event is queued. The returned string is heap-allocated; the caller
// must free it via vkb_free_string.
//
//export vkb_poll_event
func vkb_poll_event() *C.char {
	e := getEngine()
	if e == nil {
		return nil
	}
	select {
	case ev := <-e.events:
		buf, err := json.Marshal(ev)
		if err != nil {
			return nil
		}
		return C.CString(string(buf))
	default:
		return nil
	}
}

// vkb_destroy tears down the engine. Idempotent: calling on an
// already-destroyed engine is a no-op.
//
//export vkb_destroy
func vkb_destroy() {
	e := getEngine()
	if e == nil {
		return
	}
	_ = vkb_stop_capture()
	e.mu.Lock()
	pipe := e.pipeline
	e.pipeline = nil
	e.mu.Unlock()
	if pipe != nil {
		_ = pipe.Close()
	}
	setEngine(nil)
}

// vkb_last_error returns the last error message as a C string, or NULL
// if no error is set. The returned string is heap-allocated; the caller
// must free it via vkb_free_string.
//
//export vkb_last_error
func vkb_last_error() *C.char {
	e := getEngine()
	if e == nil {
		return nil
	}
	e.mu.Lock()
	defer e.mu.Unlock()
	if e.lastErr == "" {
		return nil
	}
	return C.CString(e.lastErr)
}

// vkb_free_string frees a C string previously returned by
// vkb_poll_event or vkb_last_error. Passing NULL is a no-op.
//
//export vkb_free_string
func vkb_free_string(s *C.char) {
	if s != nil {
		C.free(unsafe.Pointer(s))
	}
}

// vkb_enroll_compute computes a speaker embedding from a single recorded
// buffer and writes enrollment.wav, enrollment.emb, and speaker.json
// atomically to profileDir.
//
// samples:    Float32 mono PCM (must not be NULL)
// count:      number of samples (must be > 0)
// sampleRate: must be 48000
// profileDir: NUL-terminated UTF-8 path
//
// Not safe to call concurrently against the same profileDir.
// The host (Swift app) is responsible for serializing.
//
// Return codes:
//
//	0 = success
//	1 = engine not initialized
//	5 = invalid argument (count <= 0, profileDir empty, sr != 48000,
//	    speaker_encoder_path / onnx_lib_path not configured)
//	6 = compute failed (see vkb_last_error)
//
//export vkb_enroll_compute
func vkb_enroll_compute(samples *C.float, count C.int, sampleRate C.int, profileDirC *C.char) C.int {
	e := getEngine()
	if e == nil {
		return 1
	}
	if count <= 0 || sampleRate != 48000 || profileDirC == nil {
		e.setLastError("vkb_enroll_compute: invalid argument")
		return 5
	}
	profileDir := C.GoString(profileDirC)
	if profileDir == "" {
		e.setLastError("vkb_enroll_compute: empty profile dir")
		return 5
	}

	e.mu.Lock()
	encoderPath := e.cfg.SpeakerEncoderPath
	onnxLibPath := e.cfg.ONNXLibPath
	e.mu.Unlock()
	if encoderPath == "" || onnxLibPath == "" {
		e.setLastError("vkb_enroll_compute: speaker_encoder_path or onnx_lib_path not configured")
		return 5
	}

	// Copy out of C memory before any Go-side work.
	n := int(count)
	cSlice := unsafe.Slice(samples, n)
	buf := make([]float32, n)
	for i := 0; i < n; i++ {
		buf[i] = float32(cSlice[i])
	}

	log.Printf("[vkb] vkb_enroll_compute: count=%d sr=%d profileDir=%q", n, int(sampleRate), profileDir)
	if err := runEnrollCompute(buf, profileDir, encoderPath, onnxLibPath); err != nil {
		e.setLastError("vkb_enroll_compute: " + err.Error())
		log.Printf("[vkb] vkb_enroll_compute: FAILED %v", err)
		return 6
	}
	log.Printf("[vkb] vkb_enroll_compute: success")
	return 0
}

// vkb_list_sessions returns a JSON array of session manifests, newest
// first. Returns NULL on engine-not-initialized; an empty array "[]"
// on no sessions. The returned C string is heap-allocated; the caller
// must free it via vkb_free_string.
//
//export vkb_list_sessions
func vkb_list_sessions() *C.char {
	e := getEngine()
	if e == nil || e.sessions == nil {
		return nil
	}
	manifests, err := e.sessions.List()
	if err != nil {
		e.setLastError("vkb_list_sessions: " + err.Error())
		return nil
	}
	if manifests == nil {
		manifests = []sessions.Manifest{}
	}
	buf, err := json.Marshal(manifests)
	if err != nil {
		e.setLastError("vkb_list_sessions: marshal: " + err.Error())
		return nil
	}
	return C.CString(string(buf))
}

// vkb_get_session returns a JSON-encoded Manifest for the given id, or
// NULL if the session does not exist or its manifest is unreadable.
// Caller frees via vkb_free_string.
//
//export vkb_get_session
func vkb_get_session(idC *C.char) *C.char {
	e := getEngine()
	if e == nil || e.sessions == nil {
		return nil
	}
	id := C.GoString(idC)
	m, err := e.sessions.Get(id)
	if err != nil {
		e.setLastError("vkb_get_session: " + err.Error())
		return nil
	}
	buf, err := json.Marshal(m)
	if err != nil {
		e.setLastError("vkb_get_session: marshal: " + err.Error())
		return nil
	}
	return C.CString(string(buf))
}

// vkb_delete_session removes a single session folder. Idempotent.
// Returns 0 on success, 1 if the engine is not initialized, 5 on
// invalid id (path traversal etc.), 6 on filesystem error.
//
//export vkb_delete_session
func vkb_delete_session(idC *C.char) C.int {
	e := getEngine()
	if e == nil || e.sessions == nil {
		return 1
	}
	id := C.GoString(idC)
	if err := e.sessions.Delete(id); err != nil {
		e.setLastError("vkb_delete_session: " + err.Error())
		// Distinguish bad-id (validation) from disk error.
		if errors.Is(err, sessions.ErrInvalidSessionID) {
			return 5
		}
		return 6
	}
	return 0
}

// vkb_clear_sessions removes every session folder. Returns 0 on
// success, 1 if engine not initialized, 6 on filesystem error.
//
//export vkb_clear_sessions
func vkb_clear_sessions() C.int {
	e := getEngine()
	if e == nil || e.sessions == nil {
		return 1
	}
	if err := e.sessions.Clear(); err != nil {
		e.setLastError("vkb_clear_sessions: " + err.Error())
		return 6
	}
	return 0
}
