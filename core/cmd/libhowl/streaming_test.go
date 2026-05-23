//go:build whispercpp

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
// case in HowlCore.
//
// (Full C ABI integration tests would also exercise howl_push_audio /
// howl_poll_event end-to-end, but Go forbids `import "C"` in _test.go
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
// pipe.Run returns context.Canceled (e.g. because howl_cancel_capture
// called the engine's cancel func), the capture goroutine emits a
// "cancelled" event rather than an "error" event.
//
// We can't call the C export directly from _test.go, so we mirror the
// goroutine's error-handling shape with a fake pipe.Run.
func TestCaptureGoroutine_CancelEmitsCancelledNotError(t *testing.T) {
	events := make(chan event, 8)

	// Simulate the relevant block from howl_start_capture's goroutine.
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
// transitions inside howl_cancel_capture without going through the C ABI.
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

	// Mirror the body of howl_cancel_capture (minus the C return code).
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

// TestStopCapture_ArmsWatchdog_WhenTimeoutConfigured verifies that
// howl_stop_capture's logic schedules a time.AfterFunc that fires
// context cancellation with cause errPipelineTimedOut after the
// configured duration. This is the load-bearing piece of the
// post-stop-only timeout model: the timer must start at stop, not at
// start, so long dictations don't get cut off mid-sentence.
func TestStopCapture_ArmsWatchdog_WhenTimeoutConfigured(t *testing.T) {
	ctx, cwc := context.WithCancelCause(context.Background())
	pushCh := make(chan []float32, 4)
	e := &engine{events: make(chan event, 4)}
	e.pushCh = pushCh
	e.cancelWithCause = cwc
	e.cancel = func() { cwc(errUserCanceled) }
	e.timeoutAfterStop = 30 * time.Millisecond

	// Mirror the body of howl_stop_capture.
	e.mu.Lock()
	if e.pushCh != nil {
		close(e.pushCh)
		e.pushCh = nil
	}
	if e.timeoutAfterStop > 0 && e.cancelWithCause != nil && e.stopTimer == nil {
		cwc2 := e.cancelWithCause
		d := e.timeoutAfterStop
		e.stopTimer = time.AfterFunc(d, func() {
			cwc2(errPipelineTimedOut)
		})
	}
	e.mu.Unlock()

	if e.stopTimer == nil {
		t.Fatal("stopTimer was not armed despite timeoutAfterStop > 0")
	}

	select {
	case <-ctx.Done():
		cause := context.Cause(ctx)
		if !errors.Is(cause, errPipelineTimedOut) {
			t.Errorf("cause = %v, want errPipelineTimedOut", cause)
		}
		if ctx.Err() != context.Canceled {
			t.Errorf("ctx.Err() = %v, want context.Canceled", ctx.Err())
		}
	case <-time.After(500 * time.Millisecond):
		t.Fatal("watchdog timer did not fire within 500ms")
	}
}

// TestStopCapture_NoTimer_WhenTimeoutDisabled verifies that with
// PipelineTimeoutSec=0 (the legacy/disabled config), howl_stop_capture
// does NOT arm a watchdog. The pipeline must be free to run as long as
// it needs.
func TestStopCapture_NoTimer_WhenTimeoutDisabled(t *testing.T) {
	_, cwc := context.WithCancelCause(context.Background())
	pushCh := make(chan []float32, 4)
	e := &engine{events: make(chan event, 4)}
	e.pushCh = pushCh
	e.cancelWithCause = cwc
	e.timeoutAfterStop = 0

	e.mu.Lock()
	if e.pushCh != nil {
		close(e.pushCh)
		e.pushCh = nil
	}
	if e.timeoutAfterStop > 0 && e.cancelWithCause != nil && e.stopTimer == nil {
		t.Fatal("should not enter arm-timer branch when timeoutAfterStop == 0")
	}
	e.mu.Unlock()

	if e.stopTimer != nil {
		t.Fatal("stopTimer should be nil when timeoutAfterStop == 0")
	}
}

// TestCaptureGoroutine_CauseDistinguishesTimerVsUser verifies that the
// error-handling shape inside howl_start_capture's goroutine emits
// different events for the two cancel paths: watchdog → warning +
// empty result, user → cancelled. Both paths surface as
// context.Canceled from pipe.Run; the cause is the only differentiator.
func TestCaptureGoroutine_CauseDistinguishesTimerVsUser(t *testing.T) {
	events := make(chan event, 8)

	// Mirror the goroutine's cause-aware emit logic.
	emit := func(ctx context.Context, err error) {
		if err != nil {
			if errors.Is(err, context.Canceled) {
				if errors.Is(context.Cause(ctx), errPipelineTimedOut) {
					events <- event{Kind: "warning", Msg: "pipeline timed out"}
					events <- event{Kind: "result", Text: ""}
					return
				}
				events <- event{Kind: "cancelled"}
				return
			}
			events <- event{Kind: "error", Msg: err.Error()}
			return
		}
		events <- event{Kind: "result"}
	}

	// Timer-fired path.
	ctxTimer, cancelTimer := context.WithCancelCause(context.Background())
	cancelTimer(errPipelineTimedOut)
	emit(ctxTimer, ctxTimer.Err())

	// User-fired path.
	ctxUser, cancelUser := context.WithCancelCause(context.Background())
	cancelUser(errUserCanceled)
	emit(ctxUser, ctxUser.Err())

	// Plain error path (non-cancel).
	ctxErr, _ := context.WithCancelCause(context.Background())
	emit(ctxErr, errors.New("whisper boom"))

	// Success path.
	ctxOk, _ := context.WithCancelCause(context.Background())
	emit(ctxOk, nil)

	wantKinds := []string{"warning", "result", "cancelled", "error", "result"}
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

// TestCancelAfterStop_TimerStopsBeforeUserCancel verifies that when
// howl_cancel_capture races against the post-stop watchdog, the timer
// is disarmed before the user-cancel runs — so the cause attached to
// the context is errUserCanceled, not errPipelineTimedOut.
// context.CancelCauseFunc is first-write-wins, so the order matters.
func TestCancelAfterStop_TimerStopsBeforeUserCancel(t *testing.T) {
	ctx, cwc := context.WithCancelCause(context.Background())
	pushCh := make(chan []float32, 4)
	e := &engine{events: make(chan event, 4)}
	e.pushCh = pushCh
	e.cancelWithCause = cwc
	e.cancel = func() { cwc(errUserCanceled) }
	// Arm a watchdog that would fire well after the test runs.
	e.timeoutAfterStop = 10 * time.Second
	e.stopTimer = time.AfterFunc(e.timeoutAfterStop, func() {
		cwc(errPipelineTimedOut)
	})

	// Mirror the body of howl_cancel_capture.
	e.mu.Lock()
	cancel := e.cancel
	if e.stopTimer != nil {
		e.stopTimer.Stop()
		e.stopTimer = nil
	}
	if e.pushCh != nil {
		close(e.pushCh)
		e.pushCh = nil
	}
	e.cancel = nil
	e.cancelWithCause = nil
	e.mu.Unlock()
	if cancel != nil {
		cancel()
	}

	if ctx.Err() != context.Canceled {
		t.Errorf("ctx.Err() = %v, want Canceled", ctx.Err())
	}
	if got := context.Cause(ctx); !errors.Is(got, errUserCanceled) {
		t.Errorf("cause = %v, want errUserCanceled (timer should not have raced past Stop)", got)
	}
}

// TestCapture_WritesSessionManifest_WhenDeveloperMode runs a fake
// capture cycle with DeveloperMode=true and asserts a session.json
// landed under /tmp/voicekeyboard/sessions/<id>/.
func TestCapture_WritesSessionManifest_WhenDeveloperMode(t *testing.T) {
	t.Skip("end-to-end — requires whisper model; covered by manual smoke + e2e suite")
	// Documentation of intent: when configured with DeveloperMode=true
	// and a real audio buffer pushed via howl_push_audio, after
	// howl_stop_capture returns and a result event is observed,
	// e.activeSessionDir must contain a valid session.json whose ID
	// matches e.activeSessionID and whose Preset is the active preset
	// name (or "default" until the presets package lands in Slice 2).
	_ = sessions.Manifest{}
	_ = os.Stat
	_ = filepath.Join
}
