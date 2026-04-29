package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"context"
	"encoding/json"
	"sync"
	"time"
	"unsafe"

	"github.com/voice-keyboard/core/internal/config"
)

// vkb_init initializes the engine. Idempotent: calling it again on an
// already-initialized engine is a no-op and returns 0.
//
//export vkb_init
func vkb_init() C.int {
	if getEngine() != nil {
		return 0
	}
	setEngine(&engine{events: make(chan event, 32)})
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
	if e.stopCh != nil {
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

// vkb_start_capture begins a single-utterance capture cycle. Returns 0
// on successful start, 1 if the engine is not initialized or has no
// pipeline configured, and 2 if a capture is already in flight. Result
// or error events are delivered asynchronously via vkb_poll_event.
//
//export vkb_start_capture
func vkb_start_capture() C.int {
	e := getEngine()
	if e == nil {
		return 1
	}
	e.mu.Lock()
	if e.pipeline == nil {
		e.mu.Unlock()
		return 1
	}
	if e.stopCh != nil {
		e.mu.Unlock()
		return 2
	}
	stopCh := make(chan struct{})
	ctx, cancel := context.WithCancel(context.Background())
	pipe := e.pipeline
	e.stopCh = stopCh
	e.cancel = cancel
	e.mu.Unlock()

	// Throttle level events to ~30Hz, taking max RMS in each window.
	const levelHz = 30
	levelInterval := time.Second / levelHz
	var (
		levelMu     sync.Mutex
		levelMax    float32
		levelLastAt time.Time
	)
	levelLastAt = time.Now()
	pipe.LevelCallback = func(rms float32) {
		levelMu.Lock()
		defer levelMu.Unlock()
		now := time.Now()
		if rms > levelMax {
			levelMax = rms
		}
		if now.Sub(levelLastAt) < levelInterval {
			return
		}
		ev := event{Kind: "level", RMS: levelMax}
		select {
		case e.events <- ev:
		default:
		}
		levelMax = 0
		levelLastAt = now
	}

	go func() {
		defer func() {
			e.mu.Lock()
			e.stopCh = nil
			e.cancel = nil
			e.mu.Unlock()
		}()
		res, err := pipe.Run(ctx, stopCh)
		// Terminal events (error/warning/result) MUST NOT be dropped: if
		// they are, Swift sits forever in `processing`. We accept blocking
		// here — by the time we're stopping, level emission is over and
		// the channel will drain quickly.
		if err != nil {
			e.events <- event{Kind: "error", Msg: err.Error()}
			return
		}
		if res.LLMError != nil {
			e.events <- event{Kind: "warning", Msg: "llm: " + res.LLMError.Error()}
		}
		e.events <- event{Kind: "result", Text: res.Cleaned}
	}()
	return 0
}

// vkb_stop_capture ends an in-flight capture. Idempotent: safe to call
// when no capture is active. Always returns 0 unless the engine is not
// initialized (in which case it returns 1).
//
//export vkb_stop_capture
func vkb_stop_capture() C.int {
	e := getEngine()
	if e == nil {
		return 1
	}
	e.mu.Lock()
	defer e.mu.Unlock()
	if e.stopCh != nil {
		close(e.stopCh)
		e.stopCh = nil
	}
	if e.cancel != nil {
		e.cancel()
		e.cancel = nil
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
