package sessions

import (
	"errors"
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

func TestStore_Get_RejectsTraversal(t *testing.T) {
	s := NewStore(t.TempDir())
	for _, bad := range []string{"../escape", "foo/bar", ".."} {
		if _, err := s.Get(bad); err == nil {
			t.Errorf("Get(%q) should reject path traversal", bad)
		}
	}
}

func TestStore_Delete_RemovesFolder(t *testing.T) {
	base := t.TempDir()
	writeFakeSession(t, base, "2026-05-02T14:30:45Z", "default")
	writeFakeSession(t, base, "2026-05-02T14:32:11Z", "minimal")

	s := NewStore(base)
	if err := s.Delete("2026-05-02T14:30:45Z"); err != nil {
		t.Fatalf("Delete: %v", err)
	}
	if _, err := os.Stat(filepath.Join(base, "2026-05-02T14:30:45Z")); !os.IsNotExist(err) {
		t.Errorf("folder not deleted: %v", err)
	}
	// Other session untouched.
	if _, err := os.Stat(filepath.Join(base, "2026-05-02T14:32:11Z")); err != nil {
		t.Errorf("other session affected: %v", err)
	}
}

func TestStore_Delete_UnknownID_NoError(t *testing.T) {
	// Idempotent: deleting a nonexistent session is a no-op, not an error.
	s := NewStore(t.TempDir())
	if err := s.Delete("nope"); err != nil {
		t.Errorf("Delete on missing ID should be no-op, got: %v", err)
	}
}

func TestStore_Delete_RejectsTraversal(t *testing.T) {
	// Defense-in-depth: never let a malicious id escape base.
	s := NewStore(t.TempDir())
	for _, bad := range []string{"../escape", "foo/bar", ".."} {
		if err := s.Delete(bad); err == nil {
			t.Errorf("Delete(%q) should reject path traversal", bad)
		}
	}
}

func TestStore_Clear_RemovesAll(t *testing.T) {
	base := t.TempDir()
	writeFakeSession(t, base, "2026-05-02T14:30:45Z", "default")
	writeFakeSession(t, base, "2026-05-02T14:32:11Z", "minimal")

	s := NewStore(base)
	if err := s.Clear(); err != nil {
		t.Fatalf("Clear: %v", err)
	}
	got, err := s.List()
	if err != nil {
		t.Fatalf("List after clear: %v", err)
	}
	if len(got) != 0 {
		t.Errorf("len after clear = %d, want 0", len(got))
	}
}

func TestStore_Prune_KeepsNMostRecent(t *testing.T) {
	base := t.TempDir()
	for _, id := range []string{
		"2026-05-02T14:28:00Z",
		"2026-05-02T14:29:00Z",
		"2026-05-02T14:30:00Z",
		"2026-05-02T14:31:00Z",
		"2026-05-02T14:32:00Z",
	} {
		writeFakeSession(t, base, id, "default")
	}

	s := NewStore(base)
	if err := s.Prune(3); err != nil {
		t.Fatalf("Prune: %v", err)
	}
	got, _ := s.List()
	if len(got) != 3 {
		t.Fatalf("len after prune = %d, want 3", len(got))
	}
	// Three newest survived.
	want := []string{"2026-05-02T14:32:00Z", "2026-05-02T14:31:00Z", "2026-05-02T14:30:00Z"}
	for i, w := range want {
		if got[i].ID != w {
			t.Errorf("got[%d].ID = %q, want %q", i, got[i].ID, w)
		}
	}
}

func TestStore_Prune_BelowKeep_NoOp(t *testing.T) {
	base := t.TempDir()
	writeFakeSession(t, base, "2026-05-02T14:30:00Z", "default")
	s := NewStore(base)
	if err := s.Prune(10); err != nil {
		t.Fatalf("Prune: %v", err)
	}
	got, _ := s.List()
	if len(got) != 1 {
		t.Errorf("len = %d, want 1 (Prune below threshold should be no-op)", len(got))
	}
}

func TestStore_Prune_KeepZero_NoOp(t *testing.T) {
	base := t.TempDir()
	writeFakeSession(t, base, "2026-05-02T14:30:00Z", "default")
	s := NewStore(base)
	if err := s.Prune(0); err != nil {
		t.Fatalf("Prune(0): %v", err)
	}
	got, _ := s.List()
	if len(got) != 1 {
		t.Errorf("Prune(0) must be no-op; len = %d", len(got))
	}
}

func TestStore_Prune_NegativeKeep_NoOp(t *testing.T) {
	// Defensive: a buggy caller passing a negative keep must not wipe sessions.
	base := t.TempDir()
	writeFakeSession(t, base, "2026-05-02T14:30:00Z", "default")
	s := NewStore(base)
	if err := s.Prune(-1); err != nil {
		t.Fatalf("Prune(-1): %v", err)
	}
	got, _ := s.List()
	if len(got) != 1 {
		t.Errorf("Prune(-1) must be no-op; len = %d", len(got))
	}
}

func TestStore_Prune_KeepEqualsLen_NoOp(t *testing.T) {
	base := t.TempDir()
	writeFakeSession(t, base, "2026-05-02T14:30:00Z", "default")
	writeFakeSession(t, base, "2026-05-02T14:31:00Z", "default")
	s := NewStore(base)
	if err := s.Prune(2); err != nil {
		t.Fatalf("Prune(2): %v", err)
	}
	got, _ := s.List()
	if len(got) != 2 {
		t.Errorf("Prune(keep == len) must be no-op; len = %d", len(got))
	}
}

func TestStore_Prune_KeepOne_KeepsNewest(t *testing.T) {
	base := t.TempDir()
	for _, id := range []string{
		"2026-05-02T14:28:00Z",
		"2026-05-02T14:29:00Z",
		"2026-05-02T14:30:00Z",
	} {
		writeFakeSession(t, base, id, "default")
	}
	s := NewStore(base)
	if err := s.Prune(1); err != nil {
		t.Fatalf("Prune(1): %v", err)
	}
	got, _ := s.List()
	if len(got) != 1 {
		t.Fatalf("len after Prune(1) = %d, want 1", len(got))
	}
	if got[0].ID != "2026-05-02T14:30:00Z" {
		t.Errorf("survivor = %q, want newest %q", got[0].ID, "2026-05-02T14:30:00Z")
	}
}

func TestStore_Clear_PreservesNonDirEntries(t *testing.T) {
	// Clear must skip non-directory entries — a stray .gitkeep, README,
	// or symlink in the base must survive (they aren't sessions).
	base := t.TempDir()
	writeFakeSession(t, base, "2026-05-02T14:30:00Z", "default")
	sentinel := filepath.Join(base, ".gitkeep")
	if err := os.WriteFile(sentinel, []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := NewStore(base).Clear(); err != nil {
		t.Fatalf("Clear: %v", err)
	}
	if _, err := os.Stat(sentinel); err != nil {
		t.Errorf(".gitkeep should survive Clear, got: %v", err)
	}
}

func TestStore_Delete_InvalidID_WrapsSentinel(t *testing.T) {
	s := NewStore(t.TempDir())
	err := s.Delete("../escape")
	if err == nil {
		t.Fatal("expected error")
	}
	if !errors.Is(err, ErrInvalidSessionID) {
		t.Errorf("err = %v, want errors.Is(_, ErrInvalidSessionID)", err)
	}
}

func TestStore_Get_InvalidID_WrapsSentinel(t *testing.T) {
	s := NewStore(t.TempDir())
	_, err := s.Get("foo/bar")
	if err == nil {
		t.Fatal("expected error")
	}
	if !errors.Is(err, ErrInvalidSessionID) {
		t.Errorf("err = %v, want errors.Is(_, ErrInvalidSessionID)", err)
	}
}
