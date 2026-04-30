package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"os"
	"sync"
	"time"
	"unsafe"

	"github.com/voice-keyboard/core/internal/config"
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

	// Stream LLM cleaned-text deltas to Swift as they arrive. Each
	// chunk becomes an event{Kind: "chunk", Text: "..."}; Swift types
	// them at the cursor incrementally. Terminal `result` event is
	// still emitted at the end with the full cleaned text (Swift can
	// ignore the text since it's already typed, but the event signals
	// state transition idle ← processing).
	pipe.LLMDeltaCallback = func(delta string) {
		if delta == "" {
			return
		}
		e.events <- event{Kind: "chunk", Text: delta}
	}

	go func() {
		log.Printf("[vkb] capture goroutine: started")
		defer func() {
			if r := recover(); r != nil {
				msg := fmt.Sprintf("panic: %v", r)
				log.Printf("[vkb] capture goroutine: PANIC %s", msg)
				e.events <- event{Kind: "error", Msg: msg}
			}
			e.mu.Lock()
			e.pushCh = nil
			e.cancel = nil
			drops := e.dropCount
			pushes := e.pushCount
			e.dropCount = 0
			e.pushCount = 0
			e.mu.Unlock()
			log.Printf("[vkb] capture goroutine: exited (pushes=%d drops=%d)", pushes, drops)
		}()
		res, err := pipe.Run(ctx, pushCh)
		// Terminal events (error/warning/result) MUST NOT be dropped:
		// if they are, Swift sits forever in `processing`. We accept
		// blocking here — by the time we're stopping, level emission
		// is over and the channel will drain quickly.
		if err != nil {
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
