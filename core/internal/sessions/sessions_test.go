package sessions

import (
	"os"
	"path/filepath"
	"testing"
)

// helper: creates a session folder under base with the given id +
// minimal-but-valid manifest. Returns the full session path.
func writeFakeSession(t *testing.T, base, id, preset string) string {
	t.Helper()
	dir := filepath.Join(base, id)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	m := Manifest{Version: 1, ID: id, Preset: preset, DurationSec: 1.0}
	if err := m.Write(dir); err != nil {
		t.Fatal(err)
	}
	return dir
}

func TestStore_List_ReturnsChronologicalOrder(t *testing.T) {
	base := t.TempDir()
	writeFakeSession(t, base, "2026-05-02T14:30:45Z", "default")
	writeFakeSession(t, base, "2026-05-02T14:32:11Z", "minimal")
	writeFakeSession(t, base, "2026-05-02T14:28:12Z", "default")

	s := NewStore(base)
	got, err := s.List()
	if err != nil {
		t.Fatalf("List: %v", err)
	}
	if len(got) != 3 {
		t.Fatalf("len = %d, want 3", len(got))
	}
	// Newest first.
	wantOrder := []string{"2026-05-02T14:32:11Z", "2026-05-02T14:30:45Z", "2026-05-02T14:28:12Z"}
	for i, want := range wantOrder {
		if got[i].ID != want {
			t.Errorf("got[%d].ID = %q, want %q", i, got[i].ID, want)
		}
	}
}

func TestStore_List_SkipsFoldersWithoutManifest(t *testing.T) {
	base := t.TempDir()
	writeFakeSession(t, base, "2026-05-02T14:30:45Z", "default")
	// Folder without a session.json — should be silently skipped.
	if err := os.MkdirAll(filepath.Join(base, "stray-folder"), 0o755); err != nil {
		t.Fatal(err)
	}
	s := NewStore(base)
	got, err := s.List()
	if err != nil {
		t.Fatalf("List: %v", err)
	}
	if len(got) != 1 {
		t.Errorf("len = %d, want 1 (stray folder must be skipped)", len(got))
	}
}

func TestStore_List_SkipsCorruptManifest_LogsAndContinues(t *testing.T) {
	base := t.TempDir()
	writeFakeSession(t, base, "2026-05-02T14:30:45Z", "default")
	corrupt := filepath.Join(base, "2026-05-02T14:99:99Z")
	if err := os.MkdirAll(corrupt, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(corrupt, "session.json"), []byte("not json"), 0o644); err != nil {
		t.Fatal(err)
	}
	s := NewStore(base)
	got, err := s.List()
	if err != nil {
		t.Fatalf("List: %v (one bad manifest must not fail the whole list)", err)
	}
	if len(got) != 1 {
		t.Errorf("len = %d, want 1 (corrupt manifest must be skipped)", len(got))
	}
}

func TestStore_Get_ReturnsManifest(t *testing.T) {
	base := t.TempDir()
	writeFakeSession(t, base, "2026-05-02T14:30:45Z", "default")

	s := NewStore(base)
	got, err := s.Get("2026-05-02T14:30:45Z")
	if err != nil {
		t.Fatalf("Get: %v", err)
	}
	if got.ID != "2026-05-02T14:30:45Z" {
		t.Errorf("ID = %q", got.ID)
	}
}

func TestStore_Get_UnknownID_ReturnsError(t *testing.T) {
	s := NewStore(t.TempDir())
	if _, err := s.Get("nope"); err == nil {
		t.Fatal("expected error for unknown ID")
	}
}

func TestStore_List_EmptyBase_ReturnsEmpty(t *testing.T) {
	s := NewStore(t.TempDir())
	got, err := s.List()
	if err != nil {
		t.Fatalf("List on empty base: %v", err)
	}
	if len(got) != 0 {
		t.Errorf("len = %d, want 0", len(got))
	}
}

func TestStore_List_MissingBase_ReturnsEmpty(t *testing.T) {
	// Pointing at a base that doesn't exist should be a no-op, not an error.
	s := NewStore(filepath.Join(t.TempDir(), "does-not-exist"))
	got, err := s.List()
	if err != nil {
		t.Fatalf("List on missing base: %v", err)
	}
	if len(got) != 0 {
		t.Errorf("len = %d, want 0", len(got))
	}
}
