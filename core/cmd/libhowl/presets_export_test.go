//go:build whispercpp

package main

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/voice-keyboard/core/internal/presets"
)

func TestExport_ListPresets_IncludesBundled(t *testing.T) {
	if getEngine() == nil {
		_ = howl_init()
	}
	got := presetListGo()
	if got == "" {
		t.Fatal("expected non-empty result")
	}
	var arr []presets.Preset
	if err := json.Unmarshal([]byte(got), &arr); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if len(arr) < 4 {
		t.Errorf("len = %d, want at least 4 (bundled count)", len(arr))
	}
}

func TestExport_GetPreset_DefaultRoundTrips(t *testing.T) {
	if getEngine() == nil {
		_ = howl_init()
	}
	got := presetGetGo("default")
	if got == "" {
		t.Fatal("expected non-empty result for default preset")
	}
	var p presets.Preset
	if err := json.Unmarshal([]byte(got), &p); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if p.Name != "default" {
		t.Errorf("Name = %q, want default", p.Name)
	}
}

func TestExport_GetPreset_UnknownReturnsEmpty(t *testing.T) {
	if getEngine() == nil {
		_ = howl_init()
	}
	got := presetGetGo("nope")
	if got != "" {
		t.Errorf("expected empty for unknown preset, got %q", got)
	}
}

func TestExport_SavePreset_RoundTrips(t *testing.T) {
	if getEngine() == nil {
		_ = howl_init()
	}
	dir := t.TempDir()
	// Override the user dir so we don't pollute the real ~/Library location.
	t.Setenv("HOWL_PRESETS_USER_DIR", dir)

	body := `{"name":"my-test","description":"x","frame_stages":[],"chunk_stages":[],"transcribe":{"model_size":"small"},"llm":{"provider":"anthropic"}}`
	if rc := presetSaveGo("my-test", "x", body); rc != 0 {
		t.Fatalf("save rc=%d", rc)
	}
	listJSON := presetListGo()
	if !strings.Contains(listJSON, `"name":"my-test"`) {
		t.Errorf("saved preset not in list: %s", listJSON)
	}
}

func TestExport_DeletePreset_BundledNameRejected(t *testing.T) {
	if getEngine() == nil {
		_ = howl_init()
	}
	if rc := presetDeleteGo("default"); rc != 5 {
		t.Errorf("rc = %d, want 5 (reserved name)", rc)
	}
}
