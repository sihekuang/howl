//go:build e2e && whispercpp

// End-to-end smoke tests. Gated behind both `e2e` and `whispercpp` build
// tags so the default `go test ./...` skips them — they shell out to a
// freshly compiled `howl` binary, which costs a build per test.
//
// Run with:
//
//	cd core && go test -tags='e2e whispercpp' ./cmd/howl/... -v
//
// The pipe-with-preset case skips when HOWL_MODEL_PATH or
// HOWL_E2E_FIXTURE_WAV is unset/missing, so CI without a Whisper model
// still gets coverage of presets/sessions list.
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

// buildHowlCLI compiles howl (whispercpp tag) into t.TempDir() and
// returns the binary path. Each test gets its own fresh build —
// inexpensive enough for a smoke suite, and avoids cross-test cache
// contamination.
func buildHowlCLI(t *testing.T) string {
	t.Helper()
	bin := filepath.Join(t.TempDir(), "howl")
	cmd := exec.Command("go", "build", "-tags", "whispercpp", "-o", bin, ".")
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil {
		t.Fatalf("go build: %v", err)
	}
	return bin
}

// runBin invokes a freshly built binary with extra env vars and returns
// its stdout, stderr, and exit code. Failures to exec at all (vs
// non-zero exit) call t.Fatalf so tests don't silently treat them as
// "rc != 0".
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
	bin := buildHowlCLI(t)
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
	if len(arr) == 0 {
		t.Errorf("expected non-empty preset list")
	}
}

func TestE2E_Sessions_ListEmpty(t *testing.T) {
	bin := buildHowlCLI(t)
	dir := t.TempDir()
	out, _, rc := runBin(t, bin, []string{"HOWL_SESSIONS_DIR=" + dir}, "sessions", "list", "--json")
	if rc != 0 {
		t.Fatalf("rc = %d", rc)
	}
	got := strings.TrimSpace(out)
	if got != "[]" {
		t.Errorf("expected '[]', got %q", got)
	}
}

func TestE2E_Pipe_WithPreset_SkipsWithoutModel(t *testing.T) {
	model := os.Getenv("HOWL_MODEL_PATH")
	if model == "" {
		t.Skip("HOWL_MODEL_PATH unset — skipping pipe smoke")
	}
	if _, err := os.Stat(model); err != nil {
		t.Skipf("model %s missing: %v", model, err)
	}
	wav := os.Getenv("HOWL_E2E_FIXTURE_WAV")
	if wav == "" {
		t.Skip("HOWL_E2E_FIXTURE_WAV unset — skipping pipe smoke")
	}
	if _, err := os.Stat(wav); err != nil {
		t.Skipf("fixture %s missing: %v", wav, err)
	}

	bin := buildHowlCLI(t)
	out, stderr, rc := runBin(t, bin, []string{"HOWL_LANGUAGE=en"}, "pipe", "--preset", "default", "--no-llm", wav)
	if rc != 0 {
		t.Fatalf("rc = %d (stderr: %s)", rc, stderr)
	}
	if strings.TrimSpace(out) == "" {
		t.Errorf("expected non-empty stdout for pipe --preset default; stderr was %q", stderr)
	}
}
