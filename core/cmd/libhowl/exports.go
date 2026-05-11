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
	"github.com/voice-keyboard/core/internal/presets"
	"github.com/voice-keyboard/core/internal/recorder"
	"github.com/voice-keyboard/core/internal/sessions"
)

// openSessionRecorder constructs a recorder.Session for the next capture
// cycle when DeveloperMode is on. Called from howl_start_capture before
// the capture goroutine is launched, so the engine is single-threaded
// at this point and lock-free access to e.cfg / e.sessions is fine.
// The capture goroutine's defer reads e.activeRecorder, writes the
// manifest, then closes + nils it.
//
// All errors are non-fatal — capture proceeds without recording if the
// session can't be opened. Returns the error only so tests can assert
// on it; callers should log and continue.
func openSessionRecorder(e *engine) error {
	if !e.cfg.DeveloperMode || e.sessions == nil {
		return nil
	}
	if err := e.sessions.Prune(10); err != nil {
		log.Printf("[howl] openSessionRecorder: prune failed (continuing): %v", err)
	}
	id := time.Now().UTC().Format("2006-01-02T15:04:05.000000000Z")
	dir := e.sessions.SessionDir(id)
	rec, err := recorder.Open(recorder.Options{
		Dir:         dir,
		AudioStages: true,
		Transcripts: true,
	})
	if err != nil {
		log.Printf("[howl] openSessionRecorder: recorder.Open failed (continuing without capture): %v", err)
		return err
	}
	e.activeSessionID = id
	e.activeSessionDir = dir
	e.activeRecorder = rec
	return nil
}

// Mirror Go logs to /tmp/howl.log so the user can `tail -f` regardless of
// how the app was launched (stderr is invisible when launched from
// Finder / LaunchServices). Best-effort: if file open fails, just keep
// stderr.
func init() {
	if f, err := os.OpenFile("/tmp/howl.log", os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0644); err == nil {
		log.SetOutput(io.MultiWriter(os.Stderr, f))
	}
	log.SetFlags(log.LstdFlags | log.Lmicroseconds)
	log.Printf("[howl] libhowl loaded pid=%d", os.Getpid())
}

// howl_init initializes the engine. Idempotent: calling it again on an
// already-initialized engine is a no-op and returns 0.
//
//export howl_init
func howl_init() C.int {
	if getEngine() != nil {
		return 0
	}
	setEngine(&engine{
		events:   make(chan event, 32),
		sessions: sessions.NewStore("/tmp/voicekeyboard/sessions"),
	})
	return 0
}

// howl_configure parses a JSON-encoded Config and rebuilds the pipeline.
// Returns 0 on success. Non-zero error codes:
//
//	1 = engine not initialized
//	2 = JSON parse error
//	3 = pipeline build error
//	4 = busy: a capture is currently in flight
//
// On any non-zero return, howl_last_error provides a human-readable
// message (which the caller must free via howl_free_string).
//
//export howl_configure
func howl_configure(jsonC *C.char) C.int {
	e := getEngine()
	if e == nil {
		return 1
	}
	gostr := C.GoString(jsonC)
	var cfg config.Config
	if err := json.Unmarshal([]byte(gostr), &cfg); err != nil {
		e.setLastError("howl_configure: " + err.Error())
		return 2
	}
	config.WithDefaults(&cfg)

	e.mu.Lock()
	if e.pushCh != nil {
		e.mu.Unlock()
		e.setLastError("howl_configure: cannot reconfigure while a capture is in flight")
		return 4
	}
	e.cfg = cfg
	e.mu.Unlock()

	// Build the new pipeline first; if it fails, the old one stays in place.
	p, err := e.buildPipeline()
	if err != nil {
		e.setLastError("howl_configure: " + err.Error())
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

// howl_start_capture begins a single-utterance push-driven capture
// cycle. Returns 0 on successful start, 1 if the engine is not
// initialized or has no pipeline configured, and 2 if a capture is
// already in flight. The host (Swift app or howl) is then expected
// to feed Float32 mono 48 kHz frames via howl_push_audio and call
// howl_stop_capture to signal end-of-input. Result/error events are
// delivered asynchronously via howl_poll_event.
//
//export howl_start_capture
func howl_start_capture() C.int {
	e := getEngine()
	if e == nil {
		return 1
	}
	log.Printf("[howl] howl_start_capture: entering")
	e.mu.Lock()
	if e.pipeline == nil {
		e.mu.Unlock()
		log.Printf("[howl] howl_start_capture: REJECTED — pipeline is nil")
		return 1
	}
	if e.pushCh != nil {
		e.mu.Unlock()
		log.Printf("[howl] howl_start_capture: REJECTED — capture already in flight")
		return 2
	}
	pushCh := make(chan []float32, pushBufferFrames)
	ctx, cancel := context.WithCancel(context.Background())
	pipe := e.pipeline
	timeout := e.cfg.PipelineTimeoutValue()
	// Open a per-capture session recorder under DeveloperMode. Errors are
	// non-fatal; we proceed without recording in that case. Safe under
	// e.mu — no concurrent reader can observe the engine in this state.
	_ = openSessionRecorder(e)
	if e.activeRecorder != nil {
		pipe.Recorder = e.activeRecorder
	}
	e.pushCh = pushCh
	e.cancel = cancel
	e.dropCount = 0
	e.mu.Unlock()

	// Wrap ctx with the per-preset timeout. The timeout-cancel is
	// captured by the capture goroutine's defer (below) so it's always
	// cleaned up when the goroutine exits — independently of whether
	// howl_cancel_capture fired the parent cancel first.
	var cancelTimeout context.CancelFunc
	if timeout > 0 {
		ctx, cancelTimeout = context.WithTimeout(ctx, timeout)
	}

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
		log.Printf("[howl] capture goroutine: started")
		defer func() {
			if cancelTimeout != nil {
				cancelTimeout()
			}
			if r := recover(); r != nil {
				msg := fmt.Sprintf("panic: %v", r)
				log.Printf("[howl] capture goroutine: PANIC %s", msg)
				e.events <- event{Kind: "error", Msg: msg}
			}
			// Snapshot session metadata under the lock so we don't race with
			// a concurrent howl_configure swapping it out.
			e.mu.Lock()
			sessionID := e.activeSessionID
			sessionDir := e.activeSessionDir
			rec := e.activeRecorder
			e.activeSessionID = ""
			e.activeSessionDir = ""
			e.activeRecorder = nil
			e.pushCh = nil
			e.cancel = nil
			drops := e.dropCount
			pushes := e.pushCount
			e.dropCount = 0
			e.pushCount = 0
			e.mu.Unlock()

			// Write session.json — best-effort. A missing manifest just makes
			// the session invisible to the Inspector; the WAVs still exist on
			// disk for ad-hoc inspection. Delegated to pipe.WriteSessionManifest
			// so the live engine and the replay package share one writer.
			if sessionID != "" && sessionDir != "" {
				if err := pipe.WriteSessionManifest(sessionDir, sessionID, "default"); err != nil {
					log.Printf("[howl] capture goroutine: manifest write failed: %v", err)
				} else {
					log.Printf("[howl] capture goroutine: wrote manifest %s/session.json", sessionDir)
				}
			}

			// Close the recorder so WAV writers patch the data_bytes
			// header — without this, players see a header claiming 0
			// bytes of audio even though the file has plenty.
			if rec != nil {
				if err := rec.Close(); err != nil {
					log.Printf("[howl] capture goroutine: recorder.Close failed: %v", err)
				}
			}

			log.Printf("[howl] capture goroutine: exited (pushes=%d drops=%d)", pushes, drops)
		}()
		res, err := pipe.Run(ctx, pushCh)
		// Terminal events (error/warning/result) MUST NOT be dropped:
		// if they are, Swift sits forever in `processing`. We accept
		// blocking here — by the time we're stopping, level emission
		// is over and the channel will drain quickly.
		if err != nil {
			if errors.Is(err, context.DeadlineExceeded) {
				log.Printf("[howl] capture goroutine: pipeline timed out (>%s)", timeout)
				e.events <- event{Kind: "warning", Msg: fmt.Sprintf("pipeline timed out after %s", timeout)}
				// pipe.Run returns (Result{}, err) on context error, not partial
				// state. Emit an empty result so Swift transitions back to idle.
				e.events <- event{Kind: "result", Text: ""}
				return
			}
			if errors.Is(err, context.Canceled) {
				log.Printf("[howl] capture goroutine: pipeline cancelled")
				e.events <- event{Kind: "cancelled"}
				return
			}
			log.Printf("[howl] capture goroutine: pipe.Run error: %v", err)
			e.events <- event{Kind: "error", Msg: err.Error()}
			return
		}
		if res.LLMError != nil {
			log.Printf("[howl] capture goroutine: emitting warning + fallback result")
			e.events <- event{Kind: "warning", Msg: "llm: " + res.LLMError.Error()}
		}
		log.Printf("[howl] capture goroutine: emitting result (len=%d)", len(res.Cleaned))
		e.events <- event{Kind: "result", Text: res.Cleaned}
		log.Printf("[howl] capture goroutine: result event delivered")
	}()
	return 0
}

// howl_push_audio enqueues a chunk of Float32 mono 48 kHz audio for the
// in-flight capture. Non-blocking: if the internal buffer is full the
// frame is dropped and a single "audio buffer full, dropping frames"
// warning is emitted per cycle (audio threads must not block).
//
// Returns:
//
//	0 = enqueued (or dropped, but see warning event)
//	1 = engine not initialized
//	2 = no capture in flight (must call howl_start_capture first)
//
//export howl_push_audio
func howl_push_audio(samples *C.float, count C.int) C.int {
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
			log.Printf("[howl] push_audio: heartbeat n=%d total=%d", n, pc)
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

// howl_stop_capture signals end-of-input for the in-flight capture by
// closing the audio push channel. The pipeline goroutine drains
// remaining frames, runs transcribe/clean, and emits a result event.
// Idempotent: safe to call when no capture is active. Returns 1 if
// the engine is not initialized.
//
//export howl_stop_capture
func howl_stop_capture() C.int {
	e := getEngine()
	if e == nil {
		return 1
	}
	e.mu.Lock()
	defer e.mu.Unlock()
	log.Printf("[howl] howl_stop_capture: closing push channel")
	if e.pushCh != nil {
		close(e.pushCh)
		e.pushCh = nil
	}
	if e.cancel != nil {
		e.cancel = nil
	}
	return 0
}

// howl_cancel_capture aborts the in-flight capture, drops any buffered
// audio, and emits a "cancelled" event instead of a "result". Idempotent:
// safe to call when no capture is active. Returns 1 if the engine is
// not initialized, 0 otherwise.
//
//export howl_cancel_capture
func howl_cancel_capture() C.int {
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
		log.Printf("[howl] howl_cancel_capture: cancelling in-flight pipeline")
		cancel()
	}
	return 0
}

// howl_poll_event returns a JSON-encoded event string, or NULL if no
// event is queued. The returned string is heap-allocated; the caller
// must free it via howl_free_string.
//
//export howl_poll_event
func howl_poll_event() *C.char {
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

// howl_destroy tears down the engine. Idempotent: calling on an
// already-destroyed engine is a no-op.
//
//export howl_destroy
func howl_destroy() {
	e := getEngine()
	if e == nil {
		return
	}
	_ = howl_stop_capture()
	e.mu.Lock()
	pipe := e.pipeline
	e.pipeline = nil
	e.mu.Unlock()
	if pipe != nil {
		_ = pipe.Close()
	}
	setEngine(nil)
}

// howl_last_error returns the last error message as a C string, or NULL
// if no error is set. The returned string is heap-allocated; the caller
// must free it via howl_free_string.
//
//export howl_last_error
func howl_last_error() *C.char {
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

// howl_free_string frees a C string previously returned by
// howl_poll_event or howl_last_error. Passing NULL is a no-op.
//
//export howl_free_string
func howl_free_string(s *C.char) {
	if s != nil {
		C.free(unsafe.Pointer(s))
	}
}

// howl_enroll_compute computes a speaker embedding from a single recorded
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
//	6 = compute failed (see howl_last_error)
//
//export howl_enroll_compute
func howl_enroll_compute(samples *C.float, count C.int, sampleRate C.int, profileDirC *C.char) C.int {
	e := getEngine()
	if e == nil {
		return 1
	}
	if count <= 0 || sampleRate != 48000 || profileDirC == nil {
		e.setLastError("howl_enroll_compute: invalid argument")
		return 5
	}
	profileDir := C.GoString(profileDirC)
	if profileDir == "" {
		e.setLastError("howl_enroll_compute: empty profile dir")
		return 5
	}

	e.mu.Lock()
	encoderPath := e.cfg.SpeakerEncoderPath
	onnxLibPath := e.cfg.ONNXLibPath
	e.mu.Unlock()
	if encoderPath == "" || onnxLibPath == "" {
		e.setLastError("howl_enroll_compute: speaker_encoder_path or onnx_lib_path not configured")
		return 5
	}

	// Copy out of C memory before any Go-side work.
	n := int(count)
	cSlice := unsafe.Slice(samples, n)
	buf := make([]float32, n)
	for i := 0; i < n; i++ {
		buf[i] = float32(cSlice[i])
	}

	log.Printf("[howl] howl_enroll_compute: count=%d sr=%d profileDir=%q", n, int(sampleRate), profileDir)
	if err := runEnrollCompute(buf, profileDir, encoderPath, onnxLibPath); err != nil {
		e.setLastError("howl_enroll_compute: " + err.Error())
		log.Printf("[howl] howl_enroll_compute: FAILED %v", err)
		return 6
	}
	log.Printf("[howl] howl_enroll_compute: success")
	return 0
}

// howl_list_sessions returns a JSON array of session manifests, newest
// first. Returns NULL on engine-not-initialized; an empty array "[]"
// on no sessions. The returned C string is heap-allocated; the caller
// must free it via howl_free_string.
//
//export howl_list_sessions
func howl_list_sessions() *C.char {
	e := getEngine()
	if e == nil || e.sessions == nil {
		return nil
	}
	manifests, err := e.sessions.List()
	if err != nil {
		e.setLastError("howl_list_sessions: " + err.Error())
		return nil
	}
	if manifests == nil {
		manifests = []sessions.Manifest{}
	}
	buf, err := json.Marshal(manifests)
	if err != nil {
		e.setLastError("howl_list_sessions: marshal: " + err.Error())
		return nil
	}
	return C.CString(string(buf))
}

// howl_get_session returns a JSON-encoded Manifest for the given id, or
// NULL if the session does not exist or its manifest is unreadable.
// Caller frees via howl_free_string.
//
//export howl_get_session
func howl_get_session(idC *C.char) *C.char {
	e := getEngine()
	if e == nil || e.sessions == nil {
		return nil
	}
	if idC == nil {
		e.setLastError("howl_get_session: id is NULL")
		return nil
	}
	id := C.GoString(idC)
	m, err := e.sessions.Get(id)
	if err != nil {
		e.setLastError("howl_get_session: " + err.Error())
		return nil
	}
	buf, err := json.Marshal(m)
	if err != nil {
		e.setLastError("howl_get_session: marshal: " + err.Error())
		return nil
	}
	return C.CString(string(buf))
}

// howl_delete_session removes a single session folder. Idempotent.
// Returns 0 on success, 1 if the engine is not initialized, 5 on
// invalid id (path traversal etc.), 6 on filesystem error.
//
//export howl_delete_session
func howl_delete_session(idC *C.char) C.int {
	e := getEngine()
	if e == nil || e.sessions == nil {
		return 1
	}
	if idC == nil {
		e.setLastError("howl_delete_session: id is NULL")
		return 5
	}
	id := C.GoString(idC)
	if err := e.sessions.Delete(id); err != nil {
		e.setLastError("howl_delete_session: " + err.Error())
		// Distinguish bad-id (validation) from disk error.
		if errors.Is(err, sessions.ErrInvalidSessionID) {
			return 5
		}
		return 6
	}
	return 0
}

// howl_clear_sessions removes every session folder. Returns 0 on
// success, 1 if engine not initialized, 6 on filesystem error.
//
//export howl_clear_sessions
func howl_clear_sessions() C.int {
	e := getEngine()
	if e == nil || e.sessions == nil {
		return 1
	}
	if err := e.sessions.Clear(); err != nil {
		e.setLastError("howl_clear_sessions: " + err.Error())
		return 6
	}
	return 0
}

// abiVersion is the semver of the libhowl C ABI surface. Bumped when:
//   - major: a function signature changes, or one is removed
//   - minor: a new function is added (additive, back-compat)
//   - patch: a fix that doesn't change the surface (rare)
//
// The Mac app reads this via howl_abi_version() at startup and asserts
// it matches the major version it was built against. This catches
// dev-build vs. shipped-dylib mismatches that would otherwise crash
// at first call to the new function.
const abiVersion = "1.0.0"

// howl_abi_version returns the libhowl ABI semver. Caller frees via
// howl_free_string. Never returns NULL.
//
//export howl_abi_version
func howl_abi_version() *C.char {
	return C.CString(abiVersion)
}

// howl_list_presets returns a JSON array of presets (bundled + user).
// Caller frees via howl_free_string. Returns NULL on engine-not-init.
//
//export howl_list_presets
func howl_list_presets() *C.char {
	e := getEngine()
	if e == nil {
		return nil
	}
	all, err := presets.Load()
	if err != nil {
		e.setLastError("howl_list_presets: " + err.Error())
		return nil
	}
	if all == nil {
		all = []presets.Preset{}
	}
	buf, err := json.Marshal(all)
	if err != nil {
		e.setLastError("howl_list_presets: marshal: " + err.Error())
		return nil
	}
	return C.CString(string(buf))
}

// howl_get_preset returns the JSON-encoded Preset for the given name,
// or NULL if not found. Caller frees via howl_free_string.
//
//export howl_get_preset
func howl_get_preset(nameC *C.char) *C.char {
	e := getEngine()
	if e == nil {
		return nil
	}
	if nameC == nil {
		e.setLastError("howl_get_preset: name is NULL")
		return nil
	}
	name := C.GoString(nameC)
	all, err := presets.Load()
	if err != nil {
		e.setLastError("howl_get_preset: " + err.Error())
		return nil
	}
	for _, p := range all {
		if p.Name == name {
			buf, err := json.Marshal(p)
			if err != nil {
				e.setLastError("howl_get_preset: marshal: " + err.Error())
				return nil
			}
			return C.CString(string(buf))
		}
	}
	return nil
}

// howl_save_preset persists a user preset. body is a JSON-encoded
// Preset. Returns 0 on success, 1 if engine not initialized, 5 for
// invalid/reserved name, 6 for filesystem error, 2 for JSON parse error.
//
// nameC + descriptionC overwrite the body's Name/Description so callers
// constructing JSON from an EngineConfig don't have to mirror them.
//
//export howl_save_preset
func howl_save_preset(nameC, descriptionC, bodyC *C.char) C.int {
	e := getEngine()
	if e == nil {
		return 1
	}
	if nameC == nil || bodyC == nil {
		e.setLastError("howl_save_preset: nil argument")
		return 5
	}
	body := C.GoString(bodyC)
	var p presets.Preset
	if err := json.Unmarshal([]byte(body), &p); err != nil {
		e.setLastError("howl_save_preset: parse: " + err.Error())
		return 2
	}
	p.Name = C.GoString(nameC)
	if descriptionC != nil {
		p.Description = C.GoString(descriptionC)
	}
	if err := presets.SaveUser(p); err != nil {
		e.setLastError("howl_save_preset: " + err.Error())
		if errors.Is(err, presets.ErrInvalidName) || errors.Is(err, presets.ErrReservedName) {
			return 5
		}
		return 6
	}
	return 0
}

// howl_delete_preset removes a user preset. Returns 0 on success
// (idempotent), 1 if engine not init, 5 for invalid/reserved name,
// 6 for filesystem error.
//
//export howl_delete_preset
func howl_delete_preset(nameC *C.char) C.int {
	e := getEngine()
	if e == nil {
		return 1
	}
	if nameC == nil {
		e.setLastError("howl_delete_preset: name is NULL")
		return 5
	}
	name := C.GoString(nameC)
	if err := presets.DeleteUser(name); err != nil {
		e.setLastError("howl_delete_preset: " + err.Error())
		if errors.Is(err, presets.ErrInvalidName) || errors.Is(err, presets.ErrReservedName) {
			return 5
		}
		return 6
	}
	return 0
}
