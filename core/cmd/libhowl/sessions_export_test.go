//go:build whispercpp

package main

import (
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/voice-keyboard/core/internal/sessions"
)

// withTempSessionsStore swaps in a temp Store for a single test and
// registers a cleanup that restores the production path. Avoids
// polluting /tmp/voicekeyboard/sessions/.
func withTempSessionsStore(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	if getEngine() == nil {
		_ = howl_init()
	}
	getEngine().sessions = sessions.NewStore(dir)
	t.Cleanup(func() {
		if e := getEngine(); e != nil {
			e.sessions = sessions.NewStore("/tmp/voicekeyboard/sessions")
		}
	})
	return dir
}

func writeSessionFolder(t *testing.T, base, id string) {
	t.Helper()
	dir := filepath.Join(base, id)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	m := sessions.Manifest{Version: sessions.CurrentManifestVersion, ID: id, Preset: "default"}
	if err := m.Write(dir); err != nil {
		t.Fatal(err)
	}
}

func TestExport_ListSessions_EmptyReturnsEmptyArray(t *testing.T) {
	withTempSessionsStore(t)
	got, err := sessionListGo()
	if err != nil {
		t.Fatalf("sessionListGo: %v", err)
	}
	// Engine is initialized so we expect an empty array (not nil).
	if got == nil {
		t.Fatal("expected non-nil result")
	}
	if len(got) != 0 {
		t.Errorf("len = %d, want 0", len(got))
	}
}

func TestExport_ListSessions_ReturnsManifests(t *testing.T) {
	dir := withTempSessionsStore(t)
	writeSessionFolder(t, dir, "2026-05-02T14:30:45Z")
	writeSessionFolder(t, dir, "2026-05-02T14:32:11Z")

	got, err := sessionListGo()
	if err != nil {
		t.Fatalf("sessionListGo: %v", err)
	}
	if len(got) != 2 {
		t.Errorf("len = %d, want 2", len(got))
	}
	if got[0].ID != "2026-05-02T14:32:11Z" {
		t.Errorf("first.ID = %q, want newest first", got[0].ID)
	}
}

func TestExport_GetSession_RoundTrip(t *testing.T) {
	dir := withTempSessionsStore(t)
	writeSessionFolder(t, dir, "2026-05-02T14:30:45Z")

	m, err := sessionGetGo("2026-05-02T14:30:45Z")
	if err != nil {
		t.Fatalf("sessionGetGo: %v", err)
	}
	if m == nil {
		t.Fatal("expected non-nil manifest")
	}
	if m.ID != "2026-05-02T14:30:45Z" {
		t.Errorf("ID = %q", m.ID)
	}
}

func TestExport_GetSession_UnknownReturnsNil(t *testing.T) {
	withTempSessionsStore(t)
	m, err := sessionGetGo("does-not-exist")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if m != nil {
		t.Error("expected nil for missing session")
	}
}

func TestExport_DeleteSession_RemovesFolder(t *testing.T) {
	dir := withTempSessionsStore(t)
	writeSessionFolder(t, dir, "2026-05-02T14:30:45Z")

	if rc := sessionDeleteGo("2026-05-02T14:30:45Z"); rc != 0 {
		t.Fatalf("delete rc=%d", rc)
	}
	if _, err := os.Stat(filepath.Join(dir, "2026-05-02T14:30:45Z")); !os.IsNotExist(err) {
		t.Errorf("folder still present: %v", err)
	}
}

func TestExport_DeleteSession_RejectsTraversal(t *testing.T) {
	withTempSessionsStore(t)
	if rc := sessionDeleteGo("../escape"); rc != 5 {
		t.Errorf("rc = %d, want 5 (invalid id)", rc)
	}
}

func TestExport_ClearSessions_RemovesAll(t *testing.T) {
	dir := withTempSessionsStore(t)
	writeSessionFolder(t, dir, "2026-05-02T14:30:45Z")
	writeSessionFolder(t, dir, "2026-05-02T14:32:11Z")

	if rc := howl_clear_sessions(); rc != 0 {
		t.Fatalf("clear rc=%d", rc)
	}
	entries, _ := os.ReadDir(dir)
	if len(entries) != 0 {
		t.Errorf("entries left after clear: %d", len(entries))
	}
}

func TestExport_AbiVersion_ReturnsExpectedSemver(t *testing.T) {
	// howl_init not required for the version probe — versioning is a
	// library-level constant.
	got := abiVersionGo()
	if got != "1.0.0" {
		t.Errorf("version = %q, want 1.0.0", got)
	}
}

func TestOpenSessionRecorder_TwoCallsProduceTwoFolders(t *testing.T) {
	dir := withTempSessionsStore(t)
	getEngine().cfg.DeveloperMode = true
	t.Cleanup(func() {
		getEngine().cfg.DeveloperMode = false
		getEngine().activeSessionID = ""
		getEngine().activeSessionDir = ""
		getEngine().activeRecorder = nil
	})

	// Two calls in sequence must produce two distinct session folders.
	if err := openSessionRecorder(getEngine()); err != nil {
		t.Fatalf("first openSessionRecorder: %v", err)
	}
	id1 := getEngine().activeSessionID
	getEngine().activeSessionID = ""
	getEngine().activeSessionDir = ""
	getEngine().activeRecorder = nil

	// Sleep 1 ms to ensure RFC3339-nanos timestamps differ.
	time.Sleep(time.Millisecond)

	if err := openSessionRecorder(getEngine()); err != nil {
		t.Fatalf("second openSessionRecorder: %v", err)
	}
	id2 := getEngine().activeSessionID

	if id1 == "" || id2 == "" {
		t.Fatalf("session IDs not set: id1=%q id2=%q", id1, id2)
	}
	if id1 == id2 {
		t.Errorf("two calls produced the same id %q", id1)
	}
	for _, id := range []string{id1, id2} {
		if _, err := os.Stat(filepath.Join(dir, id)); err != nil {
			t.Errorf("session folder %q missing: %v", id, err)
		}
	}
}
