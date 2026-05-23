//go:build whispercpp

package main

import "testing"

// TestPipe_PresetFlag_UnknownPresetExits2 exercises the new --preset
// lookup. The lookup happens before transcribe.NewWhisperCpp so we don't
// need a real Whisper model — an unknown preset name short-circuits to
// rc=2 from the validation gate.
func TestPipe_PresetFlag_UnknownPresetExits2(t *testing.T) {
	rc := runPipe([]string{"--preset", "no-such-preset-xyz", "/dev/null"})
	if rc != 2 {
		t.Errorf("rc = %d, want 2", rc)
	}
}
