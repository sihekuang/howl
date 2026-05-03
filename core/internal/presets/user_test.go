package presets

import (
	"errors"
	"os"
	"path/filepath"
	"testing"
)

func TestSaveUser_RoundTrips(t *testing.T) {
	dir := t.TempDir()
	thr := float32(0.4)
	in := Preset{
		Name: "my-quiet-room", Description: "office",
		ChunkStages: []StageSpec{{Name: "tse", Enabled: true, Backend: "ecapa", Threshold: &thr}},
		Transcribe:  TranscribeSpec{ModelSize: "small"},
		LLM:         LLMSpec{Provider: "anthropic"},
	}
	if err := SaveUserAt(dir, in); err != nil {
		t.Fatalf("SaveUserAt: %v", err)
	}
	got, err := LoadUserAt(dir)
	if err != nil {
		t.Fatalf("LoadUserAt: %v", err)
	}
	if len(got) != 1 || got[0].Name != "my-quiet-room" {
		t.Errorf("got %+v", got)
	}
}

func TestSaveUser_RejectsBundledNameCollision(t *testing.T) {
	dir := t.TempDir()
	for _, bad := range []string{"default", "minimal", "aggressive", "paranoid"} {
		err := SaveUserAt(dir, Preset{Name: bad})
		if !errors.Is(err, ErrReservedName) {
			t.Errorf("SaveUserAt(%q) error = %v, want ErrReservedName", bad, err)
		}
	}
}

func TestSaveUser_RejectsInvalidName(t *testing.T) {
	dir := t.TempDir()
	for _, bad := range []string{
		"", "UPPERCASE", "has space", "../escape", "foo/bar",
		"way-too-long-name-that-exceeds-forty-characters-easily",
	} {
		if err := SaveUserAt(dir, Preset{Name: bad}); !errors.Is(err, ErrInvalidName) {
			t.Errorf("SaveUserAt(%q) error = %v, want ErrInvalidName", bad, err)
		}
	}
}

func TestLoadUser_SkipsMalformedPreset_LogsAndContinues(t *testing.T) {
	dir := t.TempDir()
	// One valid file, one corrupt file.
	if err := SaveUserAt(dir, Preset{Name: "good", LLM: LLMSpec{Provider: "anthropic"}, Transcribe: TranscribeSpec{ModelSize: "small"}}); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "bad.json"), []byte("{not json"), 0o644); err != nil {
		t.Fatal(err)
	}

	got, err := LoadUserAt(dir)
	if err != nil {
		t.Fatalf("LoadUserAt: %v (one bad file must not fail load)", err)
	}
	if len(got) != 1 {
		t.Errorf("len = %d, want 1 (corrupt file should be skipped)", len(got))
	}
}

func TestDeleteUser_RemovesFile(t *testing.T) {
	dir := t.TempDir()
	if err := SaveUserAt(dir, Preset{Name: "tmp", LLM: LLMSpec{Provider: "anthropic"}, Transcribe: TranscribeSpec{ModelSize: "small"}}); err != nil {
		t.Fatal(err)
	}
	if err := DeleteUserAt(dir, "tmp"); err != nil {
		t.Fatalf("DeleteUserAt: %v", err)
	}
	if _, err := os.Stat(filepath.Join(dir, "tmp.json")); !os.IsNotExist(err) {
		t.Errorf("file not deleted: %v", err)
	}
}

func TestDeleteUser_RejectsBundled(t *testing.T) {
	dir := t.TempDir()
	for _, bad := range []string{"default", "minimal", "aggressive", "paranoid"} {
		if err := DeleteUserAt(dir, bad); !errors.Is(err, ErrReservedName) {
			t.Errorf("DeleteUserAt(%q) error = %v, want ErrReservedName", bad, err)
		}
	}
}

func TestDeleteUser_UnknownIsNoOp(t *testing.T) {
	dir := t.TempDir()
	if err := DeleteUserAt(dir, "nope"); err != nil {
		t.Errorf("DeleteUserAt on missing should be no-op: %v", err)
	}
}
