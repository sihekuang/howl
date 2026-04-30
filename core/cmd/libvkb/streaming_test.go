package main

import (
	"encoding/json"
	"testing"
)

// TestEvent_ChunkJSONEncoding pins the wire format Swift decodes —
// kind="chunk" with text payload — so a refactor on the Go side
// can't silently rename the field and break the EngineEvent.chunk
// case in VoiceKeyboardCore.
//
// (Full C ABI integration tests would also exercise vkb_push_audio /
// vkb_poll_event end-to-end, but Go forbids `import "C"` in _test.go
// files and the existing pipeline + anthropic streaming tests already
// cover the goroutine + LLMDeltaCallback wiring.)
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
