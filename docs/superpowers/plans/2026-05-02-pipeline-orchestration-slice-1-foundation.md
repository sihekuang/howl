# Pipeline Orchestration UI — Slice 1 (Foundation) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a working "Pipeline → Inspector" Settings tab (Developer-mode-gated) that surfaces per-stage WAVs and transcripts captured automatically from every dictation, plus the `vkb_abi_version()` C ABI seam everything later builds against.

**Architecture:** Add a new `sessions` Go package owning the on-disk session manifest format and the session-folder lifecycle (list/get/delete/clear, prune to N most recent). Extend `recorder.Session` to write the manifest. Wire libvkb's `engine.buildPipeline` to construct a `recorder.Session` rooted under `/tmp/voicekeyboard/sessions/<timestamp>/` whenever `EngineConfig.DeveloperMode == true`. Add five new C ABI exports (`vkb_list_sessions`, `vkb_get_session`, `vkb_delete_session`, `vkb_clear_sessions`, `vkb_abi_version`) returning JSON via the existing `vkb_free_string` ownership convention. On the Swift side, add `developerMode` to `UserSettings` + a toggle in General tab, extend `SettingsPage` with a `.pipeline` case shown only when the toggle is on, scaffold `PipelineTab` + `InspectorView` rendering captured-session listings via a thin `SessionsClient` wrapper over the new C ABI.

**Tech Stack:** Go 1.22+ (existing core), `cgo` for the C ABI, SwiftUI + SwiftPM for the Mac side. No new external dependencies.

---

## File Structure

### Go (new)

- `core/internal/sessions/manifest.go` — session.json schema (versioned), `Manifest` struct, `Read`/`Write` helpers.
- `core/internal/sessions/sessions.go` — `Store` type owning a base directory; `List`/`Get`/`Delete`/`Clear`/`Prune` operations.
- `core/internal/sessions/sessions_test.go` — full coverage of the above.

### Go (modified)

- `core/internal/recorder/recorder.go` — add `Session.WriteManifest(m sessions.Manifest)` so the recorder owns the per-stage WAV writes AND the manifest emission in one place.
- `core/internal/recorder/recorder_test.go` — extend with manifest test.
- `core/internal/config/config.go` — add `DeveloperMode bool` field with `json:"developer_mode"` tag.
- `core/cmd/libvkb/state.go` — in `buildPipeline`, when `e.cfg.DeveloperMode == true`, construct a `recorder.Session` rooted at `/tmp/voicekeyboard/sessions/<RFC3339-timestamp>/` with `AudioStages: true, Transcripts: true`, register the standard stages, and assign to `p.Recorder`.
- `core/cmd/libvkb/exports.go` — new `vkb_list_sessions`, `vkb_get_session`, `vkb_delete_session`, `vkb_clear_sessions`, `vkb_abi_version` exports.
- `core/cmd/libvkb/state.go` — add `engine.sessions *sessions.Store` field; initialize once in `vkb_init`.

### Swift (new)

- `mac/Packages/VoiceKeyboardCore/Sources/VoiceKeyboardCore/Bridge/SessionsClient.swift` — wraps the new C ABI calls; decodes JSON into Swift types.
- `mac/Packages/VoiceKeyboardCore/Sources/VoiceKeyboardCore/Bridge/SessionManifest.swift` — Swift-side decoder for session.json.
- `mac/Packages/VoiceKeyboardCore/Tests/VoiceKeyboardCoreTests/SessionsClientTests.swift` — unit tests with a fake C ABI shim.
- `mac/VoiceKeyboard/UI/Settings/Pipeline/PipelineTab.swift` — top-level container for the Pipeline page.
- `mac/VoiceKeyboard/UI/Settings/Pipeline/InspectorView.swift` — session picker + per-stage row rendering.

### Swift (modified)

- `mac/Packages/VoiceKeyboardCore/Sources/VoiceKeyboardCore/Storage/SettingsStore.swift` — add `developerMode: Bool` (default `false`).
- `mac/Packages/VoiceKeyboardCore/Sources/VoiceKeyboardCore/Bridge/EngineConfig.swift` — add `developerMode: Bool` field with `developer_mode` JSON key.
- `mac/Packages/VoiceKeyboardCore/Tests/VoiceKeyboardCoreTests/SettingsStoreTests.swift` — extend coverage.
- `mac/Packages/VoiceKeyboardCore/Tests/VoiceKeyboardCoreTests/EngineConfigTests.swift` — extend coverage.
- `mac/VoiceKeyboard/Engine/EngineCoordinator.swift` — pass `settings.developerMode` into the `EngineConfig` it builds in `applyConfig`.
- `mac/VoiceKeyboard/UI/Settings/GeneralTab.swift` — append a `Toggle("Developer mode")` row.
- `mac/VoiceKeyboard/UI/Settings/SettingsView.swift` — add `case pipeline` to `SettingsPage`; filter sidebar based on `settings.developerMode`; route `.pipeline` to `PipelineTab(...)`.

---

## Task 1: Session manifest schema

**Files:**
- Create: `core/internal/sessions/manifest.go`
- Test: `core/internal/sessions/manifest_test.go`

- [ ] **Step 1: Write the failing test**

```go
// core/internal/sessions/manifest_test.go
package sessions

import (
	"os"
	"path/filepath"
	"testing"
)

func TestManifest_WriteReadRoundTrip(t *testing.T) {
	dir := t.TempDir()
	m := Manifest{
		Version:     1,
		ID:          "2026-05-02T14:32:11Z",
		Preset:      "default",
		DurationSec: 3.2,
		Stages: []StageEntry{
			{Name: "denoise", Kind: "frame", WavRel: "frame-stages/denoise.wav", RateHz: 48000},
			{Name: "tse", Kind: "chunk", WavRel: "chunk-stages/tse.wav", RateHz: 16000, TSESimilarity: 0.62},
		},
		Transcripts: TranscriptEntries{
			Raw:     "transcripts/raw.txt",
			Dict:    "transcripts/dict.txt",
			Cleaned: "transcripts/cleaned.txt",
		},
	}
	if err := m.Write(dir); err != nil {
		t.Fatalf("Write: %v", err)
	}
	if _, err := os.Stat(filepath.Join(dir, "session.json")); err != nil {
		t.Fatalf("session.json missing: %v", err)
	}
	got, err := Read(dir)
	if err != nil {
		t.Fatalf("Read: %v", err)
	}
	if got.ID != m.ID || got.Preset != m.Preset || len(got.Stages) != 2 {
		t.Errorf("round-trip mismatch: got %+v", got)
	}
	if got.Stages[1].TSESimilarity != 0.62 {
		t.Errorf("TSESimilarity = %v, want 0.62", got.Stages[1].TSESimilarity)
	}
}

func TestManifest_RejectsUnknownVersion(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "session.json"), []byte(`{"version":99,"id":"x"}`), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := Read(dir); err == nil {
		t.Fatal("expected error for version 99")
	}
}

func TestManifest_RejectsMalformedJSON(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "session.json"), []byte(`{not json`), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := Read(dir); err == nil {
		t.Fatal("expected error for malformed JSON")
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd core && go test ./internal/sessions/... -run TestManifest -v`
Expected: FAIL with "package sessions does not exist" or similar — package not yet created.

- [ ] **Step 3: Write the manifest schema**

```go
// core/internal/sessions/manifest.go

// Package sessions owns the per-dictation session folder format used
// by the Pipeline tab's Inspector and Compare views. A session folder
// looks like:
//
//   <base>/<id>/
//   ├── session.json            (Manifest)
//   ├── frame-stages/<stage>.wav
//   ├── chunk-stages/<stage>.wav
//   └── transcripts/{raw,dict,cleaned}.txt
//
// The manifest is the contract between writers (Go pipeline + recorder)
// and readers (Mac Inspector, vkb-cli, replay engine). Versioned at
// birth; new optional fields can be added without bumping `Version`,
// structural changes bump.
package sessions

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
)

// CurrentManifestVersion is the major version this build understands.
// Reader rejects manifests with a different major version.
const CurrentManifestVersion = 1

// Manifest is the on-disk session.json schema.
type Manifest struct {
	Version     int               `json:"version"`
	ID          string            `json:"id"`           // RFC3339 timestamp; matches the folder name
	Preset      string            `json:"preset"`       // name of the preset that produced this session ("default", "custom", ...)
	DurationSec float64           `json:"duration_sec"` // total dictation length
	Stages      []StageEntry      `json:"stages"`
	Transcripts TranscriptEntries `json:"transcripts"`
}

// StageEntry describes one captured stage. WavRel is the path of the
// stage's WAV relative to the session folder (e.g. "frame-stages/denoise.wav").
type StageEntry struct {
	Name          string  `json:"name"`
	Kind          string  `json:"kind"`                       // "frame" | "chunk"
	WavRel        string  `json:"wav"`                        // relative path inside session folder
	RateHz        int     `json:"rate_hz"`                    // output sample rate of this stage
	TSESimilarity float32 `json:"tse_similarity,omitempty"`   // populated only for the TSE stage
}

// TranscriptEntries records the relative paths of the three text outputs.
type TranscriptEntries struct {
	Raw     string `json:"raw"`
	Dict    string `json:"dict"`
	Cleaned string `json:"cleaned"`
}

// Write serializes m to <dir>/session.json (overwriting if present).
// Caller is responsible for ensuring dir exists.
func (m *Manifest) Write(dir string) error {
	if m.Version == 0 {
		m.Version = CurrentManifestVersion
	}
	buf, err := json.MarshalIndent(m, "", "  ")
	if err != nil {
		return fmt.Errorf("sessions: marshal manifest: %w", err)
	}
	if err := os.WriteFile(filepath.Join(dir, "session.json"), buf, 0o644); err != nil {
		return fmt.Errorf("sessions: write manifest: %w", err)
	}
	return nil
}

// Read parses <dir>/session.json and returns the Manifest. Returns an
// error for missing files, malformed JSON, or an unknown major version
// (forward-incompat — caller should treat the session as unreadable
// until the runtime is upgraded).
func Read(dir string) (*Manifest, error) {
	buf, err := os.ReadFile(filepath.Join(dir, "session.json"))
	if err != nil {
		return nil, fmt.Errorf("sessions: read manifest: %w", err)
	}
	var m Manifest
	if err := json.Unmarshal(buf, &m); err != nil {
		return nil, fmt.Errorf("sessions: parse manifest: %w", err)
	}
	if m.Version != CurrentManifestVersion {
		return nil, fmt.Errorf("sessions: unsupported manifest version %d (this build supports %d)", m.Version, CurrentManifestVersion)
	}
	return &m, nil
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd core && go test ./internal/sessions/... -run TestManifest -v`
Expected: PASS — three tests pass.

- [ ] **Step 5: Commit**

```bash
git add core/internal/sessions/manifest.go core/internal/sessions/manifest_test.go
git commit -m "feat(sessions): add session.json manifest schema (v1)"
```

---

## Task 2: Sessions Store — list / get

**Files:**
- Create: `core/internal/sessions/sessions.go`
- Test: `core/internal/sessions/sessions_test.go`

- [ ] **Step 1: Write the failing tests**

```go
// core/internal/sessions/sessions_test.go
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd core && go test ./internal/sessions/... -run TestStore -v`
Expected: FAIL with "undefined: NewStore" — type not yet declared.

- [ ] **Step 3: Implement Store with List + Get**

```go
// core/internal/sessions/sessions.go
package sessions

import (
	"errors"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"sort"
)

// Store owns the on-disk session folder layout under a base directory
// (typically /tmp/voicekeyboard/sessions/). All operations are safe to
// call when base does not exist — they treat that as "no sessions".
type Store struct {
	base string
}

// NewStore returns a Store rooted at the given base directory. The
// directory is created lazily on first write; List/Get on a missing
// base returns the empty/error result without complaint.
func NewStore(base string) *Store {
	return &Store{base: base}
}

// Base returns the underlying base directory. Useful for callers that
// need to construct child paths (e.g. the recorder).
func (s *Store) Base() string { return s.base }

// SessionDir returns the absolute path to a session folder.
func (s *Store) SessionDir(id string) string {
	return filepath.Join(s.base, id)
}

// List returns all valid sessions newest-first. Folders without a
// session.json are silently skipped. Folders with a corrupt manifest
// are skipped + logged, but never fail the whole list.
func (s *Store) List() ([]Manifest, error) {
	entries, err := os.ReadDir(s.base)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil, nil
		}
		return nil, fmt.Errorf("sessions: read base: %w", err)
	}
	out := make([]Manifest, 0, len(entries))
	for _, ent := range entries {
		if !ent.IsDir() {
			continue
		}
		dir := filepath.Join(s.base, ent.Name())
		m, err := Read(dir)
		if err != nil {
			// Tolerant: missing/corrupt manifest = skip with a log,
			// not an error. One bad folder must not break the picker.
			if !errors.Is(err, os.ErrNotExist) {
				log.Printf("[vkb] sessions.List: skipping %s: %v", dir, err)
			}
			continue
		}
		out = append(out, *m)
	}
	// Newest first by ID (which is an RFC3339 timestamp; lexical sort = chronological sort).
	sort.Slice(out, func(i, j int) bool { return out[i].ID > out[j].ID })
	return out, nil
}

// Get returns the manifest for a single session. Returns an error if
// the session does not exist or its manifest is unreadable.
func (s *Store) Get(id string) (*Manifest, error) {
	return Read(s.SessionDir(id))
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd core && go test ./internal/sessions/... -run TestStore -v`
Expected: PASS — all 7 TestStore_* tests pass.

- [ ] **Step 5: Commit**

```bash
git add core/internal/sessions/sessions.go core/internal/sessions/sessions_test.go
git commit -m "feat(sessions): Store.List + Store.Get over session folders"
```

---

## Task 3: Sessions Store — delete / clear / prune

**Files:**
- Modify: `core/internal/sessions/sessions.go` (append methods)
- Modify: `core/internal/sessions/sessions_test.go` (append tests)

- [ ] **Step 1: Append the failing tests**

```go
// Append to core/internal/sessions/sessions_test.go:

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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd core && go test ./internal/sessions/... -run "TestStore_Delete|TestStore_Clear|TestStore_Prune" -v`
Expected: FAIL with "undefined: Delete / Clear / Prune".

- [ ] **Step 3: Append the methods**

```go
// Append to core/internal/sessions/sessions.go:

import "strings"  // add to existing imports

// Delete removes a single session folder. Idempotent: deleting a
// nonexistent ID is a no-op, not an error. Rejects IDs that look like
// path traversal — defense-in-depth, the C ABI is not the place to
// trust caller input.
func (s *Store) Delete(id string) error {
	if !validSessionID(id) {
		return fmt.Errorf("sessions: invalid id %q", id)
	}
	dir := filepath.Join(s.base, id)
	err := os.RemoveAll(dir)
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("sessions: delete %q: %w", id, err)
	}
	return nil
}

// Clear removes every session folder under base. Base directory itself
// is preserved (recreated empty if it already existed).
func (s *Store) Clear() error {
	entries, err := os.ReadDir(s.base)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil
		}
		return fmt.Errorf("sessions: read base: %w", err)
	}
	for _, ent := range entries {
		if !ent.IsDir() {
			continue
		}
		if err := os.RemoveAll(filepath.Join(s.base, ent.Name())); err != nil {
			return fmt.Errorf("sessions: clear %q: %w", ent.Name(), err)
		}
	}
	return nil
}

// Prune keeps the keep-most-recent sessions and removes the rest.
// keep <= 0 is treated as "remove nothing" (defensive — never want a
// caller bug to wipe the whole list). When the existing count is at or
// below keep, Prune is a no-op.
func (s *Store) Prune(keep int) error {
	if keep <= 0 {
		return nil
	}
	all, err := s.List()
	if err != nil {
		return err
	}
	if len(all) <= keep {
		return nil
	}
	// List returns newest-first; older sessions live at the tail.
	for _, m := range all[keep:] {
		if err := s.Delete(m.ID); err != nil {
			return err
		}
	}
	return nil
}

// validSessionID enforces a conservative whitelist for IDs we will
// translate into filesystem paths. Allows the digits, dashes, colons,
// and 'T'/'Z' that RFC3339 timestamps use, plus optional fractional
// seconds (period). Rejects path-separator characters and ".." etc.
func validSessionID(id string) bool {
	if id == "" || id == "." || id == ".." {
		return false
	}
	if strings.ContainsAny(id, `/\` + "\x00") {
		return false
	}
	for _, r := range id {
		switch {
		case r >= '0' && r <= '9',
			r >= 'A' && r <= 'Z',
			r >= 'a' && r <= 'z',
			r == '-' || r == ':' || r == '.' || r == '_':
			// ok
		default:
			return false
		}
	}
	return true
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd core && go test ./internal/sessions/... -v`
Expected: PASS — all sessions tests (manifest + store) pass.

- [ ] **Step 5: Commit**

```bash
git add core/internal/sessions/sessions.go core/internal/sessions/sessions_test.go
git commit -m "feat(sessions): Delete / Clear / Prune with path-traversal guard"
```

---

## Task 4: Recorder — write the manifest at session end

**Files:**
- Modify: `core/internal/recorder/recorder.go`
- Modify: `core/internal/recorder/recorder_test.go`

The recorder already owns per-stage WAVs. Now teach it to emit a `session.json` manifest alongside, populated from a struct the pipeline hands it at session-end.

- [ ] **Step 1: Write the failing test**

```go
// Append to core/internal/recorder/recorder_test.go:

import (
	"github.com/voice-keyboard/core/internal/sessions"
)

func TestSession_WriteManifest(t *testing.T) {
	dir := t.TempDir()
	s, err := Open(Options{Dir: dir, AudioStages: true, Transcripts: true})
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	t.Cleanup(func() { _ = s.Close() })

	m := sessions.Manifest{
		ID:          "2026-05-02T14:32:11Z",
		Preset:      "default",
		DurationSec: 1.5,
		Stages: []sessions.StageEntry{
			{Name: "denoise", Kind: "frame", WavRel: "denoise.wav", RateHz: 48000},
		},
		Transcripts: sessions.TranscriptEntries{Raw: "raw.txt", Dict: "dict.txt", Cleaned: "cleaned.txt"},
	}
	if err := s.WriteManifest(&m); err != nil {
		t.Fatalf("WriteManifest: %v", err)
	}
	got, err := sessions.Read(dir)
	if err != nil {
		t.Fatalf("Read: %v", err)
	}
	if got.ID != m.ID || got.Preset != "default" || len(got.Stages) != 1 {
		t.Errorf("manifest mismatch: got %+v", got)
	}
}

func TestSession_WriteManifest_NilSession_NoOp(t *testing.T) {
	// Recorder methods on nil are no-ops by contract.
	var s *Session
	if err := s.WriteManifest(&sessions.Manifest{ID: "x"}); err != nil {
		t.Errorf("WriteManifest on nil should be no-op, got: %v", err)
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd core && go test ./internal/recorder/... -run TestSession_WriteManifest -v`
Expected: FAIL with "undefined: WriteManifest".

- [ ] **Step 3: Add WriteManifest to recorder.Session**

Append to `core/internal/recorder/recorder.go` after the `WriteTranscript` method (or wherever the public methods cluster):

```go
import "github.com/voice-keyboard/core/internal/sessions"   // add to existing imports

// WriteManifest serializes a session manifest to <dir>/session.json so
// readers (Inspector, vkb-cli) can discover what each WAV represents.
// Caller fills the Manifest with metadata; recorder is the writer
// because it owns the directory the WAVs live in.
//
// No-op when called on a nil *Session.
func (s *Session) WriteManifest(m *sessions.Manifest) error {
	if s == nil {
		return nil
	}
	return m.Write(s.dir)
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd core && go test ./internal/recorder/... -v`
Expected: PASS — all recorder tests including the two new ones.

- [ ] **Step 5: Commit**

```bash
git add core/internal/recorder/recorder.go core/internal/recorder/recorder_test.go
git commit -m "feat(recorder): write session.json manifest alongside per-stage WAVs"
```

---

## Task 5: Add `developer_mode` to EngineConfig (Go)

**Files:**
- Modify: `core/internal/config/config.go`

- [ ] **Step 1: Add the field + default**

Modify `core/internal/config/config.go`. Find the `Config` struct and add a new field near `DisableNoiseSuppression`:

```go
type Config struct {
	WhisperModelPath        string   `json:"whisper_model_path"`
	WhisperModelSize        string   `json:"whisper_model_size"`
	Language                string   `json:"language"`
	DisableNoiseSuppression bool     `json:"disable_noise_suppression"`
	DeepFilterModelPath     string   `json:"deep_filter_model_path"`
	LLMProvider             string   `json:"llm_provider"`
	LLMModel                string   `json:"llm_model"`
	LLMAPIKey               string   `json:"llm_api_key"`
	LLMBaseURL              string   `json:"llm_base_url"`
	CustomDict              []string `json:"custom_dict"`

	// DeveloperMode gates power-user features (always-on per-stage
	// session capture, the Pipeline tab in the Mac app). Casual users
	// keep DeveloperMode == false (the default) and never see the
	// extra UI surface or the temp-folder writes.
	DeveloperMode bool `json:"developer_mode"`

	// ... TSE fields below unchanged ...
	TSEEnabled         bool   `json:"tse_enabled"`
	// ... etc ...
}
```

`WithDefaults` doesn't need updating — `false` is already the zero value and is the right default.

- [ ] **Step 2: Add a config test**

Add to `core/internal/config/config_test.go` (create if it doesn't exist):

```go
package config

import (
	"encoding/json"
	"testing"
)

func TestConfig_DeveloperMode_DefaultFalse(t *testing.T) {
	var c Config
	WithDefaults(&c)
	if c.DeveloperMode {
		t.Error("DeveloperMode default should be false")
	}
}

func TestConfig_DeveloperMode_JSONRoundTrip(t *testing.T) {
	in := Config{DeveloperMode: true}
	buf, err := json.Marshal(in)
	if err != nil {
		t.Fatalf("Marshal: %v", err)
	}
	var out Config
	if err := json.Unmarshal(buf, &out); err != nil {
		t.Fatalf("Unmarshal: %v", err)
	}
	if !out.DeveloperMode {
		t.Errorf("DeveloperMode lost in round-trip; JSON was: %s", buf)
	}
}
```

- [ ] **Step 3: Run tests**

Run: `cd core && go test ./internal/config/... -v`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add core/internal/config/config.go core/internal/config/config_test.go
git commit -m "feat(config): add developer_mode field"
```

---

## Task 6: Wire libvkb to construct a recorder Session when DeveloperMode is on

**Files:**
- Modify: `core/cmd/libvkb/state.go`

- [ ] **Step 1: Read the current `buildPipeline` to confirm where to add the wiring**

Run: `grep -n "buildPipeline\|p := pipeline.New" core/cmd/libvkb/state.go`
Expected: shows the `buildPipeline` function around line 99 and `p := pipeline.New(...)` around line 140.

- [ ] **Step 2: Add `engine.sessions` field**

Edit `core/cmd/libvkb/state.go`. Find the `engine` struct (around line 28) and add a field:

```go
type engine struct {
	mu       sync.Mutex
	cfg      config.Config
	pipeline *pipeline.Pipeline

	// sessions stores captured per-dictation folders under
	// /tmp/voicekeyboard/sessions/. Initialized once in vkb_init;
	// the Pipeline tab + C ABI exports read from this Store.
	sessions *sessions.Store

	// ... existing fields below ...
}
```

Add the import: `"github.com/voice-keyboard/core/internal/sessions"`.

- [ ] **Step 3: Initialize the Store in `vkb_init`**

In `core/cmd/libvkb/exports.go`, find `vkb_init` and update it:

```go
//export vkb_init
func vkb_init() C.int {
	if getEngine() != nil {
		return 0
	}
	setEngine(&engine{
		events:   make(chan event, 32),
		sessions: sessions.NewStore("/tmp/voicekeyboard/sessions"),
	})
	return 0
}
```

Add the import: `"github.com/voice-keyboard/core/internal/sessions"`.

- [ ] **Step 4: Hook recorder into buildPipeline when DeveloperMode is on**

In `core/cmd/libvkb/state.go`, near the bottom of `buildPipeline` (after the TSE wiring, before `return p, nil`), add:

```go
import (
	"path/filepath"
	"time"
	"github.com/voice-keyboard/core/internal/recorder"
	"github.com/voice-keyboard/core/internal/sessions"
)

// ... inside buildPipeline, just before `return p, nil`:

if e.cfg.DeveloperMode && e.sessions != nil {
	// Prune to the last 10 sessions before opening a new one — keeps
	// /tmp from accumulating dictation history forever.
	if err := e.sessions.Prune(10); err != nil {
		log.Printf("[vkb] buildPipeline: session prune failed (continuing): %v", err)
	}
	id := time.Now().UTC().Format("2006-01-02T15:04:05Z")
	dir := e.sessions.SessionDir(id)
	rec, err := recorder.Open(recorder.Options{
		Dir:         dir,
		AudioStages: true,
		Transcripts: true,
	})
	if err != nil {
		log.Printf("[vkb] buildPipeline: recorder open failed (continuing without capture): %v", err)
	} else {
		// Register every stage we know about so AppendStage finds writers.
		// Frame stages: denoise (48k passthrough or DeepFilterNet), decimate3 (48k→16k).
		// Chunk stages: tse (16k).
		// Sample rates here mirror what Pipeline.registerRecorderStages
		// would compute; we register explicitly so the recorder doesn't
		// need to introspect the pipeline.
		if err := rec.AddStage("denoise", 48000); err != nil {
			log.Printf("[vkb] buildPipeline: AddStage(denoise) failed: %v", err)
		}
		if err := rec.AddStage("decimate3", 16000); err != nil {
			log.Printf("[vkb] buildPipeline: AddStage(decimate3) failed: %v", err)
		}
		if e.cfg.TSEEnabled {
			if err := rec.AddStage("tse", 16000); err != nil {
				log.Printf("[vkb] buildPipeline: AddStage(tse) failed: %v", err)
			}
		}
		p.Recorder = rec

		// Stash the session id + dir so the post-run hook (added in
		// Task 7) can write the manifest. Use a closure on the
		// pipeline's existing OnComplete-style hook? — pipeline
		// doesn't have one yet; we'll write the manifest from the
		// capture goroutine in exports.go (Task 7).
		e.activeSessionID = id
		e.activeSessionDir = dir
	}
	_ = filepath.Separator // keep filepath import live until Task 7 references it
}
```

Also extend the engine struct (in `state.go`) with the two new fields:

```go
type engine struct {
	// ... existing fields ...
	sessions         *sessions.Store
	activeSessionID  string
	activeSessionDir string
}
```

- [ ] **Step 5: Build the libvkb dylib to confirm it still links**

Run: `cd core && make build-dylib`
Expected: builds cleanly, no compile errors. (Tests come in Task 7 once the manifest write hook is added.)

- [ ] **Step 6: Commit**

```bash
git add core/cmd/libvkb/state.go core/cmd/libvkb/exports.go
git commit -m "feat(libvkb): construct recorder.Session per dictation when DeveloperMode is on"
```

---

## Task 7: Write the manifest from the capture goroutine

**Files:**
- Modify: `core/cmd/libvkb/exports.go`
- Modify: `core/cmd/libvkb/streaming_test.go`

The capture goroutine in `vkb_start_capture` runs `pipe.Run`, then emits `result` / `error` / `cancelled`. Add a manifest write at the same moment so every captured session has its `session.json`.

- [ ] **Step 1: Write the failing test**

Append to `core/cmd/libvkb/streaming_test.go` (build tag must match — it's already `//go:build whispercpp`):

```go
import (
	"os"
	"path/filepath"

	"github.com/voice-keyboard/core/internal/sessions"
)

// TestCapture_WritesSessionManifest_WhenDeveloperMode runs a fake
// capture cycle with DeveloperMode=true and asserts a session.json
// landed under /tmp/voicekeyboard/sessions/<id>/.
func TestCapture_WritesSessionManifest_WhenDeveloperMode(t *testing.T) {
	t.Skip("end-to-end — requires whisper model; covered by manual smoke + e2e suite")
	// Documentation of intent: when configured with DeveloperMode=true
	// and a real audio buffer pushed via vkb_push_audio, after
	// vkb_stop_capture returns and a result event is observed,
	// e.activeSessionDir must contain a valid session.json whose ID
	// matches e.activeSessionID and whose Preset is the active preset
	// name (or "default" until the presets package lands in Slice 2).
	_ = sessions.Manifest{}
	_ = os.Stat
	_ = filepath.Join
}
```

(The test is skipped because end-to-end coverage requires the Whisper model. The intent stays documented; full e2e arrives in Slice 5.)

- [ ] **Step 2: Implement the manifest write in `vkb_start_capture`**

In `core/cmd/libvkb/exports.go`, find the capture goroutine (the `go func() { ... }()` block in `vkb_start_capture`) and inject the manifest write into the `defer` cleanup so it runs regardless of how the pipeline returned:

```go
defer func() {
	if r := recover(); r != nil {
		msg := fmt.Sprintf("panic: %v", r)
		log.Printf("[vkb] capture goroutine: PANIC %s", msg)
		e.events <- event{Kind: "error", Msg: msg}
	}
	// Snapshot session metadata under the lock so we don't race with
	// a concurrent vkb_configure swapping it out.
	e.mu.Lock()
	sessionID := e.activeSessionID
	sessionDir := e.activeSessionDir
	e.activeSessionID = ""
	e.activeSessionDir = ""
	e.pushCh = nil
	e.cancel = nil
	drops := e.dropCount
	pushes := e.pushCount
	e.dropCount = 0
	e.pushCount = 0
	e.mu.Unlock()

	// Write session.json — best-effort. A missing manifest just makes
	// the session invisible to the Inspector; the WAVs still exist on
	// disk for ad-hoc inspection.
	if sessionID != "" && sessionDir != "" {
		m := sessions.Manifest{
			Version:     sessions.CurrentManifestVersion,
			ID:          sessionID,
			Preset:      "default", // populated correctly once Slice 2 lands the presets package
			DurationSec: 0,         // TODO: pipeline-side accounting in Slice 4 (replay needs precise duration)
			Stages: []sessions.StageEntry{
				{Name: "denoise", Kind: "frame", WavRel: "denoise.wav", RateHz: 48000},
				{Name: "decimate3", Kind: "frame", WavRel: "decimate3.wav", RateHz: 16000},
			},
			Transcripts: sessions.TranscriptEntries{
				Raw: "raw.txt", Dict: "dict.txt", Cleaned: "cleaned.txt",
			},
		}
		// Add tse stage entry iff it was registered.
		e.mu.Lock()
		tseEnabled := e.cfg.TSEEnabled
		e.mu.Unlock()
		if tseEnabled {
			m.Stages = append(m.Stages, sessions.StageEntry{
				Name: "tse", Kind: "chunk", WavRel: "tse.wav", RateHz: 16000,
			})
		}
		if err := m.Write(sessionDir); err != nil {
			log.Printf("[vkb] capture goroutine: manifest write failed: %v", err)
		} else {
			log.Printf("[vkb] capture goroutine: wrote manifest %s/session.json", sessionDir)
		}
	}

	log.Printf("[vkb] capture goroutine: exited (pushes=%d drops=%d)", pushes, drops)
}()
```

Add the import: `"github.com/voice-keyboard/core/internal/sessions"`.

- [ ] **Step 3: Build and run unit tests**

Run: `cd core && go test -tags=whispercpp ./cmd/libvkb/... -v`
Expected: PASS — existing tests still green; the new TestCapture_WritesSessionManifest_WhenDeveloperMode test is SKIPped.

- [ ] **Step 4: Commit**

```bash
git add core/cmd/libvkb/exports.go core/cmd/libvkb/streaming_test.go
git commit -m "feat(libvkb): write session.json from capture goroutine cleanup"
```

---

## Task 8: New C ABI exports — sessions list / get / delete / clear

**Files:**
- Modify: `core/cmd/libvkb/exports.go`

All four wrap `engine.sessions` and return JSON via the existing `vkb_free_string` ownership convention. Add error codes that mirror existing patterns.

- [ ] **Step 1: Add the four exports**

Append at the bottom of `core/cmd/libvkb/exports.go`:

```go
// vkb_list_sessions returns a JSON array of session manifests, newest
// first. Returns NULL on engine-not-initialized; an empty array "[]"
// on no sessions. The returned C string is heap-allocated; the caller
// must free it via vkb_free_string.
//
//export vkb_list_sessions
func vkb_list_sessions() *C.char {
	e := getEngine()
	if e == nil || e.sessions == nil {
		return nil
	}
	manifests, err := e.sessions.List()
	if err != nil {
		e.setLastError("vkb_list_sessions: " + err.Error())
		return nil
	}
	if manifests == nil {
		manifests = []sessions.Manifest{}
	}
	buf, err := json.Marshal(manifests)
	if err != nil {
		e.setLastError("vkb_list_sessions: marshal: " + err.Error())
		return nil
	}
	return C.CString(string(buf))
}

// vkb_get_session returns a JSON-encoded Manifest for the given id, or
// NULL if the session does not exist or its manifest is unreadable.
// Caller frees via vkb_free_string.
//
//export vkb_get_session
func vkb_get_session(idC *C.char) *C.char {
	e := getEngine()
	if e == nil || e.sessions == nil {
		return nil
	}
	id := C.GoString(idC)
	m, err := e.sessions.Get(id)
	if err != nil {
		e.setLastError("vkb_get_session: " + err.Error())
		return nil
	}
	buf, err := json.Marshal(m)
	if err != nil {
		e.setLastError("vkb_get_session: marshal: " + err.Error())
		return nil
	}
	return C.CString(string(buf))
}

// vkb_delete_session removes a single session folder. Idempotent.
// Returns 0 on success, 1 if the engine is not initialized, 5 on
// invalid id (path traversal etc.), 6 on filesystem error.
//
//export vkb_delete_session
func vkb_delete_session(idC *C.char) C.int {
	e := getEngine()
	if e == nil || e.sessions == nil {
		return 1
	}
	id := C.GoString(idC)
	if err := e.sessions.Delete(id); err != nil {
		e.setLastError("vkb_delete_session: " + err.Error())
		// Distinguish bad-id (validation) from disk error.
		if strings.Contains(err.Error(), "invalid id") {
			return 5
		}
		return 6
	}
	return 0
}

// vkb_clear_sessions removes every session folder. Returns 0 on
// success, 1 if engine not initialized, 6 on filesystem error.
//
//export vkb_clear_sessions
func vkb_clear_sessions() C.int {
	e := getEngine()
	if e == nil || e.sessions == nil {
		return 1
	}
	if err := e.sessions.Clear(); err != nil {
		e.setLastError("vkb_clear_sessions: " + err.Error())
		return 6
	}
	return 0
}
```

Add `"strings"` to the import block.

- [ ] **Step 2: Add a Go-side integration test**

Create `core/cmd/libvkb/sessions_export_test.go`:

```go
//go:build whispercpp

package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"github.com/voice-keyboard/core/internal/sessions"
)

// Helper that swaps in a temp Store for a single test, returning a
// cleanup func. Avoids polluting /tmp/voicekeyboard/sessions/.
func withTempSessionsStore(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	if getEngine() == nil {
		_ = vkb_init()
	}
	getEngine().sessions = sessions.NewStore(dir)
	t.Cleanup(func() {
		// Reset to the production location so the next test in the
		// same package binary doesn't see a stale tmpdir.
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
	m := sessions.Manifest{Version: 1, ID: id, Preset: "default"}
	if err := m.Write(dir); err != nil {
		t.Fatal(err)
	}
}

func TestExport_ListSessions_EmptyReturnsEmptyArray(t *testing.T) {
	withTempSessionsStore(t)
	cstr := vkb_list_sessions()
	if cstr == nil {
		t.Fatal("expected non-nil result")
	}
	defer vkb_free_string(cstr)
	var got []sessions.Manifest
	if err := json.Unmarshal([]byte(cString(cstr)), &got); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if len(got) != 0 {
		t.Errorf("len = %d, want 0", len(got))
	}
}

func TestExport_ListSessions_ReturnsManifests(t *testing.T) {
	dir := withTempSessionsStore(t)
	writeSessionFolder(t, dir, "2026-05-02T14:30:45Z")
	writeSessionFolder(t, dir, "2026-05-02T14:32:11Z")

	cstr := vkb_list_sessions()
	defer vkb_free_string(cstr)
	var got []sessions.Manifest
	if err := json.Unmarshal([]byte(cString(cstr)), &got); err != nil {
		t.Fatalf("unmarshal: %v", err)
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

	cstr := vkb_get_session(cBytes("2026-05-02T14:30:45Z"))
	defer vkb_free_string(cstr)
	if cstr == nil {
		t.Fatal("expected non-nil")
	}
	var m sessions.Manifest
	if err := json.Unmarshal([]byte(cString(cstr)), &m); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if m.ID != "2026-05-02T14:30:45Z" {
		t.Errorf("ID = %q", m.ID)
	}
}

func TestExport_GetSession_UnknownReturnsNil(t *testing.T) {
	withTempSessionsStore(t)
	cstr := vkb_get_session(cBytes("does-not-exist"))
	if cstr != nil {
		vkb_free_string(cstr)
		t.Error("expected nil for missing session")
	}
}

func TestExport_DeleteSession_RemovesFolder(t *testing.T) {
	dir := withTempSessionsStore(t)
	writeSessionFolder(t, dir, "2026-05-02T14:30:45Z")

	if rc := vkb_delete_session(cBytes("2026-05-02T14:30:45Z")); rc != 0 {
		t.Fatalf("delete rc=%d", rc)
	}
	if _, err := os.Stat(filepath.Join(dir, "2026-05-02T14:30:45Z")); !os.IsNotExist(err) {
		t.Errorf("folder still present: %v", err)
	}
}

func TestExport_DeleteSession_RejectsTraversal(t *testing.T) {
	withTempSessionsStore(t)
	if rc := vkb_delete_session(cBytes("../escape")); rc != 5 {
		t.Errorf("rc = %d, want 5 (invalid id)", rc)
	}
}

func TestExport_ClearSessions_RemovesAll(t *testing.T) {
	dir := withTempSessionsStore(t)
	writeSessionFolder(t, dir, "2026-05-02T14:30:45Z")
	writeSessionFolder(t, dir, "2026-05-02T14:32:11Z")

	if rc := vkb_clear_sessions(); rc != 0 {
		t.Fatalf("clear rc=%d", rc)
	}
	entries, _ := os.ReadDir(dir)
	if len(entries) != 0 {
		t.Errorf("entries left after clear: %d", len(entries))
	}
}
```

This test file references two helpers (`cString`, `cBytes`) for ergonomic conversion of `*C.char` ↔ Go strings. Add them to the same file:

```go
// cBytes converts a Go string to a NUL-terminated *C.char.
// Caller is responsible for freeing if the API requires it (these
// helpers are test-only, so we leak; tests are short-lived).
func cBytes(s string) *C.char {
	return C.CString(s)
}

// cString reads a *C.char as a Go string.
func cString(p *C.char) string {
	return C.GoString(p)
}
```

Also import `"C"` at the top with the cgo header block. The other `_test.go` file in the package likely already has the cgo prologue — copy from there.

- [ ] **Step 3: Run the new tests**

Run: `cd core && go test -tags=whispercpp ./cmd/libvkb/... -run TestExport -v`
Expected: PASS — all seven TestExport_* tests pass.

- [ ] **Step 4: Commit**

```bash
git add core/cmd/libvkb/exports.go core/cmd/libvkb/sessions_export_test.go
git commit -m "feat(libvkb): vkb_list_sessions / vkb_get_session / vkb_delete_session / vkb_clear_sessions"
```

---

## Task 9: ABI version export

**Files:**
- Modify: `core/cmd/libvkb/exports.go`
- Modify: `core/cmd/libvkb/sessions_export_test.go` (append test)

- [ ] **Step 1: Write the failing test**

Append to `core/cmd/libvkb/sessions_export_test.go`:

```go
func TestExport_AbiVersion_ReturnsExpectedSemver(t *testing.T) {
	// vkb_init not required for the version probe — versioning is a
	// library-level constant.
	cstr := vkb_abi_version()
	if cstr == nil {
		t.Fatal("expected non-nil version string")
	}
	defer vkb_free_string(cstr)
	got := cString(cstr)
	if got != "1.0.0" {
		t.Errorf("version = %q, want 1.0.0", got)
	}
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd core && go test -tags=whispercpp ./cmd/libvkb/... -run TestExport_AbiVersion -v`
Expected: FAIL with "undefined: vkb_abi_version".

- [ ] **Step 3: Add the export**

Append to `core/cmd/libvkb/exports.go`:

```go
// abiVersion is the semver of the libvkb C ABI surface. Bumped when:
//   - major: a function signature changes, or one is removed
//   - minor: a new function is added (additive, back-compat)
//   - patch: a fix that doesn't change the surface (rare)
//
// The Mac app reads this via vkb_abi_version() at startup and asserts
// it matches the major version it was built against. This catches
// dev-build vs. shipped-dylib mismatches that would otherwise crash
// at first call to the new function.
const abiVersion = "1.0.0"

// vkb_abi_version returns the libvkb ABI semver. Caller frees via
// vkb_free_string. Never returns NULL.
//
//export vkb_abi_version
func vkb_abi_version() *C.char {
	return C.CString(abiVersion)
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd core && go test -tags=whispercpp ./cmd/libvkb/... -run TestExport_AbiVersion -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add core/cmd/libvkb/exports.go core/cmd/libvkb/sessions_export_test.go
git commit -m "feat(libvkb): vkb_abi_version returns 1.0.0"
```

---

## Task 10: Mac side — add `developerMode` to UserSettings

**Files:**
- Modify: `mac/Packages/VoiceKeyboardCore/Sources/VoiceKeyboardCore/Storage/SettingsStore.swift`
- Modify: `mac/Packages/VoiceKeyboardCore/Tests/VoiceKeyboardCoreTests/SettingsStoreTests.swift`

- [ ] **Step 1: Write the failing test**

Add to `mac/Packages/VoiceKeyboardCore/Tests/VoiceKeyboardCoreTests/SettingsStoreTests.swift`:

```swift
@Test func userSettings_developerMode_defaultsFalse() {
    let s = UserSettings()
    #expect(s.developerMode == false)
}

@Test func userSettings_developerMode_jsonRoundTrip() throws {
    var s = UserSettings()
    s.developerMode = true
    let data = try JSONEncoder().encode(s)
    let back = try JSONDecoder().decode(UserSettings.self, from: data)
    #expect(back.developerMode == true)
}

@Test func userSettings_developerMode_decodesMissingAsFalse() throws {
    // Forward compat: a v1 blob (no developerMode key) decodes fine
    // with the new field defaulting to false.
    let json = #"{"whisperModelSize":"small","language":"en"}"#.data(using: .utf8)!
    let s = try JSONDecoder().decode(UserSettings.self, from: json)
    #expect(s.developerMode == false)
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd mac && make test 2>&1 | grep -E "developerMode|developer_mode"`
Expected: FAIL — `developerMode` is not a member of `UserSettings`.

- [ ] **Step 3: Add the field**

Edit `SettingsStore.swift`. Find the `UserSettings` struct and add the field next to `tseEnabled`:

```swift
public struct UserSettings: Codable, Equatable, Sendable {
    public var whisperModelSize: String
    public var language: String
    public var disableNoiseSuppression: Bool
    public var llmProvider: String
    public var llmModel: String
    public var llmBaseURL: String
    public var customDict: [String]
    public var hotkey: KeyboardShortcut
    public var inputDeviceUID: String?
    public var tseEnabled: Bool
    /// When true, unlocks the Pipeline Settings tab (live inspector,
    /// per-stage capture, A/B comparison) and tells the engine to
    /// capture every dictation's per-stage WAVs + transcripts to
    /// /tmp/voicekeyboard/sessions/. Default false; casual users
    /// never see the extra surface.
    public var developerMode: Bool

    public init(
        whisperModelSize: String = "small",
        language: String = "en",
        disableNoiseSuppression: Bool = false,
        llmProvider: String = "anthropic",
        llmModel: String = "claude-sonnet-4-6",
        llmBaseURL: String = "",
        customDict: [String] = [],
        hotkey: KeyboardShortcut = .defaultPTT,
        inputDeviceUID: String? = nil,
        tseEnabled: Bool = false,
        developerMode: Bool = false
    ) {
        self.whisperModelSize = whisperModelSize
        self.language = language
        self.disableNoiseSuppression = disableNoiseSuppression
        self.llmProvider = llmProvider
        self.llmModel = llmModel
        self.llmBaseURL = llmBaseURL
        self.customDict = customDict
        self.hotkey = hotkey
        self.inputDeviceUID = inputDeviceUID
        self.tseEnabled = tseEnabled
        self.developerMode = developerMode
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        whisperModelSize = try c.decodeIfPresent(String.self, forKey: .whisperModelSize) ?? "small"
        language = try c.decodeIfPresent(String.self, forKey: .language) ?? "en"
        disableNoiseSuppression = try c.decodeIfPresent(Bool.self, forKey: .disableNoiseSuppression) ?? false
        llmProvider = try c.decodeIfPresent(String.self, forKey: .llmProvider) ?? "anthropic"
        llmModel = try c.decodeIfPresent(String.self, forKey: .llmModel) ?? "claude-sonnet-4-6"
        llmBaseURL = try c.decodeIfPresent(String.self, forKey: .llmBaseURL) ?? ""
        customDict = try c.decodeIfPresent([String].self, forKey: .customDict) ?? []
        hotkey = try c.decodeIfPresent(KeyboardShortcut.self, forKey: .hotkey) ?? .defaultPTT
        inputDeviceUID = try c.decodeIfPresent(String.self, forKey: .inputDeviceUID)
        tseEnabled = try c.decodeIfPresent(Bool.self, forKey: .tseEnabled) ?? false
        developerMode = try c.decodeIfPresent(Bool.self, forKey: .developerMode) ?? false
    }

    enum CodingKeys: String, CodingKey {
        case whisperModelSize, language, disableNoiseSuppression
        case llmProvider, llmModel, llmBaseURL, customDict, hotkey, inputDeviceUID, tseEnabled
        case developerMode
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd mac && make test`
Expected: PASS — all SwiftPM tests including the three new ones.

- [ ] **Step 5: Commit**

```bash
git add mac/Packages/VoiceKeyboardCore/Sources/VoiceKeyboardCore/Storage/SettingsStore.swift \
        mac/Packages/VoiceKeyboardCore/Tests/VoiceKeyboardCoreTests/SettingsStoreTests.swift
git commit -m "feat(mac): add UserSettings.developerMode (default false)"
```

---

## Task 11: Mac side — add `developerMode` to EngineConfig (Swift bridge)

**Files:**
- Modify: `mac/Packages/VoiceKeyboardCore/Sources/VoiceKeyboardCore/Bridge/EngineConfig.swift`
- Modify: `mac/Packages/VoiceKeyboardCore/Tests/VoiceKeyboardCoreTests/EngineConfigTests.swift`

The engine needs to receive the flag so libvkb can wire the recorder. Mirror the JSON key (`developer_mode`) used by `config.Config` on the Go side.

- [ ] **Step 1: Write the failing test**

Add to `EngineConfigTests.swift`:

```swift
@Test func engineConfig_developerMode_jsonKeyIsSnakeCase() throws {
    let cfg = EngineConfig(
        whisperModelPath: "/x", whisperModelSize: "small", language: "en",
        disableNoiseSuppression: false, deepFilterModelPath: "",
        llmProvider: "anthropic", llmModel: "claude", llmAPIKey: "",
        customDict: [],
        developerMode: true
    )
    let data = try JSONEncoder().encode(cfg)
    let json = String(data: data, encoding: .utf8) ?? ""
    #expect(json.contains("\"developer_mode\":true"))
}

@Test func engineConfig_developerMode_defaultsFalse() {
    let cfg = EngineConfig(
        whisperModelPath: "/x", whisperModelSize: "small", language: "en",
        disableNoiseSuppression: false, deepFilterModelPath: "",
        llmProvider: "anthropic", llmModel: "claude", llmAPIKey: "",
        customDict: []
    )
    #expect(cfg.developerMode == false)
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd mac && make test 2>&1 | grep developerMode`
Expected: FAIL — argument or member missing.

- [ ] **Step 3: Add the field to `EngineConfig`**

Edit `EngineConfig.swift`. Add the field next to `tseEnabled`:

```swift
public struct EngineConfig: Codable, Equatable, Sendable {
    // ... existing fields ...
    public var llmBaseURL: String
    public var developerMode: Bool   // NEW
    public var tseEnabled: Bool
    // ...

    public init(
        // ... existing params ...
        llmBaseURL: String = "",
        developerMode: Bool = false,
        tseEnabled: Bool = false,
        // ...
    ) {
        // ...
        self.llmBaseURL = llmBaseURL
        self.developerMode = developerMode
        self.tseEnabled = tseEnabled
        // ...
    }

    enum CodingKeys: String, CodingKey {
        // ... existing cases ...
        case llmBaseURL = "llm_base_url"
        case developerMode = "developer_mode"   // NEW — must match Go's JSON tag
        case tseEnabled = "tse_enabled"
        // ...
    }
}
```

(Read the file first to place the new field/case in the existing layout; the lines above show the *additions*, not a full replacement.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd mac && make test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add mac/Packages/VoiceKeyboardCore/Sources/VoiceKeyboardCore/Bridge/EngineConfig.swift \
        mac/Packages/VoiceKeyboardCore/Tests/VoiceKeyboardCoreTests/EngineConfigTests.swift
git commit -m "feat(mac): add EngineConfig.developerMode bridge field"
```

---

## Task 12: EngineCoordinator — pass developerMode through to the engine

**Files:**
- Modify: `mac/VoiceKeyboard/Engine/EngineCoordinator.swift`

The `applyConfig` function in `EngineCoordinator` builds an `EngineConfig` from `UserSettings` and hands it to the engine. Plumb the new field through.

- [ ] **Step 1: Locate `applyConfig`**

Run: `grep -n "EngineConfig(" /Users/daniel/Documents/Projects/voice-keyboard/mac/VoiceKeyboard/Engine/EngineCoordinator.swift`
Expected: shows the EngineConfig construction site (around line 316).

- [ ] **Step 2: Add `developerMode: settings.developerMode`**

In the `EngineConfig(...)` call inside `applyConfig`, insert the new argument in the same position as in `EngineConfig.init`. For example:

```swift
let cfg = EngineConfig(
    whisperModelPath: modelPath,
    whisperModelSize: resolvedSize,
    language: settings.language,
    disableNoiseSuppression: settings.disableNoiseSuppression,
    deepFilterModelPath: dfModelPath,
    llmProvider: settings.llmProvider,
    llmModel: settings.llmModel,
    llmAPIKey: key,
    customDict: settings.customDict,
    llmBaseURL: settings.llmBaseURL,
    developerMode: settings.developerMode,  // NEW
    tseEnabled: settings.tseEnabled && tseAssetsPresent(),
    tseProfileDir: ModelPaths.voiceProfileDir.path,
    tseModelPath: ModelPaths.tseModel.path,
    speakerEncoderPath: ModelPaths.speakerEncoder.path,
    onnxLibPath: ModelPaths.onnxLib.path
)
```

Update the existing log line in the same function so the toggle state is visible during debugging:

```swift
log.info("applyConfig: whisper=\(resolvedSize, privacy: .public) llm=\(settings.llmProvider, privacy: .public)/\(settings.llmModel, privacy: .public) keyLen=\(key.count, privacy: .public) lang=\(settings.language, privacy: .public) tse=\(cfg.tseEnabled, privacy: .public) devMode=\(settings.developerMode, privacy: .public)")
```

- [ ] **Step 3: Build to verify it compiles**

Run: `cd mac && make build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Commit**

```bash
git add mac/VoiceKeyboard/Engine/EngineCoordinator.swift
git commit -m "feat(mac): EngineCoordinator passes developerMode through to libvkb"
```

---

## Task 13: General tab — Developer mode toggle

**Files:**
- Modify: `mac/VoiceKeyboard/UI/Settings/GeneralTab.swift`

- [ ] **Step 1: Add the toggle row**

Edit the `body` of `GeneralTab.swift`. Find the existing "Open at login" `Toggle` and add a new toggle below it:

```swift
Toggle("Open at login", isOn: Binding(
    get: { launchAtLoginEnabled },
    set: { newValue in
        LaunchAtLogin.setEnabled(newValue)
        launchAtLoginEnabled = LaunchAtLogin.isEnabled
    }
))

VStack(alignment: .leading, spacing: 2) {
    Toggle("Developer mode", isOn: $settings.developerMode)
    Text("Show the Pipeline tab — captures per-stage audio + transcripts to /tmp on every dictation.")
        .font(.caption)
        .foregroundStyle(.secondary)
}
```

The two-line layout (toggle + caption) matches the project's existing pattern for explaining what a setting does. The `$settings.developerMode` binding hooks straight into `UserSettings`, so the existing `.onChange(of: settings) { _, new in onSave(new) }` already persists the change.

- [ ] **Step 2: Build to verify it compiles**

Run: `cd mac && make build`
Expected: BUILD SUCCEEDED. Manually open the app, navigate to Settings → General, confirm the toggle appears below "Open at login" with its caption visible.

- [ ] **Step 3: Commit**

```bash
git add mac/VoiceKeyboard/UI/Settings/GeneralTab.swift
git commit -m "feat(mac): Developer mode toggle in General tab"
```

---

## Task 14: SettingsView — add the Pipeline tab when Developer mode is on

**Files:**
- Modify: `mac/VoiceKeyboard/UI/Settings/SettingsView.swift`

- [ ] **Step 1: Add the new SettingsPage case**

Edit `SettingsView.swift`. Add `case pipeline` to the enum, plus title/icon/color:

```swift
enum SettingsPage: String, CaseIterable, Identifiable {
    case general
    case voice
    case hotkey
    case provider
    case dictionary
    case playground
    case pipeline   // NEW

    var id: Self { self }

    var title: String {
        switch self {
        case .general:    return "General"
        case .voice:      return "Voice"
        case .hotkey:     return "Hotkey"
        case .provider:   return "Provider"
        case .dictionary: return "Dictionary"
        case .playground: return "Playground"
        case .pipeline:   return "Pipeline"   // NEW
        }
    }

    var icon: String {
        switch self {
        case .general:    return "gearshape"
        case .voice:      return "person.wave.2"
        case .hotkey:     return "keyboard"
        case .provider:   return "key"
        case .dictionary: return "books.vertical"
        case .playground: return "waveform"
        case .pipeline:   return "rectangle.connected.to.line.below"   // NEW
        }
    }

    var iconColor: Color {
        switch self {
        case .general:    return .gray
        case .voice:      return .purple
        case .hotkey:     return .blue
        case .provider:   return .orange
        case .dictionary: return .green
        case .playground: return .pink
        case .pipeline:   return .indigo   // NEW
        }
    }
}
```

- [ ] **Step 2: Filter the sidebar based on `settings.developerMode`**

In the `SettingsView.body`, change the `ForEach` over pages so `.pipeline` only shows when Developer mode is on:

```swift
List(selection: $selectedPage) {
    Section("Voice Keyboard") {
        ForEach(visiblePages) { page in
            SidebarRow(page: page).tag(page)
        }
    }
}
.listStyle(.sidebar)
.frame(width: 200)
```

Add a computed property on `SettingsView`:

```swift
private var visiblePages: [SettingsPage] {
    SettingsPage.allCases.filter { page in
        switch page {
        case .pipeline: return settings.developerMode
        default:        return true
        }
    }
}
```

- [ ] **Step 3: Route `.pipeline` to a new `PipelineTab` view**

Inside `DetailView.pageBody`'s switch, add the new case:

```swift
case .pipeline:
    PipelineTab(
        engine: composition.engine,
        sessions: SessionsClient(engine: composition.engine)
    )
```

`SessionsClient` will be created in Task 15; `PipelineTab` in Task 16. The compile will fail at this step — that's expected; finish through Task 16 and then build.

- [ ] **Step 4: Guard against stale selection**

If the user is on the Pipeline tab and toggles Developer mode off, `selectedPage` will refer to a page no longer in `visiblePages` → SwiftUI warning. Reset selection to `.general` when that happens. Add to `SettingsView`:

```swift
.onChange(of: settings.developerMode) { _, on in
    if !on, selectedPage == .pipeline {
        selectedPage = .general
    }
}
```

- [ ] **Step 5: Defer build until Task 16**

The compile will fail until `SessionsClient` and `PipelineTab` exist. We'll build at the end of Task 16.

- [ ] **Step 6: Commit (intentionally non-building intermediate state)**

```bash
git add mac/VoiceKeyboard/UI/Settings/SettingsView.swift
git commit -m "feat(mac): add .pipeline SettingsPage case (Developer mode gated)"
```

This commit doesn't build by itself — that's intentional, the next two tasks add the missing types. Reviewers can still cleanly see what changed in `SettingsView`.

---

## Task 15: SessionsClient — Swift wrapper over the new C ABI

**Files:**
- Create: `mac/Packages/VoiceKeyboardCore/Sources/VoiceKeyboardCore/Bridge/SessionManifest.swift`
- Create: `mac/Packages/VoiceKeyboardCore/Sources/VoiceKeyboardCore/Bridge/SessionsClient.swift`
- Create: `mac/Packages/VoiceKeyboardCore/Tests/VoiceKeyboardCoreTests/SessionsClientTests.swift`

- [ ] **Step 1: Decoder for session.json**

Create `SessionManifest.swift`:

```swift
import Foundation

/// Mirror of Go's sessions.Manifest. Decoded from JSON returned by
/// vkb_list_sessions / vkb_get_session.
public struct SessionManifest: Codable, Equatable, Sendable, Identifiable {
    public let version: Int
    public let id: String
    public let preset: String
    public let durationSec: Double
    public let stages: [Stage]
    public let transcripts: Transcripts

    public struct Stage: Codable, Equatable, Sendable {
        public let name: String
        public let kind: String      // "frame" | "chunk"
        public let wav: String       // path relative to session folder
        public let rateHz: Int
        public let tseSimilarity: Float?

        enum CodingKeys: String, CodingKey {
            case name, kind, wav
            case rateHz = "rate_hz"
            case tseSimilarity = "tse_similarity"
        }
    }

    public struct Transcripts: Codable, Equatable, Sendable {
        public let raw: String
        public let dict: String
        public let cleaned: String
    }

    enum CodingKeys: String, CodingKey {
        case version, id, preset, stages, transcripts
        case durationSec = "duration_sec"
    }
}
```

- [ ] **Step 2: Define the SessionsClient protocol + production impl**

Create `SessionsClient.swift`:

```swift
import Foundation

public enum SessionsClientError: Error {
    case engineUnavailable
    case decode(String)
    case backend(String)
}

/// Thin wrapper over the libvkb session-management C ABI. Constructed
/// against a CoreEngine because the C ABI is a singleton tied to the
/// engine instance — taking the engine as a dependency makes the
/// coupling explicit and lets tests substitute an InMemoryCoreEngine.
public protocol SessionsClient: Sendable {
    func list() throws -> [SessionManifest]
    func get(_ id: String) throws -> SessionManifest
    func delete(_ id: String) throws
    func clear() throws
}

/// Production impl backed by the real C ABI through CoreEngine.
public final class LibVKBSessionsClient: SessionsClient {
    private let engine: any CoreEngine

    public init(engine: any CoreEngine) {
        self.engine = engine
    }

    public func list() throws -> [SessionManifest] {
        guard let json = engine.sessionsListJSON() else {
            // NULL = engine not initialized; never the empty case
            // (Go side returns "[]" for zero sessions).
            throw SessionsClientError.engineUnavailable
        }
        do {
            return try JSONDecoder().decode([SessionManifest].self, from: Data(json.utf8))
        } catch {
            throw SessionsClientError.decode(String(describing: error))
        }
    }

    public func get(_ id: String) throws -> SessionManifest {
        guard let json = engine.sessionGetJSON(id) else {
            throw SessionsClientError.backend(engine.lastError() ?? "session not found")
        }
        do {
            return try JSONDecoder().decode(SessionManifest.self, from: Data(json.utf8))
        } catch {
            throw SessionsClientError.decode(String(describing: error))
        }
    }

    public func delete(_ id: String) throws {
        let rc = engine.sessionDelete(id)
        guard rc == 0 else {
            throw SessionsClientError.backend(engine.lastError() ?? "delete rc=\(rc)")
        }
    }

    public func clear() throws {
        let rc = engine.sessionsClear()
        guard rc == 0 else {
            throw SessionsClientError.backend(engine.lastError() ?? "clear rc=\(rc)")
        }
    }
}
```

- [ ] **Step 3: Add the four new bridge methods to CoreEngine**

`CoreEngine` is the existing protocol that wraps the C ABI. Locate it (likely `mac/Packages/VoiceKeyboardCore/Sources/VoiceKeyboardCore/Bridge/CoreEngine.swift` or similar). Add four methods to the protocol and implement them in the production type:

```swift
// In CoreEngine.swift — add to the protocol:
public protocol CoreEngine: Sendable, AnyObject {
    // ... existing methods ...

    /// Returns the JSON array of session manifests from libvkb, or nil
    /// when the engine is not initialized. nil is distinct from the
    /// empty list case (which returns "[]").
    func sessionsListJSON() -> String?

    /// Returns the JSON manifest for a single session, or nil when the
    /// session does not exist or its manifest is unreadable.
    func sessionGetJSON(_ id: String) -> String?

    /// Deletes a session folder. Returns the C ABI return code
    /// (0 = success, 1 = engine not init, 5 = invalid id, 6 = fs err).
    func sessionDelete(_ id: String) -> Int32

    /// Clears every session folder. Same return-code convention.
    func sessionsClear() -> Int32
}
```

In the production impl (where `vkb_*` C functions are called), add:

```swift
public func sessionsListJSON() -> String? {
    guard let cstr = vkb_list_sessions() else { return nil }
    defer { vkb_free_string(cstr) }
    return String(cString: cstr)
}

public func sessionGetJSON(_ id: String) -> String? {
    return id.withCString { cid -> String? in
        guard let cstr = vkb_get_session(cid) else { return nil }
        defer { vkb_free_string(cstr) }
        return String(cString: cstr)
    }
}

public func sessionDelete(_ id: String) -> Int32 {
    return id.withCString { cid in vkb_delete_session(cid) }
}

public func sessionsClear() -> Int32 {
    return vkb_clear_sessions()
}
```

(If `CoreEngine` lives in a different file or the existing methods use a different name pattern, follow that; the snippets above show shape only.)

- [ ] **Step 4: Add the in-memory test double**

In the same file as the existing `InMemoryCoreEngine` (or alongside, in a test-support file), add corresponding stubs:

```swift
// Inside InMemoryCoreEngine (or whatever the existing test double is called):
public var stubSessionsListJSON: String? = "[]"
public var stubSessionGetJSON: [String: String] = [:]
public var stubSessionDeleteRC: Int32 = 0
public var stubSessionsClearRC: Int32 = 0

public func sessionsListJSON() -> String? { stubSessionsListJSON }
public func sessionGetJSON(_ id: String) -> String? { stubSessionGetJSON[id] }
public func sessionDelete(_ id: String) -> Int32 { stubSessionDeleteRC }
public func sessionsClear() -> Int32 { stubSessionsClearRC }
```

- [ ] **Step 5: Write the unit tests**

Create `SessionsClientTests.swift`:

```swift
import Foundation
import Testing
@testable import VoiceKeyboardCore

@Suite("SessionsClient", .serialized)
struct SessionsClientTests {
    @Test func list_decodesEmptyArray() throws {
        let engine = InMemoryCoreEngine()
        engine.stubSessionsListJSON = "[]"
        let c = LibVKBSessionsClient(engine: engine)
        let got = try c.list()
        #expect(got.isEmpty)
    }

    @Test func list_decodesManifests() throws {
        let json = """
        [
          {"version":1,"id":"2026-05-02T14:32:11Z","preset":"default","duration_sec":3.2,
           "stages":[{"name":"denoise","kind":"frame","wav":"denoise.wav","rate_hz":48000}],
           "transcripts":{"raw":"raw.txt","dict":"dict.txt","cleaned":"cleaned.txt"}}
        ]
        """
        let engine = InMemoryCoreEngine()
        engine.stubSessionsListJSON = json
        let c = LibVKBSessionsClient(engine: engine)
        let got = try c.list()
        #expect(got.count == 1)
        #expect(got[0].id == "2026-05-02T14:32:11Z")
        #expect(got[0].stages[0].rateHz == 48000)
    }

    @Test func list_engineUnavailable_throws() {
        let engine = InMemoryCoreEngine()
        engine.stubSessionsListJSON = nil
        let c = LibVKBSessionsClient(engine: engine)
        #expect(throws: SessionsClientError.self) { try c.list() }
    }

    @Test func get_returnsManifest() throws {
        let engine = InMemoryCoreEngine()
        engine.stubSessionGetJSON["abc"] = """
        {"version":1,"id":"abc","preset":"default","duration_sec":1.0,
         "stages":[],"transcripts":{"raw":"raw.txt","dict":"dict.txt","cleaned":"cleaned.txt"}}
        """
        let c = LibVKBSessionsClient(engine: engine)
        let got = try c.get("abc")
        #expect(got.id == "abc")
    }

    @Test func get_unknownThrows() {
        let engine = InMemoryCoreEngine()
        engine.stubSessionGetJSON = [:]
        let c = LibVKBSessionsClient(engine: engine)
        #expect(throws: SessionsClientError.self) { try c.get("nope") }
    }

    @Test func delete_nonZeroRC_throws() {
        let engine = InMemoryCoreEngine()
        engine.stubSessionDeleteRC = 5
        let c = LibVKBSessionsClient(engine: engine)
        #expect(throws: SessionsClientError.self) { try c.delete("../escape") }
    }

    @Test func clear_zeroRC_succeeds() throws {
        let engine = InMemoryCoreEngine()
        engine.stubSessionsClearRC = 0
        let c = LibVKBSessionsClient(engine: engine)
        try c.clear()  // no throw
    }
}
```

- [ ] **Step 6: Run tests**

Run: `cd mac && make test`
Expected: PASS — all 7 SessionsClient tests pass.

- [ ] **Step 7: Commit**

```bash
git add mac/Packages/VoiceKeyboardCore/Sources/VoiceKeyboardCore/Bridge/SessionManifest.swift \
        mac/Packages/VoiceKeyboardCore/Sources/VoiceKeyboardCore/Bridge/SessionsClient.swift \
        mac/Packages/VoiceKeyboardCore/Sources/VoiceKeyboardCore/Bridge/CoreEngine.swift \
        mac/Packages/VoiceKeyboardCore/Tests/VoiceKeyboardCoreTests/SessionsClientTests.swift
git commit -m "feat(mac): SessionsClient + CoreEngine bridge for libvkb session ABI"
```

---

## Task 16: Pipeline tab + Inspector skeleton

**Files:**
- Create: `mac/VoiceKeyboard/UI/Settings/Pipeline/PipelineTab.swift`
- Create: `mac/VoiceKeyboard/UI/Settings/Pipeline/InspectorView.swift`

Minimal v1 of the Pipeline tab: just the Inspector with a session picker and a per-row breakdown. Editor + Compare arrive in Slices 3-4.

- [ ] **Step 1: Create PipelineTab**

```swift
// mac/VoiceKeyboard/UI/Settings/Pipeline/PipelineTab.swift
import SwiftUI
import VoiceKeyboardCore

/// Container for the Pipeline page. Today: just the Inspector (Slice 1
/// foundation). Slice 2 adds an Editor sub-view; Slice 4 adds a Compare
/// sub-view. The tab will gain a top-level segmented control to switch
/// between them once there's more than one.
struct PipelineTab: View {
    let engine: any CoreEngine
    let sessions: any SessionsClient

    var body: some View {
        SettingsPane {
            InspectorView(sessions: sessions)
        }
    }
}
```

- [ ] **Step 2: Create InspectorView**

```swift
// mac/VoiceKeyboard/UI/Settings/Pipeline/InspectorView.swift
import SwiftUI
import VoiceKeyboardCore
#if canImport(AppKit)
import AppKit
#endif

/// Slice 1 Inspector: session picker + per-row breakdown of the latest
/// captured dictation. Live status indicator + ▶ Play / 📄 View buttons
/// for each stage row. Editing the active pipeline arrives in Slice 3.
struct InspectorView: View {
    let sessions: any SessionsClient

    @State private var sessionList: [SessionManifest] = []
    @State private var selectedID: String? = nil
    @State private var loadError: String? = nil
    @State private var clearConfirmShown = false

    private var selectedSession: SessionManifest? {
        guard let id = selectedID else { return sessionList.first }
        return sessionList.first(where: { $0.id == id })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            sessionBar
            Divider()
            if let s = selectedSession {
                sessionDetail(s)
            } else if let err = loadError {
                Text(err).foregroundStyle(.red).font(.callout)
            } else {
                Text("No captured sessions yet. Dictate something with Developer mode on, then come back.")
                    .foregroundStyle(.secondary).font(.callout)
            }
        }
        .task { await refresh() }
        .alert("Clear all sessions?", isPresented: $clearConfirmShown) {
            Button("Clear all", role: .destructive) { Task { await clearAll() } }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This deletes every captured session under /tmp/voicekeyboard/sessions. The /tmp folder isn't user-visible storage, so this is a quick reset.")
        }
    }

    @ViewBuilder
    private var sessionBar: some View {
        HStack(spacing: 8) {
            Text("Session:").foregroundStyle(.secondary).font(.callout)
            Picker("", selection: Binding(
                get: { selectedID ?? sessionList.first?.id ?? "" },
                set: { selectedID = $0 }
            )) {
                if sessionList.isEmpty {
                    Text("(none)").tag("")
                } else {
                    ForEach(sessionList) { s in
                        Text(label(for: s)).tag(s.id)
                    }
                }
            }
            .labelsHidden()
            .frame(maxWidth: 360)

            Button {
                Task { await refresh() }
            } label: { Image(systemName: "arrow.clockwise") }
            .help("Refresh session list")

            if let s = selectedSession {
                Button {
                    revealInFinder(s)
                } label: { Image(systemName: "folder") }
                .help("Reveal in Finder")
            }

            Spacer()

            Button(role: .destructive) {
                clearConfirmShown = true
            } label: { Image(systemName: "trash") }
            .help("Clear all sessions")
            .disabled(sessionList.isEmpty)
        }
    }

    private func label(for s: SessionManifest) -> String {
        let preset = s.preset.isEmpty ? "—" : s.preset
        return "\(s.id) · \(preset) · \(String(format: "%.1fs", s.durationSec))"
    }

    @ViewBuilder
    private func sessionDetail(_ s: SessionManifest) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(s.stages.enumerated()), id: \.offset) { _, stage in
                stageRow(s, stage: stage)
            }
            Divider().padding(.vertical, 4)
            transcriptRow(label: "raw.txt",     rel: s.transcripts.raw,     in: s)
            transcriptRow(label: "dict.txt",    rel: s.transcripts.dict,    in: s)
            transcriptRow(label: "cleaned.txt", rel: s.transcripts.cleaned, in: s)
        }
    }

    @ViewBuilder
    private func stageRow(_ s: SessionManifest, stage: SessionManifest.Stage) -> some View {
        HStack {
            Text(stage.name).font(.callout).bold()
            Text("(\(stage.kind))").foregroundStyle(.secondary).font(.caption)
            Spacer()
            Text("\(stage.rateHz) Hz").foregroundStyle(.secondary).font(.caption.monospaced())
            Button {
                openInPlayer(sessionID: s.id, relPath: stage.wav)
            } label: { Label("Play", systemImage: "play") }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    @ViewBuilder
    private func transcriptRow(label: String, rel: String, in s: SessionManifest) -> some View {
        HStack {
            Text(label).font(.caption.monospaced()).foregroundStyle(.secondary)
            Spacer()
            Button {
                openInPlayer(sessionID: s.id, relPath: rel)
            } label: { Label("Open", systemImage: "doc.text") }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private func sessionURL(_ id: String, _ rel: String) -> URL {
        URL(fileURLWithPath: "/tmp/voicekeyboard/sessions/\(id)/\(rel)")
    }

    private func openInPlayer(sessionID: String, relPath: String) {
        let url = sessionURL(sessionID, relPath)
        #if canImport(AppKit)
        NSWorkspace.shared.open(url)
        #endif
    }

    private func revealInFinder(_ s: SessionManifest) {
        let url = URL(fileURLWithPath: "/tmp/voicekeyboard/sessions/\(s.id)")
        #if canImport(AppKit)
        NSWorkspace.shared.activateFileViewerSelecting([url])
        #endif
    }

    private func refresh() async {
        do {
            let list = try sessions.list()
            await MainActor.run {
                self.sessionList = list
                self.loadError = nil
                if let id = selectedID, !list.contains(where: { $0.id == id }) {
                    selectedID = nil
                }
            }
        } catch {
            await MainActor.run {
                self.loadError = "Failed to load sessions: \(error)"
            }
        }
    }

    private func clearAll() async {
        do {
            try sessions.clear()
            await refresh()
        } catch {
            await MainActor.run {
                self.loadError = "Clear failed: \(error)"
            }
        }
    }
}
```

- [ ] **Step 3: Build the Mac app**

Run: `cd mac && make build`
Expected: BUILD SUCCEEDED. (This commits Tasks 14–16 worth of compile correctness in one shot.)

- [ ] **Step 4: Manual smoke test**

Launch the app. Confirm:

- General tab shows the new Developer mode toggle.
- With Developer mode OFF: Pipeline tab is NOT in the sidebar.
- Toggle Developer mode ON: Pipeline tab appears.
- Pipeline tab opens; with no captured sessions, shows "No captured sessions yet."
- Press the configured PTT hotkey, dictate something, release. Wait for the result. Open Finder, confirm `/tmp/voicekeyboard/sessions/<timestamp>/` exists with `denoise.wav`, `decimate3.wav`, `raw.txt`, `dict.txt`, `cleaned.txt`, and `session.json`.
- Return to the Pipeline tab, click refresh. Confirm the new session appears in the dropdown. Click Play on a stage row → audio player opens.
- Click trash → confirmation alert → Clear all → list empties.
- Toggle Developer mode OFF: Pipeline tab disappears; selection auto-resets to General if it was on Pipeline.

- [ ] **Step 5: Commit**

```bash
git add mac/VoiceKeyboard/UI/Settings/Pipeline/PipelineTab.swift \
        mac/VoiceKeyboard/UI/Settings/Pipeline/InspectorView.swift
git commit -m "feat(mac): Pipeline tab + Inspector (session picker + per-stage rows)"
```

---

## Task 17: Final integration check + slice commit

- [ ] **Step 1: Run the full Go test suite**

Run: `cd core && go test ./... && go test -tags=whispercpp ./cmd/libvkb/...`
Expected: PASS across all packages.

- [ ] **Step 2: Run the full Mac test suite**

Run: `cd mac && make test`
Expected: PASS — including the new SettingsStore, EngineConfig, and SessionsClient tests.

- [ ] **Step 3: Make a clean Debug build**

Run: `cd mac && make clean && make build`
Expected: BUILD SUCCEEDED from cold.

- [ ] **Step 4: Manual smoke test against a real dictation**

Re-run the Task 16 manual smoke test from a fresh launch to confirm everything stitches together end-to-end.

- [ ] **Step 5: Open a PR**

```bash
git checkout -b feat/pipeline-orchestration-slice-1
git push -u origin feat/pipeline-orchestration-slice-1
gh pr create --base main --title "feat: pipeline orchestration UI — slice 1 (foundation)" \
  --body "First slice of the Pipeline Orchestration UI spec at docs/superpowers/specs/2026-05-02-pipeline-orchestration-ui-design.md.

## Summary

- New \`sessions\` Go package: versioned session.json manifest + Store (List/Get/Delete/Clear/Prune)
- Recorder writes session.json alongside per-stage WAVs
- libvkb constructs a recorder.Session per dictation when DeveloperMode is on
- New C ABI: vkb_list_sessions / vkb_get_session / vkb_delete_session / vkb_clear_sessions / vkb_abi_version
- Mac: UserSettings.developerMode + EngineConfig.developerMode bridge
- General tab: Developer mode toggle
- New Pipeline tab (Developer-mode gated): InspectorView with session picker + per-stage Play / View rows + Clear all

## Test plan

- [x] cd core && go test ./...
- [x] cd core && go test -tags=whispercpp ./cmd/libvkb/...
- [x] cd mac && make test
- [x] cd mac && make build
- [x] Manual smoke: Developer mode toggle ↔ Pipeline tab visibility, dictation produces session folder + manifest, Inspector renders session, Clear all empties list."
```

---

## Self-Review

### Spec coverage check

| Spec section / requirement | Implementing task |
|---|---|
| Developer mode toggle in General tab | Task 13 |
| Pipeline tab in Settings sidebar (Developer mode gated) | Task 14 |
| Inspector view with session picker, ▶ Play, 📄 View, Clear all | Task 16 |
| Always-on capture when Developer mode is on | Task 6 + Task 7 |
| Capture writes per-stage WAVs + transcripts to /tmp/voicekeyboard/sessions/<id>/ | Task 6 (recorder.Session wiring) + Task 7 (manifest) |
| session.json manifest schema, versioned at birth | Task 1 |
| Last-N session retention (default 10) | Task 6 (Prune call before opening new session) |
| C ABI: vkb_list_sessions, vkb_get_session, vkb_delete_session, vkb_clear_sessions | Task 8 |
| C ABI: vkb_abi_version returning "1.0.0" | Task 9 |
| EngineConfig grows by `developer_mode` (additive, no version bump) | Tasks 5 + 11 |
| UserSettings.developerMode field (default false) | Task 10 |
| EngineCoordinator passes developerMode through to engine | Task 12 |
| SessionsClient on Swift side | Task 15 |
| Path-traversal guard on session ids | Task 3 (validSessionID) |

Slice 1 deliverables from the spec all map to a task. Out-of-scope items (presets, edit graph, compare, CLI) are deliberately deferred to Slices 2–5.

### Placeholder scan

- No "TBD" / "TODO" / "implement later" steps. Every code block contains the actual code.
- One TODO comment appears in code (`DurationSec: 0, // TODO: pipeline-side accounting in Slice 4`) — this is a known follow-up annotated with the slice that addresses it, not a missing implementation step.

### Type consistency

- Go: `Manifest`, `StageEntry`, `TranscriptEntries`, `Store`, `validSessionID` all defined and referenced consistently across Tasks 1–4.
- Swift: `SessionManifest`, `SessionsClient`, `LibVKBSessionsClient`, `SessionsClientError` consistent across Tasks 15–16. `developerMode` field name matches across `UserSettings`, `EngineConfig`, the Go `developer_mode` JSON key, and the General tab binding (Tasks 5, 10, 11, 12, 13).
- C ABI: each function declared with its `//export` directive and matching call sites in tests + Swift bridge.

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-05-02-pipeline-orchestration-slice-1-foundation.md`. Two execution options:

**1. Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, review between tasks, fast iteration.

**2. Inline Execution** — Execute tasks in this session using `superpowers:executing-plans`, batch execution with checkpoints.

Which approach?
