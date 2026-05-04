# Pipeline Orchestration — Slice 5 (CLI parity) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bring `vkb-cli` to parity with the Mac app's Pipeline tab. The Mac app and `vkb-cli` are both consumers of the same Go primitives (`presets`, `sessions`, `replay`); Slice 5 wires those into CLI subcommands so power users can list/show/save/delete presets, list/show/delete/clear captured sessions, A/B-compare presets against a captured session, and run `pipe --preset <name>` with per-flag overrides layered on top.

**Architecture:** New per-subcommand files under `core/cmd/vkb-cli/`, each owning a `*flag.FlagSet` exactly like the existing `pipe`, `transcribe`, `check`, `backends`, `providers` subcommands. No new dependencies — `flag` package only. Subcommands import the existing `core/internal/{presets,sessions,replay}` packages directly. The `presets` and `sessions` subcommands compile without the `whispercpp` build tag (no Whisper dependency); `compare` and `pipe --preset` are whispercpp-tagged because they actually drive the pipeline.

**Tech Stack:** Go 1.22+ (`flag`, `text/tabwriter`, `encoding/json`), the existing presets/sessions/replay packages. No SwiftUI in this slice.

---

## File Structure

### Go (new)

- `core/cmd/vkb-cli/presets.go` — `runPresets(args []string) int`. Dispatches `list`/`show`/`save`/`delete` to per-action helpers. Always builds (no whispercpp tag).
- `core/cmd/vkb-cli/presets_test.go` — unit tests: argument parsing, JSON-vs-table output, save validation, delete idempotency.
- `core/cmd/vkb-cli/sessions.go` — `runSessions(args []string) int`. Dispatches `list`/`show`/`delete`/`clear`. Always builds.
- `core/cmd/vkb-cli/sessions_test.go` — unit tests using a temp `sessions.NewStore` against a `t.TempDir()`.
- `core/cmd/vkb-cli/compare.go` — `runCompare(args []string) int`. Whispercpp-tagged.
- `core/cmd/vkb-cli/compare_stub.go` — stub for non-whispercpp builds (parity with `pipe_stub.go`).
- `core/cmd/vkb-cli/compare_test.go` — argument-parsing tests (whispercpp-tagged where needed).
- `core/cmd/vkb-cli/sessions_path.go` — small helper `defaultSessionsBase()` returning `/tmp/voicekeyboard/sessions` with a `VKB_SESSIONS_DIR` override hook for tests.
- `core/cmd/vkb-cli/e2e_test.go` — end-to-end smoke tests (`-tags=e2e,whispercpp`). Builds the binary, runs `presets list`, `sessions list`, then `pipe --preset default` if a model is available; otherwise skips the pipe step.
- `core/cmd/vkb-cli/README.md` — one example per new subcommand.

### Go (modified)

- `core/cmd/vkb-cli/main.go` — add `presets`, `sessions`, `compare` cases to the switch + extend the `usage()` text.
- `core/cmd/vkb-cli/pipe.go` — accept `--preset <name>` flag; layer the resolved preset before the existing per-flag overrides.

### Documentation (modified)

- `README.md` (root) — new `## CLI` section showing `presets list`, `sessions list`, `pipe --preset`, `compare`.

---

## Phase A — Shared scaffolding

### Task 1: Sessions-path helper + main.go dispatch hooks

**Files:**
- Create: `core/cmd/vkb-cli/sessions_path.go`
- Modify: `core/cmd/vkb-cli/main.go`

The presets/sessions/compare subcommands all need to know where sessions live. Lift the path into one helper so tests can override via `VKB_SESSIONS_DIR`. Wire dispatch stubs in `main.go` so subsequent tasks have a place to plug in.

- [ ] **Step 1: Write `sessions_path.go`**

```go
package main

import "os"

// defaultSessionsBase returns the on-disk root that the recorder and
// libvkb engine write to (and read from). VKB_SESSIONS_DIR is honored
// for tests so they can route reads/writes to a tempdir without
// stomping on /tmp/voicekeyboard/sessions/.
func defaultSessionsBase() string {
	if dir := os.Getenv("VKB_SESSIONS_DIR"); dir != "" {
		return dir
	}
	return "/tmp/voicekeyboard/sessions"
}
```

- [ ] **Step 2: Add stub dispatch in `main.go`**

Insert three new cases ahead of `-h/--help/help`:

```go
case "presets":
    os.Exit(runPresets(os.Args[2:]))
case "sessions":
    os.Exit(runSessions(os.Args[2:]))
case "compare":
    os.Exit(runCompare(os.Args[2:]))
```

Update `usage()` to mention the new subcommands.

- [ ] **Step 3: Commit (after Task 2 lands a real `runPresets`)**

We commit the scaffolding alongside Task 2 so `go build` stays green throughout.

---

## Phase B — Presets subcommand

### Task 2: `vkb-cli presets list|show|save|delete`

**Files:**
- Create: `core/cmd/vkb-cli/presets.go`
- Create: `core/cmd/vkb-cli/presets_test.go`

Subcommand contract:

```
vkb-cli presets list                                   table or --json
vkb-cli presets show <name>                            human-readable spec or --json
vkb-cli presets save <name> [--description "..."] [--from <session-id>]
vkb-cli presets delete <name>                          user presets only
```

`save` semantics: when `--from <session-id>` is given, read the session manifest and clone its `preset` field's spec; otherwise clone bundled `default`. Either path produces a fresh user preset under the supplied `<name>`.

- [ ] **Step 1: Write the failing test (action dispatch + `list`)**

```go
package main

import (
	"bytes"
	"encoding/json"
	"io"
	"os"
	"strings"
	"testing"

	"github.com/voice-keyboard/core/internal/presets"
)

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
	rc := runPresets(nil)
	if rc == 0 {
		t.Fatal("expected non-zero rc when no action given")
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
}

func TestPresets_Show_UnknownName(t *testing.T) {
	rc := runPresets([]string{"show", "no-such-preset-xyz"})
	if rc == 0 {
		t.Errorf("expected non-zero rc for unknown preset")
	}
}

func TestPresets_Show_KnownName_JSON(t *testing.T) {
	out, rc := captureStdout(t, func() int { return runPresets([]string{"show", "default", "--json"}) })
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

	if rc := runPresets([]string{"save", "my-clone"}); rc != 0 {
		t.Fatalf("save rc = %d", rc)
	}
	all, _ := presets.LoadUserAt(dir)
	if len(all) != 1 || all[0].Name != "my-clone" {
		t.Fatalf("expected one user preset 'my-clone', got %+v", all)
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
	rc := runPresets([]string{"save", "default"})
	if rc == 0 {
		t.Errorf("expected non-zero rc when saving over bundled name")
	}
}

// silence unused import warnings if any tests are commented out
var _ = bytes.NewBuffer
```

- [ ] **Step 2: Run to verify failure**

Run: `cd core && go test ./cmd/vkb-cli/... -run TestPresets -v`
Expected: FAIL — `runPresets` undefined.

- [ ] **Step 3: Implement `presets.go`**

```go
package main

import (
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"text/tabwriter"

	"github.com/voice-keyboard/core/internal/presets"
	"github.com/voice-keyboard/core/internal/sessions"
)

func runPresets(args []string) int {
	if len(args) == 0 {
		fmt.Fprintln(os.Stderr, "usage: vkb-cli presets {list|show|save|delete} ...")
		return 2
	}
	switch args[0] {
	case "list":
		return presetsList(args[1:])
	case "show":
		return presetsShow(args[1:])
	case "save":
		return presetsSave(args[1:])
	case "delete":
		return presetsDelete(args[1:])
	default:
		fmt.Fprintf(os.Stderr, "unknown presets action: %s\n", args[0])
		return 2
	}
}

func presetsList(args []string) int {
	fs := flag.NewFlagSet("presets list", flag.ContinueOnError)
	asJSON := fs.Bool("json", false, "emit JSON array instead of a table")
	if err := fs.Parse(args); err != nil {
		return 2
	}
	all, err := presets.Load()
	if err != nil {
		fmt.Fprintf(os.Stderr, "load presets: %v\n", err)
		return 1
	}
	if *asJSON {
		buf, err := json.MarshalIndent(all, "", "  ")
		if err != nil {
			fmt.Fprintf(os.Stderr, "marshal: %v\n", err)
			return 1
		}
		fmt.Println(string(buf))
		return 0
	}
	bundled := bundledNameSet()
	w := tabwriter.NewWriter(os.Stdout, 0, 0, 2, ' ', 0)
	fmt.Fprintln(w, "NAME\tSOURCE\tDESCRIPTION")
	for _, p := range all {
		source := "user"
		if bundled[p.Name] {
			source = "bundled"
		}
		fmt.Fprintf(w, "%s\t%s\t%s\n", p.Name, source, p.Description)
	}
	_ = w.Flush()
	return 0
}

func presetsShow(args []string) int {
	fs := flag.NewFlagSet("presets show", flag.ContinueOnError)
	asJSON := fs.Bool("json", false, "emit preset JSON instead of human format")
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if fs.NArg() != 1 {
		fmt.Fprintln(os.Stderr, "usage: vkb-cli presets show <name> [--json]")
		return 2
	}
	name := fs.Arg(0)
	p, err := lookupPreset(name)
	if err != nil {
		fmt.Fprintf(os.Stderr, "%v\n", err)
		return 1
	}
	if *asJSON {
		buf, err := json.MarshalIndent(p, "", "  ")
		if err != nil {
			fmt.Fprintf(os.Stderr, "marshal: %v\n", err)
			return 1
		}
		fmt.Println(string(buf))
		return 0
	}
	printPresetHuman(p)
	return 0
}

func presetsSave(args []string) int {
	fs := flag.NewFlagSet("presets save", flag.ContinueOnError)
	desc := fs.String("description", "", "preset description")
	from := fs.String("from", "", "session id to clone preset from (otherwise clones bundled 'default')")
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if fs.NArg() != 1 {
		fmt.Fprintln(os.Stderr, "usage: vkb-cli presets save <name> [--description \"...\"] [--from <session-id>]")
		return 2
	}
	name := fs.Arg(0)

	var src presets.Preset
	if *from != "" {
		store := sessions.NewStore(defaultSessionsBase())
		m, err := store.Get(*from)
		if err != nil {
			fmt.Fprintf(os.Stderr, "session %q: %v\n", *from, err)
			return 1
		}
		clone, err := lookupPreset(m.Preset)
		if err != nil {
			fmt.Fprintf(os.Stderr, "session %q referenced preset %q which is unavailable: %v\n", *from, m.Preset, err)
			return 1
		}
		src = clone
	} else {
		clone, err := lookupPreset("default")
		if err != nil {
			fmt.Fprintf(os.Stderr, "load default preset: %v\n", err)
			return 1
		}
		src = clone
	}

	src.Name = name
	if *desc != "" {
		src.Description = *desc
	}

	if err := presets.SaveUser(src); err != nil {
		fmt.Fprintf(os.Stderr, "save: %v\n", err)
		if errors.Is(err, presets.ErrInvalidName) || errors.Is(err, presets.ErrReservedName) {
			return 2
		}
		return 1
	}
	dir := userPresetsDirForReport()
	fmt.Fprintf(os.Stderr, "[vkb] saved user preset %q to %s\n", name, filepath.Join(dir, name+".json"))
	return 0
}

func presetsDelete(args []string) int {
	fs := flag.NewFlagSet("presets delete", flag.ContinueOnError)
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if fs.NArg() != 1 {
		fmt.Fprintln(os.Stderr, "usage: vkb-cli presets delete <name>")
		return 2
	}
	name := fs.Arg(0)
	if err := presets.DeleteUser(name); err != nil {
		fmt.Fprintf(os.Stderr, "delete: %v\n", err)
		if errors.Is(err, presets.ErrInvalidName) || errors.Is(err, presets.ErrReservedName) {
			return 2
		}
		return 1
	}
	return 0
}

func lookupPreset(name string) (presets.Preset, error) {
	all, err := presets.Load()
	if err != nil {
		return presets.Preset{}, fmt.Errorf("load presets: %w", err)
	}
	for _, p := range all {
		if p.Name == name {
			return p, nil
		}
	}
	return presets.Preset{}, fmt.Errorf("preset not found: %q", name)
}

// bundledNameSet enumerates bundled names so the 'list' table can mark
// each row's source. We re-use Load() and rely on the fact that bundled
// presets always come first (loadBundled before user) — but we
// double-check by parsing the embedded bundle directly.
func bundledNameSet() map[string]bool {
	out := map[string]bool{"default": true, "minimal": true, "aggressive": true, "paranoid": true}
	// Not strictly necessary to re-parse; presets package's reservedNames
	// is unexported. Hard-coding the four bundled names as a fallback
	// is fine for `list` cosmetics — `save` does the real validation
	// against presets.SaveUserAt, which checks reservedNames itself.
	return out
}

func userPresetsDirForReport() string {
	if dir := os.Getenv("VKB_PRESETS_USER_DIR"); dir != "" {
		return dir
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return "<user dir>"
	}
	return filepath.Join(home, "Library", "Application Support", "VoiceKeyboard", "presets")
}

func printPresetHuman(p presets.Preset) {
	fmt.Printf("Name:        %s\n", p.Name)
	fmt.Printf("Description: %s\n", p.Description)
	if p.TimeoutSec != nil {
		fmt.Printf("Timeout:     %ds\n", *p.TimeoutSec)
	} else {
		fmt.Println("Timeout:     (unset; engine default)")
	}
	fmt.Printf("Transcribe:  model_size=%s\n", p.Transcribe.ModelSize)
	fmt.Printf("LLM:         provider=%s\n", p.LLM.Provider)
	fmt.Println("Frame stages:")
	for _, st := range p.FrameStages {
		fmt.Printf("  - %-10s enabled=%t\n", st.Name, st.Enabled)
	}
	fmt.Println("Chunk stages:")
	for _, st := range p.ChunkStages {
		thr := "(unset)"
		if st.Threshold != nil {
			thr = fmt.Sprintf("%.2f", *st.Threshold)
		}
		fmt.Printf("  - %-10s enabled=%t backend=%s threshold=%s\n", st.Name, st.Enabled, st.Backend, thr)
	}
}
```

The intentional choice on `bundledNameSet`: the `presets` package exposes `Load()` (bundled+user merged) but not a "just bundled" entry-point. Hard-coding the four bundled names for the `list` table's `SOURCE` column is acceptable cosmetic. Real validation lives in `presets.SaveUser` which checks the unexported `reservedNames` map sourced from `loadBundled`. If a future bundled preset is added, the `list` table will mis-label it as "user" until the cosmetic list is updated — caught by the table-output test (which only asserts presence of "default" today; a future test can pin the SOURCE column).

- [ ] **Step 4: Wire dispatch in `main.go`**

Add the three new switch cases and update `usage()`. Stub `runSessions` and `runCompare` to return 0 with a "not yet" message until subsequent tasks land — wait, this would leave `go build` green but the binary would silently misbehave. Better: only add the `presets` case in this commit. The `sessions` and `compare` cases ride along with their own task commits.

So in this task: add only `case "presets":` to main.go. Update `usage()` to advertise just `presets`.

- [ ] **Step 5: Run tests**

```
cd core && go build ./... && go test ./cmd/vkb-cli/... -run TestPresets -v
```

Expected: PASS — 7 tests.

- [ ] **Step 6: Commit**

```
git add core/cmd/vkb-cli/sessions_path.go \
        core/cmd/vkb-cli/presets.go \
        core/cmd/vkb-cli/presets_test.go \
        core/cmd/vkb-cli/main.go
git commit -m "feat(vkb-cli): presets list/show/save/delete subcommands"
```

---

## Phase C — Sessions subcommand

### Task 3: `vkb-cli sessions list|show|delete|clear`

**Files:**
- Create: `core/cmd/vkb-cli/sessions.go`
- Create: `core/cmd/vkb-cli/sessions_test.go`
- Modify: `core/cmd/vkb-cli/main.go`

Subcommand contract:

```
vkb-cli sessions list [--json]          ID, timestamp, preset, duration, cleaned-transcript preview
vkb-cli sessions show <id> [--json]     full manifest
vkb-cli sessions delete <id>            single session
vkb-cli sessions clear [--force]        all sessions
```

`clear --force` is required; without it, the command refuses to run (defensive — the only way someone runs `sessions clear` without realising is from a script, and `--force` is cheap insurance).

- [ ] **Step 1: Write the failing test**

```go
package main

import (
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/voice-keyboard/core/internal/sessions"
)

func writeFixtureSession(t *testing.T, base, id string) {
	t.Helper()
	dir := filepath.Join(base, id)
	if err := os.MkdirAll(dir, 0o755); err != nil {
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
}

func TestSessions_NoArgs_ShowsUsage(t *testing.T) {
	if rc := runSessions(nil); rc == 0 {
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

func TestSessions_Show_UnknownID(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("VKB_SESSIONS_DIR", dir)
	if rc := runSessions([]string{"show", "no-such-id"}); rc == 0 {
		t.Errorf("expected non-zero rc")
	}
}

func TestSessions_Show_KnownID_JSON(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("VKB_SESSIONS_DIR", dir)
	writeFixtureSession(t, dir, "2026-05-03T11:00:00Z")
	out, rc := captureStdout(t, func() int {
		return runSessions([]string{"show", "2026-05-03T11:00:00Z", "--json"})
	})
	if rc != 0 {
		t.Fatalf("rc = %d", rc)
	}
	var m sessions.Manifest
	if err := json.Unmarshal([]byte(out), &m); err != nil {
		t.Fatalf("unmarshal: %v", err)
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

var _ = io.Discard
```

- [ ] **Step 2: Run to verify failure**

Run: `cd core && go test ./cmd/vkb-cli/... -run TestSessions -v`
Expected: FAIL.

- [ ] **Step 3: Implement `sessions.go`**

```go
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"text/tabwriter"

	"github.com/voice-keyboard/core/internal/sessions"
)

func runSessions(args []string) int {
	if len(args) == 0 {
		fmt.Fprintln(os.Stderr, "usage: vkb-cli sessions {list|show|delete|clear} ...")
		return 2
	}
	switch args[0] {
	case "list":
		return sessionsList(args[1:])
	case "show":
		return sessionsShow(args[1:])
	case "delete":
		return sessionsDelete(args[1:])
	case "clear":
		return sessionsClear(args[1:])
	default:
		fmt.Fprintf(os.Stderr, "unknown sessions action: %s\n", args[0])
		return 2
	}
}

func sessionsList(args []string) int {
	fs := flag.NewFlagSet("sessions list", flag.ContinueOnError)
	asJSON := fs.Bool("json", false, "emit JSON array instead of a table")
	if err := fs.Parse(args); err != nil {
		return 2
	}
	store := sessions.NewStore(defaultSessionsBase())
	all, err := store.List()
	if err != nil {
		fmt.Fprintf(os.Stderr, "list: %v\n", err)
		return 1
	}
	if *asJSON {
		if all == nil {
			all = []sessions.Manifest{}
		}
		buf, err := json.MarshalIndent(all, "", "  ")
		if err != nil {
			fmt.Fprintf(os.Stderr, "marshal: %v\n", err)
			return 1
		}
		fmt.Println(string(buf))
		return 0
	}
	w := tabwriter.NewWriter(os.Stdout, 0, 0, 2, ' ', 0)
	fmt.Fprintln(w, "ID\tPRESET\tDURATION\tCLEANED")
	for _, m := range all {
		preview := readTranscriptPreview(store.SessionDir(m.ID), m.Transcripts.Cleaned, 60)
		fmt.Fprintf(w, "%s\t%s\t%.2fs\t%s\n", m.ID, m.Preset, m.DurationSec, preview)
	}
	_ = w.Flush()
	return 0
}

func sessionsShow(args []string) int {
	fs := flag.NewFlagSet("sessions show", flag.ContinueOnError)
	asJSON := fs.Bool("json", false, "emit manifest JSON")
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if fs.NArg() != 1 {
		fmt.Fprintln(os.Stderr, "usage: vkb-cli sessions show <id> [--json]")
		return 2
	}
	id := fs.Arg(0)
	store := sessions.NewStore(defaultSessionsBase())
	m, err := store.Get(id)
	if err != nil {
		fmt.Fprintf(os.Stderr, "show: %v\n", err)
		return 1
	}
	if *asJSON {
		buf, err := json.MarshalIndent(m, "", "  ")
		if err != nil {
			fmt.Fprintf(os.Stderr, "marshal: %v\n", err)
			return 1
		}
		fmt.Println(string(buf))
		return 0
	}
	printSessionHuman(store.SessionDir(id), m)
	return 0
}

func sessionsDelete(args []string) int {
	fs := flag.NewFlagSet("sessions delete", flag.ContinueOnError)
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if fs.NArg() != 1 {
		fmt.Fprintln(os.Stderr, "usage: vkb-cli sessions delete <id>")
		return 2
	}
	store := sessions.NewStore(defaultSessionsBase())
	if err := store.Delete(fs.Arg(0)); err != nil {
		fmt.Fprintf(os.Stderr, "delete: %v\n", err)
		return 1
	}
	return 0
}

func sessionsClear(args []string) int {
	fs := flag.NewFlagSet("sessions clear", flag.ContinueOnError)
	force := fs.Bool("force", false, "required to actually delete")
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if !*force {
		fmt.Fprintln(os.Stderr, "refusing to clear without --force")
		return 2
	}
	store := sessions.NewStore(defaultSessionsBase())
	if err := store.Clear(); err != nil {
		fmt.Fprintf(os.Stderr, "clear: %v\n", err)
		return 1
	}
	return 0
}

func readTranscriptPreview(sessionDir, rel string, max int) string {
	if rel == "" {
		return ""
	}
	buf, err := os.ReadFile(sessionDir + "/" + rel)
	if err != nil {
		return ""
	}
	s := string(buf)
	if len(s) > max {
		return s[:max] + "…"
	}
	return s
}

func printSessionHuman(sessionDir string, m *sessions.Manifest) {
	fmt.Printf("ID:           %s\n", m.ID)
	fmt.Printf("Preset:       %s\n", m.Preset)
	fmt.Printf("Duration:     %.2fs\n", m.DurationSec)
	fmt.Println("Stages:")
	for _, st := range m.Stages {
		fmt.Printf("  - %-12s kind=%-6s rate=%dHz wav=%s\n", st.Name, st.Kind, st.RateHz, st.WavRel)
	}
	if cleaned := readTranscriptPreview(sessionDir, m.Transcripts.Cleaned, 240); cleaned != "" {
		fmt.Printf("Cleaned:      %s\n", cleaned)
	}
}
```

- [ ] **Step 4: Wire `sessions` case in main.go**

Add `case "sessions":` to main.go's switch.

- [ ] **Step 5: Run tests**

```
cd core && go build ./... && go test ./cmd/vkb-cli/... -run TestSessions -v
```

Expected: PASS — 7 tests.

- [ ] **Step 6: Commit**

```
git add core/cmd/vkb-cli/sessions.go core/cmd/vkb-cli/sessions_test.go core/cmd/vkb-cli/main.go
git commit -m "feat(vkb-cli): sessions list/show/delete/clear subcommands"
```

---

## Phase D — `pipe --preset` flag

### Task 4: `vkb-cli pipe --preset <name>` overlay

**Files:**
- Modify: `core/cmd/vkb-cli/pipe.go`

Layer a named preset before the existing per-flag overrides. The existing flags (`--llm-provider`, `--dict`, `--speaker`, `--tse-backend`) still work and take priority over the preset.

Implementation strategy: when `--preset` is non-empty, look it up via `presets.Load()` and apply the preset's defaults to the locals that drive pipeline construction (e.g., `*speakerMode`, `*tseBackend`, `*llmProvider`). The flag overrides apply via `flag.Visit` — i.e., we only fall back to the preset value when the flag was *not explicitly set*. `flag.Visit` walks only flags whose `Set()` was called, which is exactly the predicate we want.

- [ ] **Step 1: Add the `--preset` flag**

In `runPipe`, alongside the other `fs.String` calls:

```go
presetName := fs.String("preset", "", "named preset to apply before per-flag overrides (see `vkb-cli presets list`)")
```

- [ ] **Step 2: Implement preset application after `fs.Parse`**

After the `fs.Parse(args)` call and the `(*live || *persistent) && len(fs.Args()) > 0` early-out:

```go
if *presetName != "" {
    p, err := lookupPreset(*presetName)
    if err != nil {
        fmt.Fprintln(os.Stderr, err)
        return 2
    }
    explicit := map[string]bool{}
    fs.Visit(func(f *flag.Flag) { explicit[f.Name] = true })

    // LLM provider: use preset only if flag wasn't passed.
    if !explicit["llm-provider"] && p.LLM.Provider != "" {
        *llmProvider = p.LLM.Provider
    }
    // TSE: enable speaker mode + backend if any chunk stage names tse and is enabled.
    for _, st := range p.ChunkStages {
        if st.Name != "tse" || !st.Enabled {
            continue
        }
        if !explicit["speaker"] {
            *speakerMode = true
        }
        if !explicit["tse-backend"] && st.Backend != "" {
            *tseBackend = st.Backend
        }
    }
    fmt.Fprintf(os.Stderr, "[vkb] preset %q applied (overrides on top take precedence)\n", p.Name)
}
```

The preset also has `Transcribe.ModelSize` and `TimeoutSec`. The existing `pipe` subcommand wires Whisper from `VKB_MODEL_PATH` — model size selection by name isn't supported in CLI today (the env var points at one specific .bin), so we leave that alone with a comment. `TimeoutSec` is engine-level (libvkb) wiring; the CLI's `pipeline.Run` doesn't apply it because `pipe` runs a one-shot pipeline; out of scope for Slice 5 — note as a Slice 5.5 follow-up.

- [ ] **Step 3: Add unit test for preset overlay**

Append to `presets_test.go`:

```go
func TestPipe_PresetFlag_RejectsUnknown(t *testing.T) {
    // Indirect: we don't have a runnable runPipe without whispercpp tag,
    // so this test lives in the whispercpp-tagged file. See
    // pipe_preset_test.go for the actual assertion.
}
```

Actually, `runPipe` is whispercpp-tagged, so the test must be too. Create `core/cmd/vkb-cli/pipe_preset_test.go`:

```go
//go:build whispercpp

package main

import "testing"

func TestPipe_PresetFlag_UnknownPresetExits2(t *testing.T) {
    // Setting VKB_MODEL_PATH to /dev/null guarantees model load won't
    // succeed; but we expect rc=2 from the preset lookup before any
    // model load happens.
    rc := runPipe([]string{"--preset", "no-such-preset-xyz", "/dev/null"})
    if rc != 2 {
        t.Errorf("rc = %d, want 2", rc)
    }
}
```

The `--preset` lookup happens before `transcribe.NewWhisperCpp`, so the test exercises the new code path without needing a real Whisper install.

- [ ] **Step 4: Run tests + build**

```
cd core && go build ./... && go test ./cmd/vkb-cli/... -run 'TestPresets|TestSessions' -v
cd core && go test -tags=whispercpp ./cmd/vkb-cli/... -run TestPipe_PresetFlag -v
```

Expected: PASS.

- [ ] **Step 5: Commit**

```
git add core/cmd/vkb-cli/pipe.go core/cmd/vkb-cli/pipe_preset_test.go
git commit -m "feat(vkb-cli): pipe --preset overlays a named preset before flag overrides"
```

---

## Phase E — Compare subcommand

### Task 5: `vkb-cli compare <session-id> --presets a,b,c [--json]`

**Files:**
- Create: `core/cmd/vkb-cli/compare.go`
- Create: `core/cmd/vkb-cli/compare_stub.go`
- Create: `core/cmd/vkb-cli/compare_test.go`
- Modify: `core/cmd/vkb-cli/main.go`

Compare requires whispercpp because `replay.Run` is whispercpp-tagged. Mirror `pipe.go` / `pipe_stub.go`'s split.

Subcommand contract:

```
vkb-cli compare <session-id> --presets a,b,c [--json]
```

Default human output prints one block per result (preset, total ms, cleaned text, error if any). `--json` emits the raw `[]replay.Result` JSON.

- [ ] **Step 1: Write `compare_stub.go`**

```go
//go:build !whispercpp

package main

import (
	"fmt"
	"os"
)

func runCompare(_ []string) int {
	fmt.Fprintln(os.Stderr, "vkb-cli: 'compare' requires -tags whispercpp (whisper.cpp CGo)")
	return 1
}
```

- [ ] **Step 2: Write `compare.go`**

```go
//go:build whispercpp

package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/voice-keyboard/core/internal/presets"
	"github.com/voice-keyboard/core/internal/replay"
	"github.com/voice-keyboard/core/internal/sessions"
)

func runCompare(args []string) int {
	fs := flag.NewFlagSet("compare", flag.ContinueOnError)
	presetsFlag := fs.String("presets", "", "comma-separated preset names to replay against")
	asJSON := fs.Bool("json", false, "emit JSON array of replay results")
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if fs.NArg() != 1 {
		fmt.Fprintln(os.Stderr, "usage: vkb-cli compare <session-id> --presets a,b,c [--json]")
		return 2
	}
	id := fs.Arg(0)
	names := splitCSV(*presetsFlag)
	if len(names) == 0 {
		fmt.Fprintln(os.Stderr, "compare: --presets is required (comma-separated)")
		return 2
	}

	base := defaultSessionsBase()
	store := sessions.NewStore(base)
	if _, err := store.Get(id); err != nil {
		fmt.Fprintf(os.Stderr, "session %q: %v\n", id, err)
		return 1
	}

	wavPath := filepath.Join(store.SessionDir(id), "denoise.wav")
	if _, err := os.Stat(wavPath); err != nil {
		fmt.Fprintf(os.Stderr, "session %q has no denoise.wav (Compare needs raw 48 kHz audio): %v\n", id, err)
		return 1
	}

	results, err := replay.Run(context.Background(), replay.Options{
		SourceWAVPath: wavPath,
		SourceID:      id,
		DestRoot:      base,
		PresetNames:   names,
		Secrets:       cliSecrets(),
	})
	if err != nil {
		fmt.Fprintf(os.Stderr, "compare: %v\n", err)
		return 1
	}

	if *asJSON {
		buf, err := json.MarshalIndent(results, "", "  ")
		if err != nil {
			fmt.Fprintf(os.Stderr, "marshal: %v\n", err)
			return 1
		}
		fmt.Println(string(buf))
		return 0
	}
	for _, r := range results {
		fmt.Printf("=== %s ===\n", r.PresetName)
		if r.Error != "" {
			fmt.Printf("ERROR: %s\n", r.Error)
		}
		fmt.Printf("Total:    %dms\n", r.TotalMS)
		if r.ReplaySessionDir != "" {
			fmt.Printf("Replay:   %s\n", r.ReplaySessionDir)
		}
		if r.Cleaned != "" {
			fmt.Printf("Cleaned:  %s\n", r.Cleaned)
		}
		fmt.Println()
	}
	return 0
}

// splitCSV mirrors the libvkb helper of the same name. Defined here too
// so vkb-cli compiles without depending on libvkb's package main.
func splitCSV(s string) []string {
	if s == "" {
		return nil
	}
	out := make([]string, 0)
	for _, p := range strings.Split(s, ",") {
		if p = strings.TrimSpace(p); p != "" {
			out = append(out, p)
		}
	}
	return out
}

// cliSecrets pulls API keys + model paths from the same env vars the rest
// of vkb-cli uses, mirroring the Mac engine's `secretsFromEngineCfg` shape.
func cliSecrets() presets.EngineSecrets {
	modelPath := os.Getenv("VKB_MODEL_PATH")
	if modelPath == "" {
		modelPath = os.ExpandEnv("$HOME/Library/Application Support/VoiceKeyboard/models/ggml-tiny.en.bin")
	}
	lang := os.Getenv("VKB_LANGUAGE")
	if lang == "" {
		lang = "en"
	}
	modelsDir := os.Getenv("VKB_MODELS_DIR")
	if modelsDir == "" {
		modelsDir = os.ExpandEnv("$HOME/Library/Application Support/VoiceKeyboard/models")
	}
	profileDir := os.Getenv("VKB_PROFILE_DIR")
	if profileDir == "" {
		profileDir = os.ExpandEnv("$HOME/.config/voice-keyboard")
	}
	onnxLib := os.Getenv("ONNXRUNTIME_LIB_PATH")
	if onnxLib == "" {
		onnxLib = "/opt/homebrew/lib/libonnxruntime.dylib"
	}
	return presets.EngineSecrets{
		LLMAPIKey:           os.Getenv("ANTHROPIC_API_KEY"),
		WhisperModelPath:    modelPath,
		Language:            lang,
		DeepFilterModelPath: os.Getenv("VKB_DEEPFILTER_MODEL_PATH"),
		TSEProfileDir:       profileDir,
		TSEModelPath:        modelsDir,
		ONNXLibPath:         onnxLib,
		LLMProvider:         os.Getenv("VKB_LLM_PROVIDER"),
		LLMBaseURL:          os.Getenv("VKB_LLM_BASE_URL"),
		LLMModel:            os.Getenv("VKB_LLM_MODEL"),
	}
}
```

- [ ] **Step 3: Write `compare_test.go`**

```go
//go:build whispercpp

package main

import "testing"

func TestCompare_NoArgs_ShowsUsage(t *testing.T) {
	if rc := runCompare(nil); rc == 0 {
		t.Errorf("expected non-zero rc")
	}
}

func TestCompare_RequiresPresetsFlag(t *testing.T) {
	if rc := runCompare([]string{"some-id"}); rc == 0 {
		t.Errorf("expected non-zero rc when --presets is empty")
	}
}

func TestCompare_UnknownSession(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("VKB_SESSIONS_DIR", dir)
	rc := runCompare([]string{"no-such-id", "--presets", "default"})
	if rc == 0 {
		t.Errorf("expected non-zero rc for unknown session")
	}
}
```

These three tests don't need a real Whisper model — failure paths fire before `replay.Run`.

- [ ] **Step 4: Wire `compare` case in main.go**

Add `case "compare":` to the switch and update `usage()`.

- [ ] **Step 5: Run tests**

```
cd core && go build ./... && go test ./cmd/vkb-cli/... -v
cd core && go test -tags=whispercpp ./cmd/vkb-cli/... -run TestCompare -v
```

Expected: PASS.

- [ ] **Step 6: Commit**

```
git add core/cmd/vkb-cli/compare.go \
        core/cmd/vkb-cli/compare_stub.go \
        core/cmd/vkb-cli/compare_test.go \
        core/cmd/vkb-cli/main.go
git commit -m "feat(vkb-cli): compare subcommand drives replay.Run from CLI"
```

---

## Phase F — End-to-end test + docs

### Task 6: `e2e_test.go` smoke test

**Files:**
- Create: `core/cmd/vkb-cli/e2e_test.go`

A coarse smoke test gated behind `-tags=e2e,whispercpp`. Builds the binary into `t.TempDir()`, runs:

1. `vkb-cli presets list` — asserts `default` appears + `--json` parses.
2. `vkb-cli sessions list` (against `VKB_SESSIONS_DIR=t.TempDir()`) — asserts `--json` is `[]`.
3. *Skipped if model missing:* `vkb-cli pipe --preset default <fixture.wav>` — asserts rc==0 + non-empty stdout.

The `-tags=e2e` gate keeps it out of the default `go test ./...` so CI without a model isn't broken.

- [ ] **Step 1: Write the test file**

```go
//go:build e2e && whispercpp

package main

import (
	"bytes"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// buildVKBCLI compiles vkb-cli into t.TempDir() and returns the binary path.
func buildVKBCLI(t *testing.T) string {
	t.Helper()
	bin := filepath.Join(t.TempDir(), "vkb-cli")
	cmd := exec.Command("go", "build", "-tags", "whispercpp", "-o", bin, ".")
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil {
		t.Fatalf("go build: %v", err)
	}
	return bin
}

func runBin(t *testing.T, bin string, env []string, args ...string) (string, string, int) {
	t.Helper()
	cmd := exec.Command(bin, args...)
	cmd.Env = append(os.Environ(), env...)
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	err := cmd.Run()
	rc := 0
	if exit, ok := err.(*exec.ExitError); ok {
		rc = exit.ExitCode()
	} else if err != nil {
		t.Fatalf("exec: %v", err)
	}
	return stdout.String(), stderr.String(), rc
}

func TestE2E_PresetsList_IncludesBundled(t *testing.T) {
	bin := buildVKBCLI(t)
	out, _, rc := runBin(t, bin, nil, "presets", "list")
	if rc != 0 {
		t.Fatalf("rc = %d", rc)
	}
	if !strings.Contains(out, "default") {
		t.Errorf("expected 'default' in output, got %q", out)
	}

	out, _, rc = runBin(t, bin, nil, "presets", "list", "--json")
	if rc != 0 {
		t.Fatalf("json rc = %d", rc)
	}
	var arr []map[string]any
	if err := json.Unmarshal([]byte(out), &arr); err != nil {
		t.Fatalf("unmarshal: %v\n%s", err, out)
	}
}

func TestE2E_Sessions_ListEmpty(t *testing.T) {
	bin := buildVKBCLI(t)
	dir := t.TempDir()
	out, _, rc := runBin(t, bin, []string{"VKB_SESSIONS_DIR=" + dir}, "sessions", "list", "--json")
	if rc != 0 {
		t.Fatalf("rc = %d", rc)
	}
	got := strings.TrimSpace(out)
	if got != "[]" {
		t.Errorf("expected '[]', got %q", got)
	}
}

func TestE2E_Pipe_WithPreset_SkipsWithoutModel(t *testing.T) {
	model := os.Getenv("VKB_MODEL_PATH")
	if model == "" {
		t.Skip("VKB_MODEL_PATH unset — skipping pipe smoke")
	}
	if _, err := os.Stat(model); err != nil {
		t.Skipf("model %s missing: %v", model, err)
	}
	wav := os.Getenv("VKB_E2E_FIXTURE_WAV")
	if wav == "" {
		t.Skip("VKB_E2E_FIXTURE_WAV unset — skipping pipe smoke")
	}
	bin := buildVKBCLI(t)
	out, stderr, rc := runBin(t, bin, []string{"VKB_LANGUAGE=en"}, "pipe", "--preset", "default", "--no-llm", wav)
	if rc != 0 {
		t.Fatalf("rc = %d (stderr: %s)", rc, stderr)
	}
	if strings.TrimSpace(out) == "" {
		t.Errorf("expected non-empty stdout for pipe --preset default")
	}
}
```

- [ ] **Step 2: Run the e2e tag explicitly**

```
cd core && go test -tags='e2e whispercpp' ./cmd/vkb-cli/... -run TestE2E -v
```

Expected: 2 tests pass; `TestE2E_Pipe_WithPreset_SkipsWithoutModel` skips unless both env vars are set.

- [ ] **Step 3: Verify the e2e tests are gated out of default `go test`**

```
cd core && go test ./cmd/vkb-cli/... -v 2>&1 | grep -c TestE2E
```

Expected: `0` — the e2e test file isn't part of the default build.

- [ ] **Step 4: Commit**

```
git add core/cmd/vkb-cli/e2e_test.go
git commit -m "test(vkb-cli): e2e smoke covers presets/sessions list + pipe --preset"
```

---

### Task 7: Documentation

**Files:**
- Modify: `README.md`
- Create: `core/cmd/vkb-cli/README.md`

- [ ] **Step 1: Add `## CLI` section to root README**

Insert between `## Building` and `## Releases`:

```markdown
## CLI

`vkb-cli` is the headless equivalent of the Mac app — useful for CI,
scripting, and reproducing issues without launching the GUI. Same Go
primitives, no SwiftUI.

```bash
# List + inspect presets
vkb-cli presets list
vkb-cli presets show default

# Run dictation with a specific preset
vkb-cli pipe --preset minimal --live
vkb-cli pipe --preset default FILE.wav

# Inspect captured sessions
vkb-cli sessions list
vkb-cli sessions show <id>
vkb-cli sessions delete <id>

# A/B compare presets against the same captured audio
vkb-cli compare <session-id> --presets default,minimal,paranoid
```

See `core/cmd/vkb-cli/README.md` for the full reference.
```

- [ ] **Step 2: Write `core/cmd/vkb-cli/README.md`**

One example per subcommand, copy/paste-friendly. Include env-var notes.

- [ ] **Step 3: Commit**

```
git add README.md core/cmd/vkb-cli/README.md
git commit -m "docs(vkb-cli): document presets/sessions/compare subcommands"
```

---

### Task 8: Final integration check + PR

- [ ] **Step 1: Full test pass**

```
cd core && go build ./... && go test ./...
cd core && go test -tags=whispercpp ./cmd/vkb-cli/... ./internal/replay/...
```

Both should pass.

- [ ] **Step 2: Push branch + open PR**

```
git push -u origin feat/pipeline-orchestration-slice-5
gh pr create --title "Pipeline orchestration: Slice 5 (CLI parity)" --body "..."
```

Match the Slice 4 PR body format: Summary + Test plan + Slice 5.5 follow-up.

---

## Summary

Total: **8 tasks across 6 phases.** Estimated ~500 LOC.

**By area:**
- Scaffolding (Task 1): ~10 LOC.
- Presets subcommand (Task 2): ~180 LOC + tests.
- Sessions subcommand (Task 3): ~140 LOC + tests.
- Pipe overlay (Task 4): ~30 LOC + 1 test.
- Compare subcommand (Task 5): ~120 LOC + 3 tests.
- E2E + docs (Tasks 6, 7): ~120 LOC of tests + docs.

---

## Test plan

- [ ] `cd core && go test ./...`
- [ ] `cd core && go test -tags=whispercpp ./cmd/vkb-cli/... ./internal/replay/...`
- [ ] `cd core && go test -tags='e2e whispercpp' ./cmd/vkb-cli/...` (model-dependent step skips without `VKB_MODEL_PATH` + `VKB_E2E_FIXTURE_WAV`)

---

## Slice 5.5 follow-up

- `--preset`'s `TimeoutSec` field is not wired into `vkb-cli pipe` (engine-side timeout is libvkb-only). Apply via `context.WithTimeout` around `pipeline.Run` when set.
- `--preset`'s `Transcribe.ModelSize` is ignored — `vkb-cli pipe` uses `VKB_MODEL_PATH` directly. A future task could resolve model size to a path under `VKB_MODELS_DIR`.
- `presets save` from CLI clones the bundled `default` (or a session's preset name) — there's no "current pipeline" state in CLI. A `--from-flags` mode could capture the per-flag values, but it's a v2 ergonomics question.

---

## Self-Review

### Spec coverage

| Spec section / requirement | Implementing task |
|---|---|
| `vkb-cli presets list` (table or `--json`) | Task 2 |
| `vkb-cli presets show <name>` | Task 2 |
| `vkb-cli presets save <name> [--description ...] [--from <session-id>]` | Task 2 |
| `vkb-cli presets delete <name>` | Task 2 |
| `vkb-cli sessions list` | Task 3 |
| `vkb-cli sessions show <id>` | Task 3 |
| `vkb-cli sessions delete <id>` | Task 3 |
| `vkb-cli sessions clear [--force]` | Task 3 |
| `vkb-cli compare <session-id> --presets a,b,c [--json]` | Task 5 |
| `vkb-cli pipe --preset <name>` | Task 4 |
| Existing pipe flags layer **after** the preset | Task 4 (`flag.Visit` predicate) |
| `--json` flag where it makes sense | Tasks 2, 3, 5 |
| README updates | Task 7 |
| End-to-end smoke covering presets/sessions/pipe | Task 6 |

### Placeholder scan

No "TBD" / "implement later" hand-waves. The two scoped-out items (timeout, model-size) are explicit Slice 5.5 follow-ups in the file body comments and in the PR body.

### Type consistency

- `presets.Preset` field tags match the JSON output of `vkb-cli presets list --json` (the package's own struct tags drive both the bundled JSON schema and the CLI output).
- `sessions.Manifest` JSON tags match `vkb-cli sessions list --json` output.
- `replay.Result` JSON tags match `vkb-cli compare --json` output.
- `presets.EngineSecrets` field names match what `cliSecrets()` populates.

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-05-03-pipeline-orchestration-slice-5-cli.md`. Two execution options:

**1. Subagent-Driven (recommended)** — Dispatch a fresh subagent per task, review between tasks.

**2. Inline Execution** — Execute tasks here, batch with checkpoints.
