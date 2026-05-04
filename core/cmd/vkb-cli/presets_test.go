package main

import (
	"encoding/json"
	"io"
	"os"
	"strings"
	"testing"

	"github.com/voice-keyboard/core/internal/presets"
)

// captureStdout swaps os.Stdout for a pipe and returns whatever fn wrote.
// Tests use this when assertions need to inspect the human/JSON output.
func captureStdout(t *testing.T, fn func() int) (string, int) {
	t.Helper()
	old := os.Stdout
	r, w, _ := os.Pipe()
	os.Stdout = w
	rc := fn()
	_ = w.Close()
	os.Stdout = old
	buf, _ := io.ReadAll(r)
	return string(buf), rc
}

func TestPresets_NoArgs_ShowsUsage(t *testing.T) {
	if rc := runPresets(nil); rc == 0 {
		t.Fatal("expected non-zero rc when no action given")
	}
}

func TestPresets_UnknownAction(t *testing.T) {
	if rc := runPresets([]string{"frobnicate"}); rc == 0 {
		t.Fatal("expected non-zero rc for unknown action")
	}
}

func TestPresets_List_TablesByDefault(t *testing.T) {
	out, rc := captureStdout(t, func() int { return runPresets([]string{"list"}) })
	if rc != 0 {
		t.Fatalf("rc = %d, want 0", rc)
	}
	if !strings.Contains(out, "default") {
		t.Errorf("expected 'default' in output, got %q", out)
	}
	if !strings.Contains(out, "NAME") {
		t.Errorf("expected NAME header in table output, got %q", out)
	}
}

func TestPresets_List_JSONFlag(t *testing.T) {
	out, rc := captureStdout(t, func() int { return runPresets([]string{"list", "--json"}) })
	if rc != 0 {
		t.Fatalf("rc = %d, want 0", rc)
	}
	var got []presets.Preset
	if err := json.Unmarshal([]byte(out), &got); err != nil {
		t.Fatalf("unmarshal: %v\n%s", err, out)
	}
	if len(got) == 0 {
		t.Errorf("expected at least one preset in JSON output")
	}
	// Bundled presets always contain 'default'.
	var sawDefault bool
	for _, p := range got {
		if p.Name == "default" {
			sawDefault = true
		}
	}
	if !sawDefault {
		t.Errorf("expected 'default' preset in JSON list, got %d entries", len(got))
	}
}

func TestPresets_Show_UnknownName(t *testing.T) {
	if rc := runPresets([]string{"show", "no-such-preset-xyz"}); rc == 0 {
		t.Errorf("expected non-zero rc for unknown preset")
	}
}

func TestPresets_Show_KnownName_Human(t *testing.T) {
	out, rc := captureStdout(t, func() int { return runPresets([]string{"show", "default"}) })
	if rc != 0 {
		t.Fatalf("rc = %d, want 0", rc)
	}
	if !strings.Contains(out, "Name:") {
		t.Errorf("expected human-format 'Name:' header, got %q", out)
	}
}

func TestPresets_Show_KnownName_JSON(t *testing.T) {
	// Flag args must precede the positional name (standard Go flag semantics).
	out, rc := captureStdout(t, func() int { return runPresets([]string{"show", "--json", "default"}) })
	if rc != 0 {
		t.Fatalf("rc = %d, want 0", rc)
	}
	var p presets.Preset
	if err := json.Unmarshal([]byte(out), &p); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if p.Name != "default" {
		t.Errorf("Name = %q, want default", p.Name)
	}
}

func TestPresets_Save_ClonesDefault_RoundTripDelete(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("VKB_PRESETS_USER_DIR", dir)

	if rc := runPresets([]string{"save", "--description", "test clone", "my-clone"}); rc != 0 {
		t.Fatalf("save rc = %d", rc)
	}
	all, err := presets.LoadUserAt(dir)
	if err != nil {
		t.Fatalf("LoadUserAt: %v", err)
	}
	if len(all) != 1 || all[0].Name != "my-clone" {
		t.Fatalf("expected one user preset 'my-clone', got %+v", all)
	}
	if all[0].Description != "test clone" {
		t.Errorf("Description = %q, want 'test clone'", all[0].Description)
	}

	if rc := runPresets([]string{"delete", "my-clone"}); rc != 0 {
		t.Fatalf("delete rc = %d", rc)
	}
	all2, _ := presets.LoadUserAt(dir)
	if len(all2) != 0 {
		t.Fatalf("expected zero user presets after delete, got %+v", all2)
	}
}

func TestPresets_Save_RejectsBundledName(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("VKB_PRESETS_USER_DIR", dir)
	if rc := runPresets([]string{"save", "default"}); rc == 0 {
		t.Errorf("expected non-zero rc when saving over bundled name")
	}
}

func TestPresets_Save_RejectsInvalidName(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("VKB_PRESETS_USER_DIR", dir)
	if rc := runPresets([]string{"save", "Has Spaces"}); rc == 0 {
		t.Errorf("expected non-zero rc for invalid name")
	}
}

func TestPresets_Save_FromMissingSession(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("VKB_PRESETS_USER_DIR", dir)
	t.Setenv("VKB_SESSIONS_DIR", t.TempDir())
	if rc := runPresets([]string{"save", "--from", "no-such-session", "from-session"}); rc == 0 {
		t.Errorf("expected non-zero rc when --from references missing session")
	}
}

func TestPresets_Delete_Idempotent(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("VKB_PRESETS_USER_DIR", dir)
	// Deleting a preset that doesn't exist mirrors presets.DeleteUser's
	// idempotent contract — should succeed (rc=0).
	if rc := runPresets([]string{"delete", "ghost"}); rc != 0 {
		t.Errorf("rc = %d, want 0 (delete is idempotent)", rc)
	}
}
