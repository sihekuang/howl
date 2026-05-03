package main

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/voice-keyboard/core/internal/sessions"
)

// TestEvent_ChunkJSONEncoding pins the wire format Swift decodes —
// kind="chunk" with text payload — so a refactor on the Go side
// can't silently rename the field and break the EngineEvent.chunk
// case in VoiceKeyboardCore.
//
// (Full C ABI integration tests would also exercise vkb_push_audio /
// vkb_poll_event end-to-end, but Go forbids `import "C"` in _test.go
// files and the existing pipeline + anthropic streaming tests already
// cover the goroutine + Listener wiring (EventLLMDelta).)
func TestEvent_ChunkJSONEncoding(t *testing.T) {
	cases := []struct {
		ev   event
		want string
	}{
		{event{Kind: "chunk", Text: "Hello"}, `{"kind":"chunk","text":"Hello"}`},
		{event{Kind: "chunk", Text: ""}, `{"kind":"chunk"}`},                  // empty text omitted
		{event{Kind: "result", Text: "Final."}, `{"kind":"result","text":"Final."}`},
		{event{Kind: "level", RMS: 0.5}, `{"kind":"level","rms":0.5}`},
		{event{Kind: "warning", Msg: "x"}, `{"kind":"warning","msg":"x"}`},
		{event{Kind: "error", Msg: "boom"}, `{"kind":"error","msg":"boom"}`},
	}
	for _, c := range cases {
		b, err := json.Marshal(c.ev)
		if err != nil {
			t.Fatalf("marshal %+v: %v", c.ev, err)
		}
		if string(b) != c.want {
			t.Errorf("event %+v encoded = %s, want %s", c.ev, b, c.want)
		}
	}
}

// TestCaptureGoroutine_CancelEmitsCancelledNotError verifies that when
// pipe.Run returns context.Canceled (e.g. because vkb_cancel_capture
// called the engine's cancel func), the capture goroutine emits a
// "cancelled" event rather than an "error" event.
//
// We can't call the C export directly from _test.go, so we mirror the
// goroutine's error-handling shape with a fake pipe.Run.
func TestCaptureGoroutine_CancelEmitsCancelledNotError(t *testing.T) {
	events := make(chan event, 8)

	// Simulate the relevant block from vkb_start_capture's goroutine.
	emitForRunErr := func(err error) {
		if err != nil {
			if errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) {
				events <- event{Kind: "cancelled"}
				return
			}
			events <- event{Kind: "error", Msg: err.Error()}
			return
		}
		events <- event{Kind: "result"}
	}

	emitForRunErr(context.Canceled)
	emitForRunErr(context.DeadlineExceeded)
	emitForRunErr(errors.New("whisper boom"))
	emitForRunErr(nil)

	wantKinds := []string{"cancelled", "cancelled", "error", "result"}
	for i, want := range wantKinds {
		select {
		case ev := <-events:
			if ev.Kind != want {
				t.Errorf("event[%d].Kind = %q, want %q", i, ev.Kind, want)
			}
		case <-time.After(50 * time.Millisecond):
			t.Fatalf("event[%d] timeout", i)
		}
	}
}

// TestCancelHelper_DropsPushChAndCallsCancel verifies the engine state
// transitions inside vkb_cancel_capture without going through the C ABI.
func TestCancelHelper_DropsPushChAndCallsCancel(t *testing.T) {
	pushCh := make(chan []float32, 4)
	ctx, cancel := context.WithCancel(context.Background())
	cancelCalled := false
	wrappedCancel := func() {
		cancelCalled = true
		cancel()
	}
	e := &engine{events: make(chan event, 4)}
	e.pushCh = pushCh
	e.cancel = wrappedCancel

	// Mirror the body of vkb_cancel_capture (minus the C return code).
	e.mu.Lock()
	c := e.cancel
	if e.pushCh != nil {
		close(e.pushCh)
		e.pushCh = nil
	}
	e.cancel = nil
	e.mu.Unlock()
	if c != nil {
		c()
	}

	if !cancelCalled {
		t.Error("cancel func was not invoked")
	}
	if e.pushCh != nil {
		t.Error("pushCh was not nilled")
	}
	if e.cancel != nil {
		t.Error("cancel field was not nilled")
	}
	if ctx.Err() != context.Canceled {
		t.Errorf("ctx not cancelled: %v", ctx.Err())
	}
	// Verify the "no active capture" no-op path is safe (idempotent).
	e.mu.Lock()
	c = e.cancel
	if e.pushCh != nil {
		close(e.pushCh)
		e.pushCh = nil
	}
	e.cancel = nil
	e.mu.Unlock()
	if c != nil {
		c()
	}
	// If we got here without panic, the no-op path is safe.
}

// TestCapture_WritesSessionManifest_WhenDeveloperMode runs a fake
// capture cycle with DeveloperMode=true and asserts a session.json
// landed under /tmp/voicekeyboard/sessions/<id>/.
func TestCapture_WritesSessionManifest_WhenDeveloperMode(t *testing.T) {
	t.Skip("end-to-end — requires whisper model; covered by manual smoke + e2e suite")
	// Documentation of intent: when configured with DeveloperMode=true
	// and a real audio buffer pushed via vkb_push_audio, after
	// vkb_stop_capture returns and a result event is observed,
	// e.activeSessionDir must contain a valid session.json whose ID
	// matches e.activeSessionID and whose Preset is the active preset
	// name (or "default" until the presets package lands in Slice 2).
	_ = sessions.Manifest{}
	_ = os.Stat
	_ = filepath.Join
}
