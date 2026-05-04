package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/voice-keyboard/core/internal/sessions"
)

// writeFixtureSession lays down a minimal valid <base>/<id>/session.json
// so List/Show/Delete have something to operate on.
func writeFixtureSession(t *testing.T, base, id string) {
	t.Helper()
	dir := filepath.Join(base, id)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(dir, "transcripts"), 0o755); err != nil {
		t.Fatal(err)
	}
	m := sessions.Manifest{
		ID:          id,
		Preset:      "default",
		DurationSec: 1.5,
		Transcripts: sessions.TranscriptEntries{
			Raw:     "transcripts/raw.txt",
			Dict:    "transcripts/dict.txt",
			Cleaned: "transcripts/cleaned.txt",
		},
	}
	if err := m.Write(dir); err != nil {
		t.Fatalf("write manifest: %v", err)
	}
	// Drop a tiny cleaned.txt so the preview path has something to read.
	if err := os.WriteFile(filepath.Join(dir, "transcripts", "cleaned.txt"), []byte("hello world"), 0o644); err != nil {
		t.Fatalf("write cleaned: %v", err)
	}
}

func TestSessions_NoArgs_ShowsUsage(t *testing.T) {
	if rc := runSessions(nil); rc == 0 {
		t.Errorf("expected non-zero rc")
	}
}

func TestSessions_UnknownAction(t *testing.T) {
	if rc := runSessions([]string{"garbage"}); rc == 0 {
		t.Errorf("expected non-zero rc")
	}
}

func TestSessions_List_EmptyTable(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("VKB_SESSIONS_DIR", dir)
	out, rc := captureStdout(t, func() int { return runSessions([]string{"list"}) })
	if rc != 0 {
		t.Fatalf("rc = %d", rc)
	}
	if !strings.Contains(out, "ID") {
		t.Errorf("expected header in empty table, got %q", out)
	}
}

func TestSessions_List_EmptyJSON(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("VKB_SESSIONS_DIR", dir)
	out, rc := captureStdout(t, func() int { return runSessions([]string{"list", "--json"}) })
	if rc != 0 {
		t.Fatalf("rc = %d", rc)
	}
	got := strings.TrimSpace(out)
	if got != "[]" {
		t.Errorf("expected '[]', got %q", got)
	}
}

func TestSessions_List_WithFixture_JSON(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("VKB_SESSIONS_DIR", dir)
	writeFixtureSession(t, dir, "2026-05-03T10:00:00Z")

	out, rc := captureStdout(t, func() int { return runSessions([]string{"list", "--json"}) })
	if rc != 0 {
		t.Fatalf("rc = %d", rc)
	}
	var got []sessions.Manifest
	if err := json.Unmarshal([]byte(out), &got); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if len(got) != 1 || got[0].ID != "2026-05-03T10:00:00Z" {
		t.Errorf("unexpected list result: %+v", got)
	}
}

func TestSessions_List_TableShowsCleanedPreview(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("VKB_SESSIONS_DIR", dir)
	writeFixtureSession(t, dir, "2026-05-03T10:30:00Z")

	out, rc := captureStdout(t, func() int { return runSessions([]string{"list"}) })
	if rc != 0 {
		t.Fatalf("rc = %d", rc)
	}
	if !strings.Contains(out, "hello world") {
		t.Errorf("expected cleaned preview in table, got %q", out)
	}
}

func TestSessions_Show_UnknownID(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("VKB_SESSIONS_DIR", dir)
	if rc := runSessions([]string{"show", "no-such-id"}); rc == 0 {
		t.Errorf("expected non-zero rc")
	}
}

func TestSessions_Show_KnownID_Human(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("VKB_SESSIONS_DIR", dir)
	writeFixtureSession(t, dir, "2026-05-03T11:00:00Z")
	out, rc := captureStdout(t, func() int {
		return runSessions([]string{"show", "2026-05-03T11:00:00Z"})
	})
	if rc != 0 {
		t.Fatalf("rc = %d", rc)
	}
	if !strings.Contains(out, "ID:") || !strings.Contains(out, "Preset:") {
		t.Errorf("expected human-format headers, got %q", out)
	}
}

func TestSessions_Show_KnownID_JSON(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("VKB_SESSIONS_DIR", dir)
	writeFixtureSession(t, dir, "2026-05-03T11:30:00Z")
	out, rc := captureStdout(t, func() int {
		return runSessions([]string{"show", "--json", "2026-05-03T11:30:00Z"})
	})
	if rc != 0 {
		t.Fatalf("rc = %d", rc)
	}
	var m sessions.Manifest
	if err := json.Unmarshal([]byte(out), &m); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if m.ID != "2026-05-03T11:30:00Z" {
		t.Errorf("ID = %q", m.ID)
	}
}

func TestSessions_Delete_RoundTrip(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("VKB_SESSIONS_DIR", dir)
	writeFixtureSession(t, dir, "2026-05-03T12:00:00Z")
	if rc := runSessions([]string{"delete", "2026-05-03T12:00:00Z"}); rc != 0 {
		t.Fatalf("delete rc = %d", rc)
	}
	if _, err := os.Stat(filepath.Join(dir, "2026-05-03T12:00:00Z")); !os.IsNotExist(err) {
		t.Errorf("expected dir gone, got err=%v", err)
	}
}

func TestSessions_Clear_RequiresForce(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("VKB_SESSIONS_DIR", dir)
	writeFixtureSession(t, dir, "2026-05-03T13:00:00Z")

	if rc := runSessions([]string{"clear"}); rc == 0 {
		t.Errorf("expected non-zero rc without --force")
	}
	if _, err := os.Stat(filepath.Join(dir, "2026-05-03T13:00:00Z")); err != nil {
		t.Errorf("expected fixture intact, got err=%v", err)
	}

	if rc := runSessions([]string{"clear", "--force"}); rc != 0 {
		t.Errorf("clear --force rc = %d", rc)
	}
	if _, err := os.Stat(filepath.Join(dir, "2026-05-03T13:00:00Z")); !os.IsNotExist(err) {
		t.Errorf("expected fixture gone, got err=%v", err)
	}
}
