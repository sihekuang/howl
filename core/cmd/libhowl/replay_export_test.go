//go:build whispercpp

package main

import (
	"strings"
	"testing"
)

func TestExport_Replay_RejectsEmptyPresets(t *testing.T) {
	if getEngine() == nil {
		_ = howl_init()
	}
	out := replayGo("any-id", "")
	if !strings.Contains(out, "error") {
		t.Errorf("expected error JSON for empty preset list, got: %s", out)
	}
}

func TestExport_Replay_RejectsMissingSession(t *testing.T) {
	if getEngine() == nil {
		_ = howl_init()
	}
	out := replayGo("does-not-exist", "default")
	if !strings.Contains(out, "error") {
		t.Errorf("expected error JSON for missing session, got: %s", out)
	}
}
