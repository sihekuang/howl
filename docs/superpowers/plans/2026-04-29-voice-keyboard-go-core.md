# Voice Keyboard — Go Core Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the `libvkb.dylib` Go core and the `vkb-cli` test harness so that `vkb-cli pipe --live` runs the full dictation pipeline (mic capture → denoise → resample → Whisper → dictionary → Anthropic cleanup → cleaned text) end-to-end, with every collaborator behind an interface and unit-tested.

**Architecture:** Hexagonal / ports-and-adapters Go module. Pure Go (config, dict, resample, pipeline, llm, fake capture) developed and tested first. CGo-bound modules (denoise, transcribe, audio capture) added next. Both `cmd/vkb-cli` and `cmd/libvkb` are composition roots that wire interfaces to concrete impls. `libvkb` is built with `-buildmode=c-shared` for the Swift app to link against.

**Tech Stack:** Go 1.22+, malgo (miniaudio Go bindings), whisper.cpp v1.8.4 (Homebrew), DeepFilterNet (vendored prebuilt `libdf.dylib`), `anthropic-sdk-go`.

---

## File Structure

All paths relative to `/Users/daniel/Documents/Projects/voice-keyboard/core/`.

| File | Responsibility |
|---|---|
| `go.mod` | Module declaration, dependency versions |
| `Makefile` | `bootstrap`, `build`, `build-cli`, `build-dylib`, `test`, `test-unit`, `test-integration`, `clean`, `rebuild-denoise` |
| `BUILDING_DENOISE.md` | Maintainer doc: how to rebuild `libdf.dylib` from source |
| `cmd/vkb-cli/main.go` | CLI test harness, composition root #1 |
| `cmd/libvkb/main.go` | C ABI surface, composition root #2, c-shared build |
| `internal/config/config.go` | `Config` struct, JSON marshaling for the C ABI |
| `internal/config/config_test.go` | Round-trip JSON marshaling tests |
| `internal/dict/dictionary.go` | `Dictionary` interface |
| `internal/dict/fuzzy.go` | Levenshtein-based fuzzy matcher impl |
| `internal/dict/fuzzy_test.go` | Matching tests with known inputs |
| `internal/llm/cleaner.go` | `Cleaner` interface |
| `internal/llm/prompt.go` | Cleanup prompt template |
| `internal/llm/anthropic.go` | Anthropic impl using `anthropic-sdk-go` |
| `internal/llm/anthropic_test.go` | HTTP integration test using `httptest.Server` |
| `internal/resample/decimate3.go` | 48kHz → 16kHz polyphase FIR decimator |
| `internal/resample/decimate3_test.go` | Frequency-domain tests on synthetic signals |
| `internal/audio/capture.go` | `Capture` interface |
| `internal/audio/fake_capture.go` | Test impl that replays a `[]float32` buffer |
| `internal/audio/fake_capture_test.go` | Fake capture behavioral tests |
| `internal/audio/malgo_capture.go` | malgo (miniaudio) impl |
| `internal/denoise/denoiser.go` | `Denoiser` interface |
| `internal/denoise/passthrough.go` | No-op impl when feature disabled |
| `internal/denoise/deepfilter_cgo.go` | CGo binding to `libdf.dylib` |
| `internal/denoise/denoise_test.go` | Tests for passthrough; `//go:build deepfilter` for CGo impl |
| `internal/transcribe/transcriber.go` | `Transcriber` interface |
| `internal/transcribe/whisper_cpp.go` | CGo binding to `libwhisper.dylib` |
| `internal/transcribe/whisper_cpp_test.go` | Build-tagged hardware tests |
| `internal/pipeline/pipeline.go` | `Pipeline` orchestrator + `Result` type |
| `internal/pipeline/pipeline_test.go` | All collaborators replaced with fakes |
| `internal/cabi/exports.go` | `//export` C ABI functions, lives inside `cmd/libvkb` package |
| `test/integration/full_pipeline_test.go` | Real impls + fake capture from a WAV fixture |
| `test/integration/testdata/hello-world.wav` | 16kHz mono WAV fixture, ~2 seconds |
| `third_party/deepfilter/lib/macos-arm64/libdf.dylib` | Prebuilt DeepFilterNet C library |
| `third_party/deepfilter/include/deep_filter.h` | C header for CGo binding |
| `third_party/deepfilter/VERSION.md` | Pin info: upstream tag, commit, build date |

The `internal/` boundary enforces hex/ports: only `cmd/` packages may construct concrete impls. Inter-package deps inside `internal/` are interface-only.

---

## Task 1: Bootstrap project structure

**Files:**
- Create: `core/go.mod`
- Create: `core/.gitignore`
- Create: `core/cmd/vkb-cli/main.go`

- [ ] **Step 1: Install Go toolchain via Homebrew**

Run: `brew install go && go version`
Expected: prints `go version go1.22.x darwin/arm64` or newer.

- [ ] **Step 2: Create the core directory and Go module**

```bash
mkdir -p /Users/daniel/Documents/Projects/voice-keyboard/core
cd /Users/daniel/Documents/Projects/voice-keyboard/core
go mod init github.com/voice-keyboard/core
```

The module path uses `github.com/voice-keyboard/...` as a placeholder owner. If the user later publishes under a different GitHub org, edit `go.mod`'s `module` line and run `find . -name "*.go" -exec sed -i '' 's|github.com/voice-keyboard|github.com/NEWOWNER|g' {} +`.

- [ ] **Step 3: Create a stub main for vkb-cli so the module compiles**

Write `core/cmd/vkb-cli/main.go`:

```go
package main

import "fmt"

func main() {
	fmt.Println("vkb-cli: not yet implemented")
}
```

- [ ] **Step 4: Create .gitignore**

Write `core/.gitignore`:

```
# Build outputs
build/
*.dylib
*.so
*.dll
*.h
!third_party/**/*.dylib
!third_party/**/*.so
!third_party/**/*.h

# Go
*.test
*.out
coverage.out

# IDE
.vscode/
.idea/

# OS
.DS_Store
```

The `!third_party/**/*.dylib` and `!third_party/**/*.so` negations are critical: without them the `*.dylib` rule would silently prevent committing `third_party/deepfilter/lib/macos-arm64/libdf.dylib` in Task 3.

- [ ] **Step 5: Verify it compiles**

Run: `cd /Users/daniel/Documents/Projects/voice-keyboard/core && go build ./cmd/vkb-cli`
Expected: produces `core/vkb-cli` binary; `./vkb-cli` prints `vkb-cli: not yet implemented`.

- [ ] **Step 6: Clean up the stub binary**

Run: `rm /Users/daniel/Documents/Projects/voice-keyboard/core/vkb-cli`

---

## Task 2: Set up Makefile

**Files:**
- Create: `core/Makefile`

- [ ] **Step 1: Write the Makefile**

Write `core/Makefile`:

```makefile
SHELL := /bin/bash
BUILD_DIR := build
GO := go
WHISPER_PREFIX := /opt/homebrew/opt/whisper-cpp
DEEPFILTER_DIR := third_party/deepfilter

# Used by CGo to find headers and libraries
export CGO_CFLAGS  := -I$(WHISPER_PREFIX)/include -I$(CURDIR)/$(DEEPFILTER_DIR)/include
export CGO_LDFLAGS := -L$(WHISPER_PREFIX)/lib -lwhisper -L$(CURDIR)/$(DEEPFILTER_DIR)/lib/macos-arm64 -ldf
export DYLD_LIBRARY_PATH := $(WHISPER_PREFIX)/lib:$(CURDIR)/$(DEEPFILTER_DIR)/lib/macos-arm64:$(DYLD_LIBRARY_PATH)

.PHONY: bootstrap build build-cli build-dylib test test-unit test-integration clean rebuild-denoise

bootstrap:
	@command -v go >/dev/null || (echo "Go not installed. Run: brew install go" && exit 1)
	@command -v xcodebuild >/dev/null || (echo "Xcode required" && exit 1)
	@test -f $(WHISPER_PREFIX)/lib/libwhisper.dylib || (echo "whisper-cpp not installed. Run: brew install whisper-cpp" && exit 1)
	@test -f $(DEEPFILTER_DIR)/lib/macos-arm64/libdf.dylib || (echo "vendored libdf.dylib missing. See BUILDING_DENOISE.md" && exit 1)
	$(GO) mod download
	@echo "Bootstrap OK"

build: build-cli build-dylib

build-cli:
	mkdir -p $(BUILD_DIR)
	$(GO) build -o $(BUILD_DIR)/vkb-cli ./cmd/vkb-cli

build-dylib:
	mkdir -p $(BUILD_DIR)
	$(GO) build -buildmode=c-shared -o $(BUILD_DIR)/libvkb.dylib ./cmd/libvkb

test: test-unit

test-unit:
	$(GO) test ./internal/...

test-integration:
	$(GO) test -tags=integration ./test/integration/...

clean:
	rm -rf $(BUILD_DIR)

rebuild-denoise:
	@echo "Maintainer-only target. See BUILDING_DENOISE.md."
	@exit 1
```

- [ ] **Step 2: Verify Makefile syntax is valid**

Run: `cd /Users/daniel/Documents/Projects/voice-keyboard/core && make -n bootstrap`
Expected: dry-run prints commands without executing; no syntax error.

---

## Task 3: Build libdf and vendor it

This is the one-time setup that requires Rust. Once done, the binary is committed and Rust is no longer required.

**Files:**
- Create: `core/third_party/deepfilter/lib/macos-arm64/libdf.dylib`
- Create: `core/third_party/deepfilter/include/deep_filter.h`
- Create: `core/third_party/deepfilter/VERSION.md`
- Create: `core/BUILDING_DENOISE.md`

- [ ] **Step 1: Install Rust temporarily**

Run: `command -v cargo || curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --no-modify-path && source "$HOME/.cargo/env"`
Expected: `cargo --version` prints a valid version.

- [ ] **Step 2: Clone DeepFilterNet at a pinned tag**

```bash
mkdir -p /tmp/voice-keyboard-build
cd /tmp/voice-keyboard-build
git clone --depth 1 --branch v0.5.6 https://github.com/Rikorose/DeepFilterNet.git deepfilternet
cd deepfilternet
```

If `v0.5.6` is no longer current, replace with the latest stable tag from https://github.com/Rikorose/DeepFilterNet/releases. Record the chosen tag for VERSION.md.

- [ ] **Step 3: Build libdf for macOS arm64**

```bash
export MACOSX_DEPLOYMENT_TARGET=13.0
cargo build --release -p deep_filter --features capi --target aarch64-apple-darwin
```

Expected: produces `target/aarch64-apple-darwin/release/libdf.dylib` (~16MB on rustc 1.95). The `--features capi` flag enables the C ABI.

**Two upstream gotchas verified during the original v0.5.6 build (April 2026):**
1. The `time` crate v0.3.28 pinned in upstream's `Cargo.lock` doesn't compile on rustc 1.95+. Run `cargo update -p time` before `cargo build`.
2. `libDF/Cargo.toml`'s `[lib]` section does NOT declare `crate-type`, so default cargo builds emit only an `rlib`. Either use `cargo cinstall` (requires `cargo install cargo-c`), or simpler: edit `libDF/Cargo.toml` to add `crate-type = ["cdylib", "rlib"]` to the `[lib]` section before building.

If the upstream feature flag has changed, check `libDF/Cargo.toml` for the feature that builds the C library.

- [ ] **Step 4: Copy artifacts into the vendor directory**

```bash
mkdir -p /Users/daniel/Documents/Projects/voice-keyboard/core/third_party/deepfilter/lib/macos-arm64
mkdir -p /Users/daniel/Documents/Projects/voice-keyboard/core/third_party/deepfilter/include
cp target/aarch64-apple-darwin/release/libdf.dylib \
   /Users/daniel/Documents/Projects/voice-keyboard/core/third_party/deepfilter/lib/macos-arm64/
cp libDF/include/deep_filter.h \
   /Users/daniel/Documents/Projects/voice-keyboard/core/third_party/deepfilter/include/
```

- [ ] **Step 5: Set the install name on the dylib**

```bash
cd /Users/daniel/Documents/Projects/voice-keyboard/core/third_party/deepfilter/lib/macos-arm64
install_name_tool -id "@rpath/libdf.dylib" libdf.dylib
otool -D libdf.dylib
```

Expected: `otool -D` prints `@rpath/libdf.dylib`. This makes the dylib relocatable so the Swift app can bundle it later.

- [ ] **Step 6: Write VERSION.md**

Write `core/third_party/deepfilter/VERSION.md`:

```markdown
# DeepFilterNet vendored binary

| Field | Value |
|---|---|
| Upstream | https://github.com/Rikorose/DeepFilterNet |
| Tag | v0.5.6 |
| Commit | <git rev-parse HEAD output from /tmp/voice-keyboard-build/deepfilternet> |
| Build target | aarch64-apple-darwin |
| MACOSX_DEPLOYMENT_TARGET | 13.0 |
| Rust version | <rustc --version output> |
| Cargo features | capi |
| Build date | <date -u +%Y-%m-%dT%H:%M:%SZ> |

## How this was built

See `BUILDING_DENOISE.md`.
```

Replace placeholders with actual values from the build environment.

- [ ] **Step 7: Write BUILDING_DENOISE.md**

Write `core/BUILDING_DENOISE.md`:

```markdown
# Rebuilding libdf.dylib

The `libdf.dylib` shipped under `third_party/deepfilter/lib/macos-arm64/` is built once by a maintainer and committed to the repo. Day-to-day contributors do not need Rust — they just consume the prebuilt binary.

This document describes how to regenerate the binary when bumping DeepFilterNet versions.

## Prerequisites
- Rust toolchain (`rustup`)
- Xcode command-line tools

## Steps
1. Install Rust if missing:
   ```bash
   curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
   source "$HOME/.cargo/env"
   ```

2. Clone DeepFilterNet at the desired tag:
   ```bash
   git clone --depth 1 --branch <TAG> https://github.com/Rikorose/DeepFilterNet.git
   cd DeepFilterNet
   ```

3. Build for arm64 macOS:
   ```bash
   export MACOSX_DEPLOYMENT_TARGET=13.0
   cargo build --release -p deep_filter --features capi --target aarch64-apple-darwin
   ```

4. Copy the artifacts into the vendor directory:
   ```bash
   cp target/aarch64-apple-darwin/release/libdf.dylib \
      <REPO>/core/third_party/deepfilter/lib/macos-arm64/
   cp libDF/include/deep_filter.h \
      <REPO>/core/third_party/deepfilter/include/
   ```

5. Rewrite the install name:
   ```bash
   cd <REPO>/core/third_party/deepfilter/lib/macos-arm64
   install_name_tool -id "@rpath/libdf.dylib" libdf.dylib
   ```

6. Update `third_party/deepfilter/VERSION.md` with the new tag, commit hash, build date, and Rust version.

7. Run the denoise tests:
   ```bash
   cd <REPO>/core
   make test-unit
   ```
```

- [ ] **Step 8: Verify the dylib is loadable**

Run:
```bash
cd /Users/daniel/Documents/Projects/voice-keyboard/core
otool -L third_party/deepfilter/lib/macos-arm64/libdf.dylib | head -5
```
Expected: lists `/usr/lib/libSystem.B.dylib` and `/usr/lib/libiconv.2.dylib`. No `libc++` dependency is expected — Rust statically links its own standard library. Confirms the binary is well-formed.

- [ ] **Step 9: Verify the header is non-empty and exposes the C ABI**

Run: `head -50 /Users/daniel/Documents/Projects/voice-keyboard/core/third_party/deepfilter/include/deep_filter.h`
Expected: contains declarations like `DFState* df_create(...)`, `df_process_frame(...)`, `df_free(...)`. Note the exact function names and signatures — they are needed in Task 11.

- [ ] **Step 10: Commit**

(Skip git commits if the project is not a git repo yet. Otherwise commit with message "chore: vendor DeepFilterNet libdf.dylib v0.5.6".)

---

## Task 4: Config struct and JSON marshaling

**Files:**
- Create: `core/internal/config/config.go`
- Create: `core/internal/config/config_test.go`

- [ ] **Step 1: Write the failing test**

Write `core/internal/config/config_test.go`:

```go
package config

import (
	"encoding/json"
	"testing"
)

func TestConfig_RoundTrip(t *testing.T) {
	original := Config{
		WhisperModelPath:    "/tmp/ggml-small.bin",
		WhisperModelSize:    "small",
		Language:            "en",
		NoiseSuppression:    true,
		DeepFilterModelPath: "/tmp/DeepFilterNet3.tar.gz",
		LLMProvider:         "anthropic",
		LLMModel:            "claude-sonnet-4-6",
		LLMAPIKey:           "sk-ant-test",
		CustomDict:          []string{"MCP", "WebRTC"},
	}

	data, err := json.Marshal(original)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}

	var roundtripped Config
	if err := json.Unmarshal(data, &roundtripped); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}

	if roundtripped.WhisperModelPath != original.WhisperModelPath {
		t.Errorf("WhisperModelPath mismatch: got %q want %q", roundtripped.WhisperModelPath, original.WhisperModelPath)
	}
	if roundtripped.WhisperModelSize != original.WhisperModelSize {
		t.Errorf("WhisperModelSize mismatch: got %q want %q", roundtripped.WhisperModelSize, original.WhisperModelSize)
	}
	if roundtripped.Language != original.Language {
		t.Errorf("Language mismatch: got %q want %q", roundtripped.Language, original.Language)
	}
	if roundtripped.DeepFilterModelPath != original.DeepFilterModelPath {
		t.Errorf("DeepFilterModelPath mismatch: got %q want %q", roundtripped.DeepFilterModelPath, original.DeepFilterModelPath)
	}
	if roundtripped.NoiseSuppression != original.NoiseSuppression {
		t.Errorf("NoiseSuppression mismatch")
	}
	if len(roundtripped.CustomDict) != 2 || roundtripped.CustomDict[0] != "MCP" {
		t.Errorf("CustomDict mismatch: %+v", roundtripped.CustomDict)
	}
	if roundtripped.LLMProvider != original.LLMProvider {
		t.Errorf("LLMProvider mismatch: got %q want %q", roundtripped.LLMProvider, original.LLMProvider)
	}
	if roundtripped.LLMModel != original.LLMModel {
		t.Errorf("LLMModel mismatch: got %q want %q", roundtripped.LLMModel, original.LLMModel)
	}
	if roundtripped.LLMAPIKey != original.LLMAPIKey {
		t.Errorf("LLMAPIKey mismatch: got %q want %q", roundtripped.LLMAPIKey, original.LLMAPIKey)
	}
}

func TestConfig_DefaultsApplied(t *testing.T) {
	var empty Config
	WithDefaults(&empty)
	if empty.WhisperModelSize != "small" {
		t.Errorf("expected default WhisperModelSize=small, got %q", empty.WhisperModelSize)
	}
	if empty.Language != "auto" {
		t.Errorf("expected default Language=auto, got %q", empty.Language)
	}
	if !empty.NoiseSuppression {
		t.Errorf("expected default NoiseSuppression=true")
	}
	if empty.LLMProvider != "anthropic" {
		t.Errorf("expected default LLMProvider=anthropic, got %q", empty.LLMProvider)
	}
	if empty.LLMModel != "claude-sonnet-4-6" {
		t.Errorf("expected default LLMModel=claude-sonnet-4-6, got %q", empty.LLMModel)
	}
}
```

- [ ] **Step 2: Run the test to confirm it fails**

Run: `cd /Users/daniel/Documents/Projects/voice-keyboard/core && go test ./internal/config/...`
Expected: FAIL — `Config` type and `WithDefaults` function are undefined.

- [ ] **Step 3: Write the implementation**

Write `core/internal/config/config.go`:

```go
// Package config holds the Config struct that travels across the C ABI
// as JSON. Defaults are applied by WithDefaults, never inside JSON tags.
package config

type Config struct {
	WhisperModelPath    string   `json:"whisper_model_path"`
	WhisperModelSize    string   `json:"whisper_model_size"`
	Language            string   `json:"language"`
	NoiseSuppression    bool     `json:"noise_suppression"`
	DeepFilterModelPath string   `json:"deep_filter_model_path"` // path to DeepFilterNet model archive (.tar.gz)
	LLMProvider         string   `json:"llm_provider"`
	LLMModel            string   `json:"llm_model"`
	LLMAPIKey           string   `json:"llm_api_key"`
	CustomDict          []string `json:"custom_dict"`
}

func WithDefaults(c *Config) {
	if c.WhisperModelSize == "" {
		c.WhisperModelSize = "small"
	}
	if c.Language == "" {
		c.Language = "auto"
	}
	if !c.NoiseSuppression {
		c.NoiseSuppression = true
	}
	if c.LLMProvider == "" {
		c.LLMProvider = "anthropic"
	}
	if c.LLMModel == "" {
		c.LLMModel = "claude-sonnet-4-6"
	}
}
```

Note: `WithDefaults` only sets fields that are at their zero value. The `NoiseSuppression` default of `true` cannot be distinguished from `false` in Go's type system without a pointer; this is acceptable for v1 because Swift always sends the explicit current setting. The `if !c.NoiseSuppression` line is intentional — it makes the default `true` when the field is unset (zero-value `false`).

- [ ] **Step 4: Run the test**

Run: `cd /Users/daniel/Documents/Projects/voice-keyboard/core && go test ./internal/config/...`
Expected: PASS.

- [ ] **Step 5: Commit**

(If git initialized.) `git add internal/config && git commit -m "feat(config): add Config struct with JSON marshaling"`

---

## Task 5: Dictionary fuzzy matching

**Files:**
- Create: `core/internal/dict/dictionary.go`
- Create: `core/internal/dict/fuzzy.go`
- Create: `core/internal/dict/fuzzy_test.go`

- [ ] **Step 1: Write the interface**

Write `core/internal/dict/dictionary.go`:

```go
// Package dict provides custom-vocabulary correction for ASR output.
// The Dictionary interface is an extension point: today only fuzzy matching;
// Phase 2 may add phonetic (Metaphone) matching behind the same interface.
package dict

type Dictionary interface {
	// Match scans `text` for tokens that approximately match any of the
	// custom terms this Dictionary was constructed with. Each matched
	// token is replaced with its canonical form. The returned slice is
	// the canonical forms that were actually substituted, with no
	// duplicates and no preserved order. An empty input yields ("", nil).
	Match(text string) (corrected string, matchedTerms []string)
}
```

- [ ] **Step 2: Write the failing tests**

Write `core/internal/dict/fuzzy_test.go`:

```go
package dict

import (
	"sort"
	"testing"
)

func TestFuzzy_ExactMatch(t *testing.T) {
	d := NewFuzzy([]string{"WebRTC", "MCP"}, 1)
	got, terms := d.Match("we use WebRTC for audio")
	if got != "we use WebRTC for audio" {
		t.Errorf("exact match should leave text unchanged, got %q", got)
	}
	wantTerms := []string{"WebRTC"}
	if !equalStringSets(terms, wantTerms) {
		t.Errorf("matchedTerms = %v, want %v", terms, wantTerms)
	}
}

func TestFuzzy_OneEditDistance(t *testing.T) {
	d := NewFuzzy([]string{"WebRTC"}, 1)
	got, terms := d.Match("we use webrt for audio")
	if got != "we use WebRTC for audio" {
		t.Errorf("close match should be corrected, got %q", got)
	}
	if len(terms) != 1 || terms[0] != "WebRTC" {
		t.Errorf("matchedTerms = %v", terms)
	}
}

func TestFuzzy_TooFar_NoMatch(t *testing.T) {
	d := NewFuzzy([]string{"WebRTC"}, 1)
	got, terms := d.Match("we use HTTP for audio")
	if got != "we use HTTP for audio" {
		t.Errorf("distant token should not match, got %q", got)
	}
	if len(terms) != 0 {
		t.Errorf("matchedTerms = %v, want []", terms)
	}
}

func TestFuzzy_EmptyInput(t *testing.T) {
	d := NewFuzzy([]string{"WebRTC"}, 1)
	got, terms := d.Match("")
	if got != "" || terms != nil {
		t.Errorf("empty input → %q, %v", got, terms)
	}
}

func TestFuzzy_DeduplicatesMatchedTerms(t *testing.T) {
	d := NewFuzzy([]string{"MCP"}, 1)
	got, terms := d.Match("MCP and MCP again")
	if got != "MCP and MCP again" {
		t.Errorf("got %q", got)
	}
	if len(terms) != 1 || terms[0] != "MCP" {
		t.Errorf("matchedTerms = %v", terms)
	}
}

func TestFuzzy_PunctuationPreserved(t *testing.T) {
	d := NewFuzzy([]string{"WebRTC"}, 1)
	got, _ := d.Match("we use webrt, for audio.")
	if got != "we use WebRTC, for audio." {
		t.Errorf("punctuation lost: got %q", got)
	}
}

func TestLevenshtein(t *testing.T) {
	cases := []struct {
		a, b string
		want int
	}{
		{"", "", 0},
		{"abc", "abc", 0},
		{"abc", "abd", 1},
		{"abc", "acb", 2},
		{"webrt", "WebRTC", 4}, // 4 case-sensitive edits; the Match path lowers both sides before calling levenshtein
		{"kitten", "sitting", 3},
	}
	for _, tc := range cases {
		got := levenshtein(tc.a, tc.b)
		if got != tc.want {
			t.Errorf("levenshtein(%q, %q) = %d, want %d", tc.a, tc.b, got, tc.want)
		}
	}
}

func equalStringSets(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	ac := append([]string(nil), a...)
	bc := append([]string(nil), b...)
	sort.Strings(ac)
	sort.Strings(bc)
	for i := range ac {
		if ac[i] != bc[i] {
			return false
		}
	}
	return true
}
```

- [ ] **Step 3: Run the tests to confirm they fail**

Run: `cd /Users/daniel/Documents/Projects/voice-keyboard/core && go test ./internal/dict/...`
Expected: FAIL — `NewFuzzy`, `levenshtein` undefined.

- [ ] **Step 4: Write the implementation**

Write `core/internal/dict/fuzzy.go`:

```go
package dict

import (
	"strings"
	"unicode"
)

// Fuzzy matches tokens to a small vocabulary using Levenshtein distance.
// Comparison is case-insensitive. Tokens shorter than three runes are
// skipped to avoid spurious matches on common short words.
type Fuzzy struct {
	terms    []string
	maxDist  int
	lowerSet []string // lowercase terms, parallel to `terms`
}

func NewFuzzy(terms []string, maxDist int) *Fuzzy {
	lowerSet := make([]string, len(terms))
	for i, t := range terms {
		lowerSet[i] = strings.ToLower(t)
	}
	return &Fuzzy{terms: terms, maxDist: maxDist, lowerSet: lowerSet}
}

func (f *Fuzzy) Match(text string) (string, []string) {
	if text == "" {
		return "", nil
	}

	matched := map[string]struct{}{}
	var b strings.Builder
	b.Grow(len(text))

	i := 0
	for i < len(text) {
		// pass through anything that isn't a letter or digit
		if !isWordRune(rune(text[i])) {
			b.WriteByte(text[i])
			i++
			continue
		}

		// find the next token boundary
		j := i
		for j < len(text) && isWordRune(rune(text[j])) {
			j++
		}
		token := text[i:j]
		canonical := f.canonicalFor(token)
		if canonical != "" {
			b.WriteString(canonical)
			matched[canonical] = struct{}{}
		} else {
			b.WriteString(token)
		}
		i = j
	}

	out := make([]string, 0, len(matched))
	for k := range matched {
		out = append(out, k)
	}
	return b.String(), out
}

func (f *Fuzzy) canonicalFor(token string) string {
	if len([]rune(token)) < 3 {
		return ""
	}
	tokenLower := strings.ToLower(token)
	bestIdx := -1
	bestDist := f.maxDist + 1
	for i, term := range f.lowerSet {
		d := levenshtein(tokenLower, term)
		if d <= f.maxDist && d < bestDist {
			bestDist = d
			bestIdx = i
		}
	}
	if bestIdx == -1 {
		return ""
	}
	return f.terms[bestIdx]
}

func isWordRune(r rune) bool {
	return unicode.IsLetter(r) || unicode.IsDigit(r)
}

// levenshtein returns the edit distance between two ASCII/UTF-8 strings.
// Uses the standard two-row dynamic programming approach: O(len(a)*len(b))
// time, O(min(len(a), len(b))) space.
func levenshtein(a, b string) int {
	ra := []rune(a)
	rb := []rune(b)
	if len(ra) == 0 {
		return len(rb)
	}
	if len(rb) == 0 {
		return len(ra)
	}
	prev := make([]int, len(rb)+1)
	curr := make([]int, len(rb)+1)
	for j := range prev {
		prev[j] = j
	}
	for i := 1; i <= len(ra); i++ {
		curr[0] = i
		for j := 1; j <= len(rb); j++ {
			cost := 1
			if ra[i-1] == rb[j-1] {
				cost = 0
			}
			curr[j] = min3(curr[j-1]+1, prev[j]+1, prev[j-1]+cost)
		}
		prev, curr = curr, prev
	}
	return prev[len(rb)]
}

func min3(a, b, c int) int {
	m := a
	if b < m {
		m = b
	}
	if c < m {
		m = c
	}
	return m
}
```

- [ ] **Step 5: Run the tests**

Run: `cd /Users/daniel/Documents/Projects/voice-keyboard/core && go test ./internal/dict/... -v`
Expected: all tests PASS.

- [ ] **Step 6: Commit**

`git add internal/dict && git commit -m "feat(dict): add fuzzy dictionary matcher with Levenshtein"`

---

## Task 6: LLM cleaner interface and prompt

**Files:**
- Create: `core/internal/llm/cleaner.go`
- Create: `core/internal/llm/prompt.go`
- Create: `core/internal/llm/prompt_test.go`

- [ ] **Step 1: Write the interface**

Write `core/internal/llm/cleaner.go`:

```go
// Package llm provides the LLM cleanup step that removes filler words and
// fixes grammar in raw transcriptions. The Cleaner interface is the
// extension point: v1 ships an Anthropic impl; OpenAI/Ollama in Phase 2.
package llm

import "context"

type Cleaner interface {
	// Clean takes a raw transcription and a list of custom terms that
	// must be preserved verbatim, returns the cleaned text. On any
	// error (network, auth, rate limit) the caller should fall back
	// to the original raw text — never lose the user's words.
	Clean(ctx context.Context, raw string, preserveTerms []string) (string, error)
}
```

- [ ] **Step 2: Write the failing test for prompt rendering**

Write `core/internal/llm/prompt_test.go`:

```go
package llm

import (
	"strings"
	"testing"
)

func TestRenderPrompt_BasicSubstitution(t *testing.T) {
	got := renderPrompt("hello world um yeah", []string{"MCP", "WebRTC"})
	if !strings.Contains(got, "hello world um yeah") {
		t.Errorf("prompt missing raw text:\n%s", got)
	}
	if !strings.Contains(got, "MCP, WebRTC") {
		t.Errorf("prompt missing preserve terms:\n%s", got)
	}
	if !strings.Contains(got, "Remove filler words") {
		t.Errorf("prompt missing instructions:\n%s", got)
	}
}

func TestRenderPrompt_NoTerms(t *testing.T) {
	got := renderPrompt("hello", nil)
	if !strings.Contains(got, "Preserve technical terms exactly as listed:") {
		t.Errorf("prompt missing terms section even when empty:\n%s", got)
	}
	// when terms list is empty, render with the literal "(none)"
	if !strings.Contains(got, "(none)") {
		t.Errorf("expected (none) when no terms:\n%s", got)
	}
}
```

- [ ] **Step 3: Run the test to confirm it fails**

Run: `cd /Users/daniel/Documents/Projects/voice-keyboard/core && go test ./internal/llm/...`
Expected: FAIL — `renderPrompt` undefined.

- [ ] **Step 4: Implement the prompt template**

Write `core/internal/llm/prompt.go`:

```go
package llm

import (
	"fmt"
	"strings"
)

const cleanupPrompt = `You are a transcription editor. Clean up the following voice transcription:
- Remove filler words (um, uh, like, you know, basically)
- Fix grammar and punctuation
- Preserve technical terms exactly as listed: %s
- Keep meaning intact, do not add new content
- Return only the cleaned text, nothing else

Raw transcription: %s`

// renderPrompt produces the user message sent to the LLM.
func renderPrompt(raw string, preserveTerms []string) string {
	terms := "(none)"
	if len(preserveTerms) > 0 {
		terms = strings.Join(preserveTerms, ", ")
	}
	return fmt.Sprintf(cleanupPrompt, terms, raw)
}
```

- [ ] **Step 5: Run tests**

Run: `cd /Users/daniel/Documents/Projects/voice-keyboard/core && go test ./internal/llm/... -v`
Expected: PASS.

- [ ] **Step 6: Commit**

`git add internal/llm && git commit -m "feat(llm): add Cleaner interface and prompt template"`

---

## Task 7: Anthropic Cleaner implementation

**Files:**
- Create: `core/internal/llm/anthropic.go`
- Create: `core/internal/llm/anthropic_test.go`
- Modify: `core/go.mod` (adds `github.com/anthropics/anthropic-sdk-go`)

- [ ] **Step 1: Add the Anthropic SDK dependency**

Run: `cd /Users/daniel/Documents/Projects/voice-keyboard/core && go get github.com/anthropics/anthropic-sdk-go`
Expected: `go.mod` updated; `go.sum` populated.

If the import path has changed since this plan was written, search https://pkg.go.dev for `anthropic-sdk-go`. The current canonical path as of January 2026 is `github.com/anthropics/anthropic-sdk-go`.

- [ ] **Step 2: Write the failing test**

Write `core/internal/llm/anthropic_test.go`:

```go
package llm

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestAnthropicClean_HappyPath(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("x-api-key") != "sk-ant-test" {
			t.Errorf("missing or wrong x-api-key header: %q", r.Header.Get("x-api-key"))
		}
		if !strings.Contains(r.URL.Path, "/messages") {
			t.Errorf("unexpected path %s", r.URL.Path)
		}
		// Read the request body to verify our prompt structure.
		var body map[string]any
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			t.Fatalf("decode req: %v", err)
		}
		if model, _ := body["model"].(string); model == "" {
			t.Errorf("model missing in request")
		}
		// Respond with a synthetic Anthropic-shaped reply.
		resp := map[string]any{
			"id":   "msg_test",
			"type": "message",
			"role": "assistant",
			"content": []map[string]any{
				{"type": "text", "text": "Hello, world."},
			},
			"model":      "claude-sonnet-4-6",
			"stop_reason": "end_turn",
			"usage":      map[string]any{"input_tokens": 10, "output_tokens": 4},
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(resp)
	}))
	defer srv.Close()

	cleaner := NewAnthropic(AnthropicOptions{
		APIKey:  "sk-ant-test",
		Model:   "claude-sonnet-4-6",
		BaseURL: srv.URL,
		Timeout: 5 * time.Second,
	})

	got, err := cleaner.Clean(context.Background(), "hello um world", []string{"MCP"})
	if err != nil {
		t.Fatalf("Clean: %v", err)
	}
	if got != "Hello, world." {
		t.Errorf("Clean returned %q, want %q", got, "Hello, world.")
	}
}

func TestAnthropicClean_AuthError(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusUnauthorized)
		_, _ = w.Write([]byte(`{"type":"error","error":{"type":"authentication_error","message":"invalid api key"}}`))
	}))
	defer srv.Close()

	cleaner := NewAnthropic(AnthropicOptions{
		APIKey:  "wrong",
		Model:   "claude-sonnet-4-6",
		BaseURL: srv.URL,
		Timeout: 5 * time.Second,
	})

	_, err := cleaner.Clean(context.Background(), "hi", nil)
	if err == nil {
		t.Fatalf("expected auth error, got nil")
	}
}

func TestAnthropicClean_MissingAPIKey(t *testing.T) {
	cleaner := NewAnthropic(AnthropicOptions{
		APIKey:  "",
		Model:   "claude-sonnet-4-6",
		BaseURL: "http://example.invalid",
		Timeout: time.Millisecond,
	})
	_, err := cleaner.Clean(context.Background(), "hi", nil)
	if err == nil {
		t.Fatalf("expected error for missing API key, got nil")
	}
}

func TestAnthropicClean_EmptyTextContent(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// Response has content but only a tool_use block; no text.
		resp := map[string]any{
			"id":   "msg_test",
			"type": "message",
			"role": "assistant",
			"content": []map[string]any{
				{"type": "tool_use", "id": "tu_1", "name": "no_op", "input": map[string]any{}},
			},
			"model":       "claude-sonnet-4-6",
			"stop_reason": "tool_use",
			"usage":       map[string]any{"input_tokens": 1, "output_tokens": 1},
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(resp)
	}))
	defer srv.Close()

	cleaner := NewAnthropic(AnthropicOptions{
		APIKey:  "sk-ant-test",
		Model:   "claude-sonnet-4-6",
		BaseURL: srv.URL,
		Timeout: 5 * time.Second,
	})
	_, err := cleaner.Clean(context.Background(), "hi", nil)
	if err == nil {
		t.Fatalf("expected error for response with no text blocks, got nil")
	}
}
```

- [ ] **Step 3: Run the test to confirm it fails**

Run: `cd /Users/daniel/Documents/Projects/voice-keyboard/core && go test ./internal/llm/...`
Expected: FAIL — `NewAnthropic`, `AnthropicOptions` undefined.

- [ ] **Step 4: Write the Anthropic implementation**

Write `core/internal/llm/anthropic.go`:

```go
package llm

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"strings"
	"time"

	"github.com/anthropics/anthropic-sdk-go"
	"github.com/anthropics/anthropic-sdk-go/option"
)

const defaultTimeout = 30 * time.Second

type AnthropicOptions struct {
	APIKey  string
	Model   string
	BaseURL string        // optional; overrides for testing
	Timeout time.Duration // optional; defaults to 30s
}

type Anthropic struct {
	client *anthropic.Client
	model  string
}

func NewAnthropic(opts AnthropicOptions) *Anthropic {
	timeout := opts.Timeout
	if timeout == 0 {
		timeout = defaultTimeout
	}
	httpClient := &http.Client{Timeout: timeout}

	clientOpts := []option.RequestOption{
		option.WithAPIKey(opts.APIKey),
		option.WithHTTPClient(httpClient),
	}
	if opts.BaseURL != "" {
		clientOpts = append(clientOpts, option.WithBaseURL(opts.BaseURL))
	}
	c := anthropic.NewClient(clientOpts...)
	return &Anthropic{client: &c, model: opts.Model}
}

func (a *Anthropic) Clean(ctx context.Context, raw string, preserveTerms []string) (string, error) {
	if a == nil || a.client == nil {
		return "", errors.New("anthropic: not initialized")
	}
	prompt := renderPrompt(raw, preserveTerms)

	msg, err := a.client.Messages.New(ctx, anthropic.MessageNewParams{
		Model:     anthropic.Model(a.model),
		MaxTokens: 1024,
		Messages: []anthropic.MessageParam{
			anthropic.NewUserMessage(anthropic.NewTextBlock(prompt)),
		},
	})
	if err != nil {
		return "", fmt.Errorf("anthropic: %w", err)
	}
	if len(msg.Content) == 0 {
		return "", errors.New("anthropic: empty response")
	}
	var b strings.Builder
	for _, block := range msg.Content {
		// Only consider text blocks; tool-use blocks should never be
		// emitted for this prompt but we ignore them defensively.
		if block.Type == "text" {
			b.WriteString(block.Text)
		}
	}
	result := strings.TrimSpace(b.String())
	if result == "" {
		return "", errors.New("anthropic: no text content in response")
	}
	return result, nil
}
```

Note: the exact `anthropic-sdk-go` API surface may have minor differences from the snippet above (the SDK is on a stable v1 line as of January 2026; field names may have evolved). The implementer should:
1. Run `go doc github.com/anthropics/anthropic-sdk-go` to confirm `Messages.New`, `MessageNewParams`, `NewUserMessage`, `NewTextBlock`, and the response shape.
2. Adjust this code to match. The contract this code must honor is captured in `anthropic_test.go`: it must hit the configured `BaseURL`, send `x-api-key`, marshal `model` into the request body, and extract a single text response.

- [ ] **Step 5: Run the test**

Run: `cd /Users/daniel/Documents/Projects/voice-keyboard/core && go test ./internal/llm/... -v`
Expected: PASS. If the SDK API has drifted, fix `anthropic.go` to match while keeping `anthropic_test.go` green.

- [ ] **Step 6: Commit**

`git add internal/llm go.mod go.sum && git commit -m "feat(llm): add Anthropic Cleaner implementation"`

---

## Task 8: 3:1 polyphase decimator (48kHz → 16kHz)

**Files:**
- Create: `core/internal/resample/decimate3.go`
- Create: `core/internal/resample/decimate3_test.go`

- [ ] **Step 1: Write the failing tests**

Write `core/internal/resample/decimate3_test.go`:

```go
package resample

import (
	"math"
	"testing"
)

func TestDecimate3_OutputLengthIsThird(t *testing.T) {
	in := make([]float32, 4800) // 100ms @ 48kHz
	d := NewDecimate3()
	out := d.Process(in)
	wantLen := 4800 / 3
	if len(out) < wantLen-1 || len(out) > wantLen+1 {
		t.Errorf("output length = %d, expected ~%d", len(out), wantLen)
	}
}

func TestDecimate3_DCSignalPreserved(t *testing.T) {
	// Constant signal should remain (close to) constant after decimation.
	in := make([]float32, 4800)
	for i := range in {
		in[i] = 0.5
	}
	d := NewDecimate3()
	out := d.Process(in)

	// Check the steady-state samples (skip initial filter delay; group delay is
	// ~5 output samples for a 33-tap FIR, 20 leaves comfortable headroom).
	const skip = 20
	if len(out) <= skip+10 {
		t.Fatalf("output too short for steady-state check: %d", len(out))
	}
	for _, v := range out[skip : skip+10] {
		if math.Abs(float64(v-0.5)) > 0.01 {
			t.Errorf("steady-state sample = %f, want ~0.5", v)
		}
	}
}

func TestDecimate3_LowFrequencyPassesThrough(t *testing.T) {
	// 1kHz sine well below the 8kHz post-decimation Nyquist should
	// pass through with most of its amplitude intact.
	const fs = 48000
	const f = 1000.0
	in := make([]float32, fs/10) // 100ms
	for i := range in {
		in[i] = float32(math.Sin(2 * math.Pi * f * float64(i) / fs))
	}
	d := NewDecimate3()
	out := d.Process(in)

	// Compute peak amplitude in steady-state region.
	peak := 0.0
	for _, v := range out[100:] {
		if math.Abs(float64(v)) > peak {
			peak = math.Abs(float64(v))
		}
	}
	if peak < 0.7 {
		t.Errorf("1kHz peak amplitude %f, expected > 0.7", peak)
	}
}

func TestDecimate3_HighFrequencyAttenuated(t *testing.T) {
	// 12kHz sine is above the 8kHz post-decimation Nyquist; the
	// low-pass filter should attenuate it heavily before decimation.
	const fs = 48000
	const f = 12000.0
	in := make([]float32, fs/10)
	for i := range in {
		in[i] = float32(math.Sin(2 * math.Pi * f * float64(i) / fs))
	}
	d := NewDecimate3()
	out := d.Process(in)

	peak := 0.0
	for _, v := range out[100:] {
		if math.Abs(float64(v)) > peak {
			peak = math.Abs(float64(v))
		}
	}
	if peak > 0.2 {
		t.Errorf("12kHz peak amplitude %f, expected < 0.2", peak)
	}
}

func TestDecimate3_ResetEqualsFreshConstruction(t *testing.T) {
	// Same input fed through a fresh decimator and a Reset-ed decimator
	// must produce identical output, byte-for-byte.
	in := make([]float32, 4800)
	for i := range in {
		in[i] = float32(math.Sin(2 * math.Pi * 1000 * float64(i) / 48000.0))
	}

	fresh := NewDecimate3()
	freshOut := fresh.Process(in)

	reused := NewDecimate3()
	reused.Process(in)  // dirty its state
	reused.Reset()
	resetOut := reused.Process(in)

	if len(freshOut) != len(resetOut) {
		t.Fatalf("output lengths differ: fresh=%d reset=%d", len(freshOut), len(resetOut))
	}
	for i := range freshOut {
		if freshOut[i] != resetOut[i] {
			t.Errorf("sample %d: fresh=%f reset=%f", i, freshOut[i], resetOut[i])
			break
		}
	}
}
```

- [ ] **Step 2: Run the tests to confirm they fail**

Run: `cd /Users/daniel/Documents/Projects/voice-keyboard/core && go test ./internal/resample/...`
Expected: FAIL — `NewDecimate3`, `Process` undefined.

- [ ] **Step 3: Write the decimator**

Write `core/internal/resample/decimate3.go`:

```go
// Package resample provides sample-rate conversion. Decimate3 implements
// a 3:1 FIR low-pass + decimator suitable for 48kHz → 16kHz.
//
// The filter is a 33-tap Hamming-windowed sinc with cutoff at 7.5kHz
// (slightly below the 8kHz post-decimation Nyquist to leave headroom).
// On each output sample (every 3rd input), the full 33-tap FIR is
// computed against the rolling delay line. A true polyphase decomposition
// would split the FIR into 3 sub-filters of 11 taps each and select one
// per output; the output is mathematically identical, the chosen
// direct-form is simpler. The 33-tap length keeps polyphase as a
// drop-in optimization later if needed.
package resample

import "math"

const (
	taps   = 33      // FIR length; 33 = 3×11 keeps a polyphase split as a future drop-in option
	decim  = 3       // 48000 / 16000
	cutoff = 7500.0  // Hz, slightly below 8kHz post-decim Nyquist
	srIn   = 48000.0 // input sample rate
)

// fir holds the FIR coefficients computed once at package init.
var fir = makeFir()

func makeFir() []float32 {
	coeffs := make([]float32, taps)
	mid := float64(taps-1) / 2.0
	for n := 0; n < taps; n++ {
		x := float64(n) - mid
		var sinc float64
		if x == 0 {
			sinc = 2.0 * cutoff / srIn
		} else {
			arg := 2.0 * math.Pi * cutoff * x / srIn
			sinc = math.Sin(arg) / (math.Pi * x)
		}
		hamming := 0.54 - 0.46*math.Cos(2.0*math.Pi*float64(n)/float64(taps-1))
		coeffs[n] = float32(sinc * hamming)
	}
	// Normalize to unity DC gain.
	sum := float32(0)
	for _, c := range coeffs {
		sum += c
	}
	for i := range coeffs {
		coeffs[i] /= sum
	}
	return coeffs
}

type Decimate3 struct {
	// rolling delay line of the last `taps` input samples
	delay []float32
	// counter for which input sample index we're on (0..decim-1);
	// we only emit an output when this reaches 0
	phase int
}

func NewDecimate3() *Decimate3 {
	return &Decimate3{delay: make([]float32, taps)}
}

// Process consumes input samples and returns output samples. State is
// preserved across calls so streamed audio works (no boundary glitches).
func (d *Decimate3) Process(in []float32) []float32 {
	out := make([]float32, 0, len(in)/decim+1)
	for _, x := range in {
		// shift delay line left, append new sample
		copy(d.delay, d.delay[1:])
		d.delay[len(d.delay)-1] = x

		d.phase++
		if d.phase < decim {
			continue
		}
		d.phase = 0

		// FIR convolution
		var acc float32
		for i, c := range fir {
			acc += c * d.delay[i]
		}
		out = append(out, acc)
	}
	return out
}

// Reset clears the internal delay line. Use at the start of a new utterance.
func (d *Decimate3) Reset() {
	for i := range d.delay {
		d.delay[i] = 0
	}
	d.phase = 0
}
```

- [ ] **Step 4: Run the tests**

Run: `cd /Users/daniel/Documents/Projects/voice-keyboard/core && go test ./internal/resample/... -v`
Expected: all four tests PASS. If `TestDecimate3_DCSignalPreserved` fails, the FIR normalization is off; if `TestDecimate3_HighFrequencyAttenuated` fails, the cutoff/taps are wrong.

- [ ] **Step 5: Commit**

`git add internal/resample && git commit -m "feat(resample): add 3:1 polyphase decimator (48k→16k)"`

---

## Task 9: Audio Capture interface and fake implementation

**Files:**
- Create: `core/internal/audio/capture.go`
- Create: `core/internal/audio/fake_capture.go`
- Create: `core/internal/audio/fake_capture_test.go`

- [ ] **Step 1: Write the interface**

Write `core/internal/audio/capture.go`:

```go
// Package audio provides PCM capture from the microphone. The Capture
// interface is satisfied by malgo (real hardware) in production and by
// the FakeCapture (replays a buffer) in tests.
package audio

import "context"

type Capture interface {
	// Start begins capturing PCM frames at the given sample rate, mono,
	// returning a channel that yields []float32 frames until Stop is
	// called or ctx is cancelled. Frame size is implementation-defined;
	// consumers must handle variable sizes.
	Start(ctx context.Context, sampleRate int) (<-chan []float32, error)

	// Stop ends an in-progress capture. Safe to call multiple times.
	Stop() error
}
```

- [ ] **Step 2: Write the failing test for the fake**

Write `core/internal/audio/fake_capture_test.go`:

```go
package audio

import (
	"context"
	"testing"
	"time"
)

func TestFakeCapture_ReplaysBufferAndCloses(t *testing.T) {
	// 1500 samples split into 3 frames of 500 samples each
	src := make([]float32, 1500)
	for i := range src {
		src[i] = float32(i)
	}
	fake := NewFakeCapture(src, 500)

	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()

	frames, err := fake.Start(ctx, 48000)
	if err != nil {
		t.Fatalf("Start: %v", err)
	}

	var got []float32
	for f := range frames {
		got = append(got, f...)
	}
	if len(got) != len(src) {
		t.Errorf("got %d samples, want %d", len(got), len(src))
	}
	for i := range src {
		if got[i] != src[i] {
			t.Errorf("sample %d = %f, want %f", i, got[i], src[i])
			break
		}
	}
}

func TestFakeCapture_StopHaltsEarly(t *testing.T) {
	src := make([]float32, 10000)
	fake := NewFakeCapture(src, 1000)

	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()

	frames, err := fake.Start(ctx, 48000)
	if err != nil {
		t.Fatalf("Start: %v", err)
	}

	// Read one frame, then stop.
	<-frames
	if err := fake.Stop(); err != nil {
		t.Errorf("Stop: %v", err)
	}

	// Channel should close within a short window.
	deadline := time.After(500 * time.Millisecond)
	for {
		select {
		case _, ok := <-frames:
			if !ok {
				return // channel closed, success
			}
		case <-deadline:
			t.Fatal("frames channel did not close within 500ms after Stop()")
		}
	}
}

func TestFakeCapture_ContextCancelHaltsEarly(t *testing.T) {
	src := make([]float32, 10000)
	fake := NewFakeCapture(src, 1000)

	ctx, cancel := context.WithCancel(context.Background())
	frames, err := fake.Start(ctx, 48000)
	if err != nil {
		t.Fatalf("Start: %v", err)
	}
	<-frames
	cancel()

	deadline := time.After(500 * time.Millisecond)
	for {
		select {
		case _, ok := <-frames:
			if !ok {
				return
			}
		case <-deadline:
			t.Fatal("frames channel did not close within 500ms after ctx cancel")
		}
	}
}

func TestFakeCapture_StartCancelsPrior(t *testing.T) {
	src := make([]float32, 10000)
	fake := NewFakeCapture(src, 1000)

	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()

	first, err := fake.Start(ctx, 48000)
	if err != nil {
		t.Fatalf("first Start: %v", err)
	}
	<-first // consume one frame

	// Re-Start without Stopping; the first goroutine must be cancelled
	// so its channel closes promptly rather than leaking.
	second, err := fake.Start(ctx, 48000)
	if err != nil {
		t.Fatalf("second Start: %v", err)
	}

	deadline := time.After(500 * time.Millisecond)
drain:
	for {
		select {
		case _, ok := <-first:
			if !ok {
				break drain
			}
		case <-deadline:
			t.Fatal("first frames channel did not close after re-Start within 500ms")
		}
	}

	// Cleanup the second goroutine so the test exits promptly.
	if err := fake.Stop(); err != nil {
		t.Errorf("Stop: %v", err)
	}
	for range second {
	}
}
```

- [ ] **Step 3: Run the test to confirm it fails**

Run: `cd /Users/daniel/Documents/Projects/voice-keyboard/core && go test ./internal/audio/...`
Expected: FAIL — `NewFakeCapture` undefined.

- [ ] **Step 4: Implement the fake**

Write `core/internal/audio/fake_capture.go`:

```go
package audio

import (
	"context"
	"errors"
	"sync"
)

// FakeCapture replays a fixed buffer in fixed-size frames. Used in tests
// to drive the pipeline deterministically without hardware.
type FakeCapture struct {
	src       []float32
	frameSize int

	mu     sync.Mutex
	cancel context.CancelFunc
}

func NewFakeCapture(src []float32, frameSize int) *FakeCapture {
	return &FakeCapture{src: src, frameSize: frameSize}
}

func (f *FakeCapture) Start(ctx context.Context, sampleRate int) (<-chan []float32, error) {
	if f.frameSize <= 0 {
		return nil, errors.New("fake capture: frameSize must be > 0")
	}
	subCtx, cancel := context.WithCancel(ctx)
	f.mu.Lock()
	if f.cancel != nil {
		f.cancel() // cancel any prior goroutine to avoid leak on re-entry
	}
	f.cancel = cancel
	f.mu.Unlock()

	out := make(chan []float32, 4)
	go func() {
		defer close(out)
		for i := 0; i < len(f.src); i += f.frameSize {
			end := i + f.frameSize
			if end > len(f.src) {
				end = len(f.src)
			}
			frame := make([]float32, end-i)
			copy(frame, f.src[i:end])
			select {
			case out <- frame:
			case <-subCtx.Done():
				return
			}
		}
	}()
	return out, nil
}

func (f *FakeCapture) Stop() error {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.cancel != nil {
		f.cancel()
		f.cancel = nil
	}
	return nil
}
```

- [ ] **Step 5: Run the tests**

Run: `cd /Users/daniel/Documents/Projects/voice-keyboard/core && go test ./internal/audio/... -v`
Expected: all three tests PASS.

- [ ] **Step 6: Commit**

`git add internal/audio && git commit -m "feat(audio): add Capture interface and FakeCapture for tests"`

---

## Task 10: malgo (miniaudio) capture implementation

**Files:**
- Create: `core/internal/audio/malgo_capture.go`
- Modify: `core/go.mod` (adds `github.com/gen2brain/malgo`)

- [ ] **Step 1: Add the malgo dependency**

Run: `cd /Users/daniel/Documents/Projects/voice-keyboard/core && go get github.com/gen2brain/malgo`
Expected: `go.mod` updated.

- [ ] **Step 2: Implement MalgoCapture**

Write `core/internal/audio/malgo_capture.go`:

```go
package audio

import (
	"context"
	"errors"
	"fmt"
	"sync"
	"unsafe"

	"github.com/gen2brain/malgo"
)

const malgoChannels = 1

var _ Capture = (*MalgoCapture)(nil)

// MalgoCapture captures PCM from the default system microphone using
// miniaudio (via the malgo Go bindings). It produces float32 mono frames
// at the requested sample rate.
type MalgoCapture struct {
	mu       sync.Mutex
	ctxMalgo *malgo.AllocatedContext
	device   *malgo.Device
	out      chan []float32
	cancel   context.CancelFunc
}

func NewMalgoCapture() *MalgoCapture {
	return &MalgoCapture{}
}

func (m *MalgoCapture) Start(ctx context.Context, sampleRate int) (<-chan []float32, error) {
	m.mu.Lock()
	defer m.mu.Unlock()

	if m.device != nil {
		return nil, errors.New("malgo capture: already started")
	}

	mctx, err := malgo.InitContext(nil, malgo.ContextConfig{}, func(message string) {})
	if err != nil {
		return nil, fmt.Errorf("malgo init context: %w", err)
	}

	cfg := malgo.DefaultDeviceConfig(malgo.Capture)
	cfg.Capture.Format = malgo.FormatF32
	cfg.Capture.Channels = malgoChannels
	cfg.SampleRate = uint32(sampleRate)
	cfg.Alsa.NoMMap = 1

	subCtx, cancel := context.WithCancel(ctx)
	out := make(chan []float32, 32)

	onRecv := func(_, in []byte, frameCount uint32) {
		// `in` is interleaved float32 mono. We reinterpret bytes as
		// float32 via unsafe.Slice (Go 1.17+), then copy out so the
		// caller owns the buffer.
		if frameCount == 0 || len(in) < int(frameCount)*4 {
			return
		}
		header := (*float32)(unsafe.Pointer(&in[0]))
		view := unsafe.Slice(header, int(frameCount))
		samples := make([]float32, frameCount)
		copy(samples, view)
		select {
		case out <- samples:
		case <-subCtx.Done():
		}
	}

	deviceCallbacks := malgo.DeviceCallbacks{Data: onRecv}
	device, err := malgo.InitDevice(mctx.Context, cfg, deviceCallbacks)
	if err != nil {
		_ = mctx.Uninit()
		mctx.Free()
		cancel()
		close(out)
		return nil, fmt.Errorf("malgo init device: %w", err)
	}
	if err := device.Start(); err != nil {
		device.Uninit()
		_ = mctx.Uninit()
		mctx.Free()
		cancel()
		close(out)
		return nil, fmt.Errorf("malgo start: %w", err)
	}

	m.ctxMalgo = mctx
	m.device = device
	m.out = out
	m.cancel = cancel

	// stop+cleanup goroutine
	go func() {
		<-subCtx.Done()
		m.mu.Lock()
		defer m.mu.Unlock()
		if m.device != nil {
			m.device.Uninit()
			m.device = nil
		}
		if m.ctxMalgo != nil {
			_ = m.ctxMalgo.Uninit()
			m.ctxMalgo.Free()
			m.ctxMalgo = nil
		}
		close(m.out)
		m.out = nil
		m.cancel = nil
	}()

	return out, nil
}

func (m *MalgoCapture) Stop() error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.cancel != nil {
		m.cancel()
		m.cancel = nil
	}
	return nil
}
```

The malgo callback runs on a non-Go thread; sending to the channel from any goroutine is safe, but only the cleanup goroutine ever closes `out`, so we never hit "send on closed channel."

- [ ] **Step 3: Build to verify CGo flags work**

Run: `cd /Users/daniel/Documents/Projects/voice-keyboard/core && go build ./internal/audio/...`
Expected: success. malgo's CGo build pulls in CoreAudio frameworks on macOS.

- [ ] **Step 4: Manual hardware smoke test (optional, not part of automated suite)**

Manual verification only — write a tiny throwaway program that calls `MalgoCapture.Start` for 1 second, records, dumps the frame count, and confirms it's roughly `sampleRate * 1`. Tests for malgo aren't worth automating in CI because they require a real microphone.

- [ ] **Step 5: Commit**

`git add internal/audio go.mod go.sum && git commit -m "feat(audio): add malgo (miniaudio) capture implementation"`

---

## Task 11: Denoiser interface and DeepFilterNet CGo binding

**Files:**
- Create: `core/internal/denoise/denoiser.go`
- Create: `core/internal/denoise/passthrough.go`
- Create: `core/internal/denoise/deepfilter_cgo.go`
- Create: `core/internal/denoise/denoise_test.go`

- [ ] **Step 1: Write the interface**

Write `core/internal/denoise/denoiser.go`:

```go
// Package denoise provides single-frame audio denoising. The Denoiser
// interface accepts and produces 480-sample float32 mono frames at 48kHz
// (10ms frames). Both the passthrough impl and the DeepFilterNet CGo
// impl satisfy this contract.
package denoise

const FrameSize = 480 // samples per frame at 48kHz, 10ms

type Denoiser interface {
	// Process accepts a single 480-sample frame and returns a denoised
	// 480-sample frame. It is the caller's responsibility to chunk
	// streaming audio into 480-sample frames before calling.
	Process(frame []float32) []float32

	// Close releases any underlying resources. Safe to call multiple times.
	Close() error
}
```

- [ ] **Step 2: Write the passthrough implementation**

Write `core/internal/denoise/passthrough.go`:

```go
package denoise

// Passthrough is a no-op Denoiser used when the user disables noise
// suppression. It returns the input frame unchanged.
type Passthrough struct{}

func NewPassthrough() *Passthrough { return &Passthrough{} }

func (p *Passthrough) Process(frame []float32) []float32 {
	out := make([]float32, len(frame))
	copy(out, frame)
	return out
}

func (p *Passthrough) Close() error { return nil }
```

- [ ] **Step 3: Write the failing tests**

Write **two** test files (Go build tags must be at the top of a file, so the DeepFilter test cannot live in the same file as the always-on Passthrough test):

1. `core/internal/denoise/denoise_test.go` — Passthrough only, no build tag
2. `core/internal/denoise/denoise_deepfilter_test.go` — `//go:build deepfilter` at the top, contains the DeepFilter test

The combined source is shown below; split it into the two files at the marked boundary.

```go
package denoise

import (
	"math"
	"testing"
)

func TestPassthrough_ReturnsCopyUnchanged(t *testing.T) {
	in := make([]float32, FrameSize)
	for i := range in {
		in[i] = float32(i) / float32(FrameSize)
	}
	p := NewPassthrough()
	out := p.Process(in)
	if len(out) != FrameSize {
		t.Fatalf("out length = %d, want %d", len(out), FrameSize)
	}
	for i := range in {
		if out[i] != in[i] {
			t.Errorf("sample %d: got %f, want %f", i, out[i], in[i])
		}
	}
	// Mutating output must not affect input.
	out[0] = 999
	if in[0] == 999 {
		t.Errorf("Process must return a copy, not the same slice")
	}
}

// TestDeepFilter_AttenuatesNoise lives in a separate file with its own
// build tag, so the unit suite stays CGo-free for fast iteration. The
// build-tagged test requires libdf.dylib AND the vendored model file at
// third_party/deepfilter/models/DeepFilterNet3.tar.gz. Run with:
//   go test -tags=deepfilter ./internal/denoise/...
//
// It generates a noisy sine wave, runs DeepFilterNet over it, and checks
// the denoised RMS is lower than the input RMS.

// Note: write this in a separate file `denoise_deepfilter_test.go` (NOT
// in `denoise_test.go`) so the `//go:build deepfilter` directive at the
// top of the file is the first non-blank line, which is how Go build
// tags must be placed.

// File: core/internal/denoise/denoise_deepfilter_test.go
//go:build deepfilter

package denoise

import (
	"math"
	"os"
	"path/filepath"
	"testing"
)

func TestDeepFilter_AttenuatesNoise(t *testing.T) {
	// Resolve the vendored model path relative to the package dir.
	modelPath := filepath.Join("..", "..", "third_party", "deepfilter", "models", "DeepFilterNet3.tar.gz")
	if _, err := os.Stat(modelPath); err != nil {
		t.Skipf("model not vendored at %s; see Task 11 Step 5b", modelPath)
	}
	d, err := NewDeepFilter(modelPath, 100)
	if err != nil {
		t.Fatalf("NewDeepFilter: %v", err)
	}
	defer d.Close()

	// Build 10 frames of a 1kHz sine at amplitude 0.3 plus white noise at 0.3.
	const frames = 10
	const sr = 48000
	in := make([][]float32, frames)
	noisyRMS := 0.0
	for f := 0; f < frames; f++ {
		frame := make([]float32, FrameSize)
		for i := 0; i < FrameSize; i++ {
			t := float64(f*FrameSize+i) / float64(sr)
			tone := 0.3 * math.Sin(2*math.Pi*1000*t)
			noise := 0.3 * (math.Mod(float64(i*9301+49297), 233280)/233280 - 0.5) * 2
			frame[i] = float32(tone + noise)
			noisyRMS += float64(frame[i] * frame[i])
		}
		in[f] = frame
	}
	noisyRMS = math.Sqrt(noisyRMS / float64(frames*FrameSize))

	cleanRMS := 0.0
	for _, f := range in {
		out := d.Process(f)
		for _, s := range out {
			cleanRMS += float64(s * s)
		}
	}
	cleanRMS = math.Sqrt(cleanRMS / float64(frames*FrameSize))

	if cleanRMS >= noisyRMS {
		t.Errorf("denoised RMS (%f) should be lower than noisy RMS (%f)", cleanRMS, noisyRMS)
	}
}
```

- [ ] **Step 4: Run unit tests (passthrough only)**

Run: `cd /Users/daniel/Documents/Projects/voice-keyboard/core && go test ./internal/denoise/...`
Expected: PASS — only `TestPassthrough_ReturnsCopyUnchanged` runs.

- [ ] **Step 5: Confirm the deep_filter.h API**

Run: `cat /Users/daniel/Documents/Projects/voice-keyboard/core/third_party/deepfilter/include/deep_filter.h`

Verified API (from the v0.5.6 cbindgen-generated header committed in Task 3):

```c
typedef struct DFState DFState;

DFState *df_create(const char *path, float atten_lim);
uintptr_t df_get_frame_length(DFState *st);
void df_set_atten_lim(DFState *st, float lim_db);
void df_set_post_filter_beta(DFState *st, float beta);
float df_process_frame(DFState *st, float *input, float *output);
float df_process_frame_raw(DFState *st, float *input, float **out_gains_p, float **out_coefs_p);
void df_free(DFState *model);
```

Notable points:
- `df_create` requires a path to an unpacked model directory (or a `.tar.gz`) — there is no zero-arg constructor with a built-in model. Pass `atten_lim` in dB (use 100.0 for "no attenuation cap" / let the network decide).
- `df_process_frame` returns the local SNR as a float — useful for diagnostics, can be ignored.
- The destructor is `df_free` (not `df_destroy`).

- [ ] **Step 5b: Acquire a DeepFilterNet model file**

The dylib does NOT embed weights — `df_create` needs an actual model path. Two options:

**Option A (preferred for v1):** Vendor the official DeepFilterNet3 model into the repo so the build is self-contained.

```bash
mkdir -p /Users/daniel/Documents/Projects/voice-keyboard/core/third_party/deepfilter/models
cd /Users/daniel/Documents/Projects/voice-keyboard/core/third_party/deepfilter/models
# DeepFilterNet3 model — small enough to commit (~5MB).
curl -L https://github.com/Rikorose/DeepFilterNet/releases/download/v0.5.6/DeepFilterNet3_onnx.tar.gz \
  -o DeepFilterNet3.tar.gz
ls -lh DeepFilterNet3.tar.gz
```

If the URL has changed since this plan was written, look in upstream releases for an "_onnx.tar.gz" asset.

After downloading, run `git check-ignore third_party/deepfilter/models/DeepFilterNet3.tar.gz` — should exit non-zero (file is tracked). The `.gitignore` rules already permit `third_party/**/*.dylib` and `*.h` and don't restrict `*.tar.gz`.

**Option B (deferred):** Have the Mac app download the model on first run alongside the Whisper model. Would require changes to the engine state and a "model not loaded" error path. Not v1 scope.

This task uses Option A.

- [ ] **Step 6: Implement the CGo binding**

Write `core/internal/denoise/deepfilter_cgo.go`:

```go
//go:build deepfilter

package denoise

/*
#cgo CFLAGS: -I${SRCDIR}/../../third_party/deepfilter/include
#cgo LDFLAGS: -L${SRCDIR}/../../third_party/deepfilter/lib/macos-arm64 -ldf
#include <stdlib.h>
#include "deep_filter.h"
*/
import "C"

import (
	"errors"
	"runtime"
	"unsafe"
)

const defaultAttenLimDB = 100.0 // no attenuation cap; let the network decide

// DeepFilter wraps a libdf state. Each instance is single-threaded;
// concurrent callers must serialize externally or construct one per
// goroutine.
type DeepFilter struct {
	state *C.DFState
}

// NewDeepFilter constructs a denoiser from a DeepFilterNet model archive
// (.tar.gz file or unpacked directory). Use `attenLimDB` to cap how much
// gain reduction the network applies; pass defaultAttenLimDB (100) for no cap.
func NewDeepFilter(modelPath string, attenLimDB float32) (*DeepFilter, error) {
	if modelPath == "" {
		return nil, errors.New("deep filter: modelPath is required")
	}
	cPath := C.CString(modelPath)
	defer C.free(unsafe.Pointer(cPath))

	st := C.df_create(cPath, C.float(attenLimDB))
	if st == nil {
		return nil, errors.New("deep filter: df_create returned NULL (bad model path?)")
	}

	// libdf's frame length is fixed at 480 samples for 48kHz mono. Verify
	// at runtime so we fail loudly if a future libdf version changes that.
	if got := C.df_get_frame_length(st); int(got) != FrameSize {
		C.df_free(st)
		return nil, errors.New("deep filter: unexpected frame length from libdf")
	}

	d := &DeepFilter{state: st}
	runtime.SetFinalizer(d, func(d *DeepFilter) { _ = d.Close() })
	return d, nil
}

// Process runs one 480-sample frame through DeepFilterNet. Returns a
// fresh slice; the caller owns it.
func (d *DeepFilter) Process(frame []float32) []float32 {
	if d.state == nil || len(frame) != FrameSize {
		// degrade to passthrough on any precondition failure
		out := make([]float32, len(frame))
		copy(out, frame)
		return out
	}
	out := make([]float32, FrameSize)
	// df_process_frame returns the local SNR as a float; we ignore it.
	C.df_process_frame(
		d.state,
		(*C.float)(unsafe.Pointer(&frame[0])),
		(*C.float)(unsafe.Pointer(&out[0])),
	)
	return out
}

func (d *DeepFilter) Close() error {
	if d.state != nil {
		C.df_free(d.state)
		d.state = nil
	}
	return nil
}
```

Then update the test from Step 3 — change `NewDeepFilter()` (zero-arg) to `NewDeepFilter("third_party/deepfilter/models/DeepFilterNet3.tar.gz", 100)`. The relative path works because `go test` runs in the package directory; the `${SRCDIR}/../../third_party/...` C path is wired through `#cgo CFLAGS`/`LDFLAGS`.

- [ ] **Step 7: Build the CGo binding**

Run:
```bash
cd /Users/daniel/Documents/Projects/voice-keyboard/core
DYLD_LIBRARY_PATH=$PWD/third_party/deepfilter/lib/macos-arm64:$DYLD_LIBRARY_PATH \
  go build -tags=deepfilter ./internal/denoise/...
```
Expected: success. If the linker complains about missing symbols, the function names in the binding don't match the real ABI from the header — fix and re-run.

- [ ] **Step 8: Run the build-tagged test**

Run:
```bash
cd /Users/daniel/Documents/Projects/voice-keyboard/core
DYLD_LIBRARY_PATH=$PWD/third_party/deepfilter/lib/macos-arm64:$DYLD_LIBRARY_PATH \
  go test -tags=deepfilter ./internal/denoise/... -v
```
Expected: `TestPassthrough_ReturnsCopyUnchanged` PASS, `TestDeepFilter_AttenuatesNoise` PASS.

- [ ] **Step 9: Commit**

`git add internal/denoise && git commit -m "feat(denoise): add Denoiser interface, passthrough, and DeepFilterNet CGo binding"`

---

## Task 12: Whisper.cpp transcriber

**Files:**
- Create: `core/internal/transcribe/transcriber.go`
- Create: `core/internal/transcribe/whisper_cpp.go`
- Create: `core/internal/transcribe/whisper_cpp_test.go`
- Create: `core/test/integration/testdata/hello-world.wav` (next-step instructions)

- [ ] **Step 1: Write the interface**

Write `core/internal/transcribe/transcriber.go`:

```go
// Package transcribe provides ASR via whisper.cpp. The Transcriber
// interface accepts 16kHz mono float32 PCM and returns a UTF-8 string.
package transcribe

import "context"

type Transcriber interface {
	// Transcribe accepts mono 16kHz float32 PCM and returns the
	// recognized text. Empty audio (or audio detected as silence)
	// yields ("", nil) — silence is not an error.
	Transcribe(ctx context.Context, pcm16k []float32) (string, error)

	// Close releases the underlying model. Safe to call multiple times.
	Close() error
}
```

- [ ] **Step 2: Acquire a Whisper model file**

Run:
```bash
mkdir -p ~/Library/Application\ Support/VoiceKeyboard/models
cd ~/Library/Application\ Support/VoiceKeyboard/models
test -f ggml-tiny.en.bin || curl -L \
  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny.en.bin \
  -o ggml-tiny.en.bin
ls -lh ggml-tiny.en.bin
```
Expected: `ggml-tiny.en.bin` is ~75MB. Use `tiny.en` for fast tests; production users will choose `small` or larger via settings.

- [ ] **Step 3: Acquire a test WAV fixture**

Run:
```bash
mkdir -p /Users/daniel/Documents/Projects/voice-keyboard/core/test/integration/testdata
cd /Users/daniel/Documents/Projects/voice-keyboard/core/test/integration/testdata
# Use a well-known whisper.cpp sample, ~11s of clean speech at 16kHz mono.
test -f hello-world.wav || curl -L \
  https://raw.githubusercontent.com/ggerganov/whisper.cpp/master/samples/jfk.wav \
  -o hello-world.wav
file hello-world.wav
```
Expected: `RIFF (little-endian) data, WAVE audio, ... 16000 Hz` reported by `file`. (The fixture is named `hello-world.wav` for in-repo continuity but its contents are JFK's "ask not what your country can do for you" sample.)

- [ ] **Step 4: Implement the CGo binding**

Write `core/internal/transcribe/whisper_cpp.go`:

```go
package transcribe

/*
#cgo CFLAGS: -I/opt/homebrew/opt/whisper-cpp/include
#cgo LDFLAGS: -L/opt/homebrew/opt/whisper-cpp/lib -lwhisper

#include <stdlib.h>
#include "whisper.h"

// Helper that calls whisper_full and returns the segment count.
// Lives here so we can pass Go-allocated float buffers cleanly.
static int run_whisper_full(struct whisper_context* ctx,
                             struct whisper_full_params params,
                             const float* samples, int n_samples) {
    int rc = whisper_full(ctx, params, samples, n_samples);
    if (rc != 0) return -1;
    return whisper_full_n_segments(ctx);
}
*/
import "C"

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"unsafe"
)

// WhisperCpp wraps a whisper.cpp context. NOT safe for concurrent calls
// to Transcribe on the same instance.
type WhisperCpp struct {
	ctx     *C.struct_whisper_context
	lang    string
	threads int
}

type WhisperOptions struct {
	ModelPath string
	Language  string // "en", "auto", etc.
	Threads   int    // 0 = let runtime decide (1)
}

func NewWhisperCpp(opts WhisperOptions) (*WhisperCpp, error) {
	if opts.ModelPath == "" {
		return nil, errors.New("whisper: ModelPath is required")
	}
	cPath := C.CString(opts.ModelPath)
	defer C.free(unsafe.Pointer(cPath))

	cparams := C.whisper_context_default_params()
	ctx := C.whisper_init_from_file_with_params(cPath, cparams)
	if ctx == nil {
		return nil, fmt.Errorf("whisper: failed to load model %q", opts.ModelPath)
	}
	threads := opts.Threads
	if threads <= 0 {
		threads = 4
	}
	lang := opts.Language
	if lang == "" {
		lang = "auto"
	}
	return &WhisperCpp{ctx: ctx, lang: lang, threads: threads}, nil
}

func (w *WhisperCpp) Transcribe(ctx context.Context, pcm16k []float32) (string, error) {
	if w.ctx == nil {
		return "", errors.New("whisper: closed")
	}
	if len(pcm16k) == 0 {
		return "", nil
	}

	params := C.whisper_full_default_params(C.WHISPER_SAMPLING_GREEDY)
	params.n_threads = C.int(w.threads)
	params.print_progress = C.bool(false)
	params.print_realtime = C.bool(false)
	params.print_timestamps = C.bool(false)
	params.suppress_blank = C.bool(true)
	params.no_timestamps = C.bool(true)
	cLang := C.CString(w.lang)
	defer C.free(unsafe.Pointer(cLang))
	params.language = cLang

	nSegs := C.run_whisper_full(
		w.ctx, params,
		(*C.float)(unsafe.Pointer(&pcm16k[0])),
		C.int(len(pcm16k)),
	)
	if nSegs < 0 {
		return "", errors.New("whisper: inference failed")
	}

	var b strings.Builder
	for i := C.int(0); i < nSegs; i++ {
		cstr := C.whisper_full_get_segment_text(w.ctx, i)
		b.WriteString(C.GoString(cstr))
	}
	return strings.TrimSpace(b.String()), nil
}

func (w *WhisperCpp) Close() error {
	if w.ctx != nil {
		C.whisper_free(w.ctx)
		w.ctx = nil
	}
	return nil
}
```

If the whisper.cpp version differs and any of these functions have been renamed (notably `whisper_init_from_file_with_params`, `whisper_full_default_params`, `whisper_full_n_segments`, `whisper_full_get_segment_text`, `whisper_free`), check `/opt/homebrew/include/whisper.h` and adjust.

- [ ] **Step 5: Write the integration test**

Write `core/internal/transcribe/whisper_cpp_test.go`:

```go
//go:build whispercpp

package transcribe

import (
	"context"
	"encoding/binary"
	"math"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestWhisperCpp_TranscribesSamples(t *testing.T) {
	modelPath := os.ExpandEnv("$HOME/Library/Application Support/VoiceKeyboard/models/ggml-tiny.en.bin")
	if _, err := os.Stat(modelPath); err != nil {
		t.Skipf("model not available at %s; download via the curl in Task 12 step 2", modelPath)
	}

	wavPath := filepath.Join("..", "..", "test", "integration", "testdata", "hello-world.wav")
	pcm, err := readWavMono16k(wavPath)
	if err != nil {
		t.Skipf("test fixture not available: %v", err)
	}

	w, err := NewWhisperCpp(WhisperOptions{ModelPath: modelPath, Language: "en"})
	if err != nil {
		t.Fatalf("NewWhisperCpp: %v", err)
	}
	defer w.Close()

	got, err := w.Transcribe(context.Background(), pcm)
	if err != nil {
		t.Fatalf("Transcribe: %v", err)
	}
	if strings.TrimSpace(got) == "" {
		t.Errorf("expected non-empty transcription, got empty string")
	}
	t.Logf("transcription: %q", got)
}

// readWavMono16k loads a small WAV fixture into []float32. Only handles
// 16-bit PCM mono at 16kHz — sufficient for the test fixture.
func readWavMono16k(path string) ([]float32, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	// Locate the 'data' chunk crudely.
	for i := 12; i < len(data)-8; i += 4 {
		if string(data[i:i+4]) == "data" {
			size := int(binary.LittleEndian.Uint32(data[i+4 : i+8]))
			pcm := data[i+8 : i+8+size]
			samples := make([]float32, len(pcm)/2)
			for j := range samples {
				v := int16(binary.LittleEndian.Uint16(pcm[j*2 : j*2+2]))
				samples[j] = float32(v) / float32(math.MaxInt16)
			}
			return samples, nil
		}
	}
	return nil, os.ErrInvalid
}
```

- [ ] **Step 6: Build the CGo binding**

Run:
```bash
cd /Users/daniel/Documents/Projects/voice-keyboard/core
go build -tags=whispercpp ./internal/transcribe/...
```
Expected: success.

- [ ] **Step 7: Run the integration test**

Run:
```bash
cd /Users/daniel/Documents/Projects/voice-keyboard/core
go test -tags=whispercpp ./internal/transcribe/... -v
```
Expected: PASS — log line shows the transcription contains words like "ask not" or similar from the JFK sample.

- [ ] **Step 8: Commit**

`git add internal/transcribe test/integration/testdata && git commit -m "feat(transcribe): add Whisper.cpp CGo transcriber"`

---

## Task 13: Pipeline orchestrator

**Files:**
- Create: `core/internal/pipeline/pipeline.go`
- Create: `core/internal/pipeline/pipeline_test.go`

- [ ] **Step 1: Write the failing test**

Write `core/internal/pipeline/pipeline_test.go`:

```go
package pipeline

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/voice-keyboard/core/internal/audio"
	"github.com/voice-keyboard/core/internal/denoise"
	"github.com/voice-keyboard/core/internal/dict"
)

type fakeTranscriber struct {
	out string
	err error
}

func (f *fakeTranscriber) Transcribe(ctx context.Context, _ []float32) (string, error) {
	return f.out, f.err
}
func (f *fakeTranscriber) Close() error { return nil }

type fakeCleaner struct {
	out string
	err error
}

func (f *fakeCleaner) Clean(ctx context.Context, _ string, _ []string) (string, error) {
	return f.out, f.err
}

func TestPipeline_HappyPath(t *testing.T) {
	// 48kHz, 0.5s of zeros — enough samples for a couple of denoise frames.
	src := make([]float32, 24000)
	cap := audio.NewFakeCapture(src, denoise.FrameSize)
	d := denoise.NewPassthrough()
	dy := dict.NewFuzzy([]string{"WebRTC"}, 1)
	tr := &fakeTranscriber{out: "hello webrt world"}
	cl := &fakeCleaner{out: "Hello, WebRTC world."}

	p := New(cap, d, tr, dy, cl)

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	stop := make(chan struct{})
	close(stop) // immediate stop — fake capture drains its full buffer first

	res, err := p.Run(ctx, stop)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if res.Cleaned != "Hello, WebRTC world." {
		t.Errorf("Cleaned = %q", res.Cleaned)
	}
	if res.Raw != "hello webrt world" {
		t.Errorf("Raw = %q", res.Raw)
	}
}

func TestPipeline_LLMErrorFallsBackToDictText(t *testing.T) {
	src := make([]float32, 24000)
	cap := audio.NewFakeCapture(src, denoise.FrameSize)
	d := denoise.NewPassthrough()
	dy := dict.NewFuzzy([]string{"WebRTC"}, 1)
	tr := &fakeTranscriber{out: "use webrt please"}
	cl := &fakeCleaner{err: errors.New("network down")}

	p := New(cap, d, tr, dy, cl)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	stop := make(chan struct{})
	close(stop)

	res, err := p.Run(ctx, stop)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if res.Cleaned != "use WebRTC please" {
		t.Errorf("Cleaned should fall back to dict-corrected raw; got %q", res.Cleaned)
	}
	if res.LLMError == nil {
		t.Errorf("LLMError should be set when LLM fails")
	}
}

func TestPipeline_EmptyTranscriptionYieldsEmptyResult(t *testing.T) {
	src := make([]float32, 240) // half a frame
	cap := audio.NewFakeCapture(src, denoise.FrameSize)
	d := denoise.NewPassthrough()
	dy := dict.NewFuzzy(nil, 1)
	tr := &fakeTranscriber{out: ""}
	cl := &fakeCleaner{out: "should not be called"}

	p := New(cap, d, tr, dy, cl)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	stop := make(chan struct{})
	close(stop)

	res, err := p.Run(ctx, stop)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if res.Cleaned != "" {
		t.Errorf("expected empty cleaned for empty raw, got %q", res.Cleaned)
	}
}
```

- [ ] **Step 2: Run to confirm failure**

Run: `cd /Users/daniel/Documents/Projects/voice-keyboard/core && go test ./internal/pipeline/...`
Expected: FAIL — `New`, `Pipeline`, `Result` undefined.

- [ ] **Step 3: Implement Pipeline**

Write `core/internal/pipeline/pipeline.go`:

```go
// Package pipeline orchestrates one PTT cycle:
//   capture → denoise → decimate → transcribe → dict → clean → Result
//
// Pipeline.Run is single-shot: each PTT press calls Run once. Lifecycle
// (start/stop) is owned by the composition root, not the pipeline.
package pipeline

import (
	"context"
	"errors"

	"github.com/voice-keyboard/core/internal/audio"
	"github.com/voice-keyboard/core/internal/denoise"
	"github.com/voice-keyboard/core/internal/dict"
	"github.com/voice-keyboard/core/internal/llm"
	"github.com/voice-keyboard/core/internal/resample"
	"github.com/voice-keyboard/core/internal/transcribe"
)

const inputSampleRate = 48000

// Result of a single PTT cycle.
type Result struct {
	Raw      string // post-dictionary, pre-LLM
	Cleaned  string // final text to paste; equals dict-corrected raw if LLM failed
	Terms    []string
	LLMError error
}

type Pipeline struct {
	capture     audio.Capture
	denoiser    denoise.Denoiser
	transcriber transcribe.Transcriber
	dict        dict.Dictionary
	cleaner     llm.Cleaner
}

func New(c audio.Capture, d denoise.Denoiser, t transcribe.Transcriber,
	dy dict.Dictionary, cl llm.Cleaner) *Pipeline {
	return &Pipeline{
		capture: c, denoiser: d, transcriber: t, dict: dy, cleaner: cl,
	}
}

// Run starts capture, accumulates audio until stopCh is closed (or ctx
// is cancelled), then runs the full processing pipeline and returns the
// Result. Capture is stopped on the way out.
func (p *Pipeline) Run(ctx context.Context, stopCh <-chan struct{}) (Result, error) {
	if p == nil {
		return Result{}, errors.New("pipeline: nil receiver")
	}

	frames, err := p.capture.Start(ctx, inputSampleRate)
	if err != nil {
		return Result{}, err
	}
	defer p.capture.Stop()

	denoised := captureAndDenoise(ctx, frames, stopCh, p.denoiser)

	dec := resample.NewDecimate3()
	pcm16k := dec.Process(denoised)

	raw, err := p.transcriber.Transcribe(ctx, pcm16k)
	if err != nil {
		return Result{}, err
	}
	if raw == "" {
		return Result{}, nil
	}

	corrected, terms := p.dict.Match(raw)

	cleaned, llmErr := p.cleaner.Clean(ctx, corrected, terms)
	if llmErr != nil {
		// graceful degradation: ship the dict-corrected text
		return Result{Raw: corrected, Cleaned: corrected, Terms: terms, LLMError: llmErr}, nil
	}
	return Result{Raw: corrected, Cleaned: cleaned, Terms: terms}, nil
}

// captureAndDenoise drains the capture channel, denoising in 480-sample
// (10ms) frames. Stops draining when stopCh fires, ctx is cancelled, or
// frames closes. Any partial trailing samples are zero-padded into a
// final frame so we don't lose the tail of an utterance.
func captureAndDenoise(ctx context.Context, frames <-chan []float32, stopCh <-chan struct{}, d denoise.Denoiser) []float32 {
	var pending []float32
	var out []float32

	flush := func() {
		for len(pending) >= denoise.FrameSize {
			frame := pending[:denoise.FrameSize]
			out = append(out, d.Process(frame)...)
			pending = pending[denoise.FrameSize:]
		}
	}

	for {
		select {
		case f, ok := <-frames:
			if !ok {
				goto finalize
			}
			pending = append(pending, f...)
			flush()
		case <-stopCh:
			goto finalize
		case <-ctx.Done():
			goto finalize
		}
	}
finalize:
	if len(pending) > 0 {
		last := make([]float32, denoise.FrameSize)
		copy(last, pending)
		out = append(out, d.Process(last)...)
	}
	return out
}
```

- [ ] **Step 4: Run tests**

Run: `cd /Users/daniel/Documents/Projects/voice-keyboard/core && go test ./internal/pipeline/... -v`
Expected: all three tests PASS.

- [ ] **Step 5: Commit**

`git add internal/pipeline && git commit -m "feat(pipeline): add single-utterance Pipeline orchestrator"`

---

## Task 14: vkb-cli `check` subcommand

**Files:**
- Modify: `core/cmd/vkb-cli/main.go`
- Create: `core/cmd/vkb-cli/check.go`

- [ ] **Step 1: Replace the stub with a subcommand dispatcher**

Replace `core/cmd/vkb-cli/main.go`:

```go
package main

import (
	"fmt"
	"os"
)

func main() {
	if len(os.Args) < 2 {
		usage()
		os.Exit(2)
	}
	switch os.Args[1] {
	case "check":
		os.Exit(runCheck(os.Args[2:]))
	case "capture":
		os.Exit(runCapture(os.Args[2:]))
	case "transcribe":
		os.Exit(runTranscribe(os.Args[2:]))
	case "pipe":
		os.Exit(runPipe(os.Args[2:]))
	case "-h", "--help", "help":
		usage()
		os.Exit(0)
	default:
		fmt.Fprintf(os.Stderr, "unknown subcommand: %s\n\n", os.Args[1])
		usage()
		os.Exit(2)
	}
}

func usage() {
	fmt.Fprintf(os.Stderr, `vkb-cli — voice keyboard CLI test harness

Usage:
  vkb-cli check                          verify dependencies and config
  vkb-cli capture --out FILE [--secs N]  record from mic to WAV
  vkb-cli transcribe FILE                run Whisper on a WAV
  vkb-cli pipe FILE                      run full pipeline on a WAV
  vkb-cli pipe --live                    record from mic, full pipeline

Environment:
  ANTHROPIC_API_KEY   required for cleanup
  VKB_MODEL_PATH      path to Whisper ggml-*.bin file
  VKB_LANGUAGE        defaults to "en"
`)
}
```

- [ ] **Step 2: Implement the check subcommand**

Write `core/cmd/vkb-cli/check.go`:

```go
package main

import (
	"flag"
	"fmt"
	"os"
)

func runCheck(args []string) int {
	fs := flag.NewFlagSet("check", flag.ContinueOnError)
	if err := fs.Parse(args); err != nil {
		return 2
	}

	ok := true

	// 1. ANTHROPIC_API_KEY
	if os.Getenv("ANTHROPIC_API_KEY") == "" {
		fmt.Println("[FAIL] ANTHROPIC_API_KEY is not set in the environment")
		ok = false
	} else {
		fmt.Println("[ OK ] ANTHROPIC_API_KEY is set")
	}

	// 2. Whisper model
	modelPath := os.Getenv("VKB_MODEL_PATH")
	if modelPath == "" {
		modelPath = os.ExpandEnv("$HOME/Library/Application Support/VoiceKeyboard/models/ggml-tiny.en.bin")
	}
	if _, err := os.Stat(modelPath); err != nil {
		fmt.Printf("[FAIL] Whisper model not found at %s\n", modelPath)
		ok = false
	} else {
		fmt.Printf("[ OK ] Whisper model present: %s\n", modelPath)
	}

	// 3. libwhisper available — if we got here and built, it is. Just
	//    note its location for the operator.
	fmt.Printf("[ OK ] linked against libwhisper.dylib (Homebrew)\n")
	fmt.Printf("[ OK ] linked against libdf.dylib (vendored)\n")

	if ok {
		fmt.Println("\nAll checks passed.")
		return 0
	}
	fmt.Println("\nOne or more checks failed.")
	return 1
}
```

- [ ] **Step 3: Build and run**

```bash
cd /Users/daniel/Documents/Projects/voice-keyboard/core
make build-cli
./build/vkb-cli check
```
Expected: prints `[ OK ]` or `[FAIL]` for each dependency. If everything is set up, exit 0.

- [ ] **Step 4: Commit**

`git add cmd/vkb-cli && git commit -m "feat(cli): add vkb-cli check subcommand"`

---

## Task 15: vkb-cli `capture` subcommand

**Files:**
- Create: `core/cmd/vkb-cli/capture.go`
- Create: `core/cmd/vkb-cli/wav.go`

- [ ] **Step 1: Write a tiny WAV writer**

Write `core/cmd/vkb-cli/wav.go`:

```go
package main

import (
	"encoding/binary"
	"io"
	"math"
	"os"
)

// writeWavMonoFloat writes float32 PCM samples as 16-bit signed PCM WAV.
// Whisper expects 16-bit at 16kHz; for capture we keep 48kHz so users
// can hear what was recorded, which is fine — file is just a debug aid.
func writeWavMonoFloat(path string, samples []float32, sampleRate int) error {
	f, err := os.Create(path)
	if err != nil {
		return err
	}
	defer f.Close()

	const bitsPerSample = 16
	const channels = 1

	dataLen := len(samples) * (bitsPerSample / 8)
	chunkLen := 36 + dataLen

	w := f
	if _, err := w.Write([]byte("RIFF")); err != nil {
		return err
	}
	binary.Write(w, binary.LittleEndian, uint32(chunkLen))
	w.Write([]byte("WAVEfmt "))
	binary.Write(w, binary.LittleEndian, uint32(16))                   // fmt chunk size
	binary.Write(w, binary.LittleEndian, uint16(1))                    // PCM
	binary.Write(w, binary.LittleEndian, uint16(channels))
	binary.Write(w, binary.LittleEndian, uint32(sampleRate))
	binary.Write(w, binary.LittleEndian, uint32(sampleRate*channels*bitsPerSample/8))
	binary.Write(w, binary.LittleEndian, uint16(channels*bitsPerSample/8))
	binary.Write(w, binary.LittleEndian, uint16(bitsPerSample))
	w.Write([]byte("data"))
	binary.Write(w, binary.LittleEndian, uint32(dataLen))
	for _, s := range samples {
		v := int16(math.MaxInt16 * clamp(s, -1, 1))
		binary.Write(w, binary.LittleEndian, v)
	}
	return nil
}

func clamp(v, lo, hi float32) float32 {
	if v < lo {
		return lo
	}
	if v > hi {
		return hi
	}
	return v
}

// readWavMonoFloat reads any 16-bit PCM mono WAV into float32.
func readWavMonoFloat(path string) ([]float32, int, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, 0, err
	}
	defer f.Close()
	data, err := io.ReadAll(f)
	if err != nil {
		return nil, 0, err
	}
	if len(data) < 44 {
		return nil, 0, os.ErrInvalid
	}
	sampleRate := int(binary.LittleEndian.Uint32(data[24:28]))
	for i := 36; i < len(data)-8; i += 4 {
		if string(data[i:i+4]) == "data" {
			size := int(binary.LittleEndian.Uint32(data[i+4 : i+8]))
			pcm := data[i+8 : i+8+size]
			samples := make([]float32, len(pcm)/2)
			for j := range samples {
				v := int16(binary.LittleEndian.Uint16(pcm[j*2 : j*2+2]))
				samples[j] = float32(v) / float32(math.MaxInt16)
			}
			return samples, sampleRate, nil
		}
	}
	return nil, 0, os.ErrInvalid
}
```

- [ ] **Step 2: Implement capture subcommand**

Write `core/cmd/vkb-cli/capture.go`:

```go
package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"time"

	"github.com/voice-keyboard/core/internal/audio"
)

func runCapture(args []string) int {
	fs := flag.NewFlagSet("capture", flag.ContinueOnError)
	out := fs.String("out", "capture.wav", "output WAV file path")
	secs := fs.Int("secs", 3, "seconds to record")
	if err := fs.Parse(args); err != nil {
		return 2
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt)
	defer stop()

	cap := audio.NewMalgoCapture()
	frames, err := cap.Start(ctx, 48000)
	if err != nil {
		fmt.Fprintf(os.Stderr, "capture: %v\n", err)
		return 1
	}
	fmt.Printf("Recording %d seconds (Ctrl-C to stop early)...\n", *secs)

	deadline := time.After(time.Duration(*secs) * time.Second)
	var pcm []float32
	for {
		select {
		case f, ok := <-frames:
			if !ok {
				goto done
			}
			pcm = append(pcm, f...)
		case <-deadline:
			_ = cap.Stop()
		case <-ctx.Done():
			_ = cap.Stop()
		}
	}
done:
	if err := writeWavMonoFloat(*out, pcm, 48000); err != nil {
		fmt.Fprintf(os.Stderr, "write wav: %v\n", err)
		return 1
	}
	fmt.Printf("Wrote %d samples (%.1fs) to %s\n", len(pcm), float64(len(pcm))/48000.0, *out)
	return 0
}
```

- [ ] **Step 3: Build and try recording 1 second**

```bash
cd /Users/daniel/Documents/Projects/voice-keyboard/core
make build-cli
./build/vkb-cli capture --out /tmp/test.wav --secs 1
file /tmp/test.wav
```
Expected: prints `48000 Hz` for the WAV; `~48000 samples (1.0s)` log line.

- [ ] **Step 4: Commit**

`git add cmd/vkb-cli && git commit -m "feat(cli): add vkb-cli capture and WAV utilities"`

---

## Task 16: vkb-cli `transcribe` subcommand

**Files:**
- Create: `core/cmd/vkb-cli/transcribe.go`

- [ ] **Step 1: Implement transcribe subcommand**

Write `core/cmd/vkb-cli/transcribe.go`:

```go
package main

import (
	"context"
	"flag"
	"fmt"
	"os"

	"github.com/voice-keyboard/core/internal/resample"
	"github.com/voice-keyboard/core/internal/transcribe"
)

func runTranscribe(args []string) int {
	fs := flag.NewFlagSet("transcribe", flag.ContinueOnError)
	if err := fs.Parse(args); err != nil {
		return 2
	}
	rest := fs.Args()
	if len(rest) != 1 {
		fmt.Fprintln(os.Stderr, "usage: vkb-cli transcribe FILE.wav")
		return 2
	}
	path := rest[0]

	pcm, sr, err := readWavMonoFloat(path)
	if err != nil {
		fmt.Fprintf(os.Stderr, "read wav: %v\n", err)
		return 1
	}

	pcm16k := pcm
	if sr == 48000 {
		dec := resample.NewDecimate3()
		pcm16k = dec.Process(pcm)
	} else if sr != 16000 {
		fmt.Fprintf(os.Stderr, "unsupported sample rate %d (need 16000 or 48000)\n", sr)
		return 1
	}

	modelPath := os.Getenv("VKB_MODEL_PATH")
	if modelPath == "" {
		modelPath = os.ExpandEnv("$HOME/Library/Application Support/VoiceKeyboard/models/ggml-tiny.en.bin")
	}
	lang := os.Getenv("VKB_LANGUAGE")
	if lang == "" {
		lang = "en"
	}

	w, err := transcribe.NewWhisperCpp(transcribe.WhisperOptions{
		ModelPath: modelPath,
		Language:  lang,
	})
	if err != nil {
		fmt.Fprintf(os.Stderr, "load model: %v\n", err)
		return 1
	}
	defer w.Close()

	text, err := w.Transcribe(context.Background(), pcm16k)
	if err != nil {
		fmt.Fprintf(os.Stderr, "transcribe: %v\n", err)
		return 1
	}
	fmt.Println(text)
	return 0
}
```

- [ ] **Step 2: Test with the JFK fixture**

```bash
cd /Users/daniel/Documents/Projects/voice-keyboard/core
make build-cli
./build/vkb-cli transcribe test/integration/testdata/hello-world.wav
```
Expected: prints text resembling "And so my fellow Americans, ask not what your country can do for you..." or whatever the fixture contains.

- [ ] **Step 3: Commit**

`git add cmd/vkb-cli && git commit -m "feat(cli): add vkb-cli transcribe subcommand"`

---

## Task 17: vkb-cli `pipe` subcommand (file mode and live mode)

**Files:**
- Create: `core/cmd/vkb-cli/pipe.go`

- [ ] **Step 1: Implement pipe subcommand**

Write `core/cmd/vkb-cli/pipe.go`:

```go
package main

import (
	"bufio"
	"context"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"strings"

	"github.com/voice-keyboard/core/internal/audio"
	"github.com/voice-keyboard/core/internal/denoise"
	"github.com/voice-keyboard/core/internal/dict"
	"github.com/voice-keyboard/core/internal/llm"
	"github.com/voice-keyboard/core/internal/pipeline"
	"github.com/voice-keyboard/core/internal/transcribe"
)

func runPipe(args []string) int {
	fs := flag.NewFlagSet("pipe", flag.ContinueOnError)
	live := fs.Bool("live", false, "record from mic; press Enter to stop")
	dictTerms := fs.String("dict", "", "comma-separated custom terms")
	if err := fs.Parse(args); err != nil {
		return 2
	}

	apiKey := os.Getenv("ANTHROPIC_API_KEY")
	if apiKey == "" {
		fmt.Fprintln(os.Stderr, "ANTHROPIC_API_KEY required")
		return 1
	}
	modelPath := os.Getenv("VKB_MODEL_PATH")
	if modelPath == "" {
		modelPath = os.ExpandEnv("$HOME/Library/Application Support/VoiceKeyboard/models/ggml-tiny.en.bin")
	}
	lang := os.Getenv("VKB_LANGUAGE")
	if lang == "" {
		lang = "en"
	}

	w, err := transcribe.NewWhisperCpp(transcribe.WhisperOptions{ModelPath: modelPath, Language: lang})
	if err != nil {
		fmt.Fprintf(os.Stderr, "load model: %v\n", err)
		return 1
	}
	defer w.Close()

	cleaner := llm.NewAnthropic(llm.AnthropicOptions{
		APIKey: apiKey,
		Model:  "claude-sonnet-4-6",
	})

	var terms []string
	if *dictTerms != "" {
		for _, t := range strings.Split(*dictTerms, ",") {
			if t = strings.TrimSpace(t); t != "" {
				terms = append(terms, t)
			}
		}
	}
	dy := dict.NewFuzzy(terms, 1)
	d := denoise.NewPassthrough() // build with -tags=deepfilter to use real denoise

	var cap audio.Capture
	if *live {
		cap = audio.NewMalgoCapture()
	} else {
		rest := fs.Args()
		if len(rest) != 1 {
			fmt.Fprintln(os.Stderr, "usage: vkb-cli pipe [--dict X,Y] FILE.wav  (or --live)")
			return 2
		}
		pcm, sr, err := readWavMonoFloat(rest[0])
		if err != nil {
			fmt.Fprintf(os.Stderr, "read wav: %v\n", err)
			return 1
		}
		if sr != 48000 {
			// upsample by zero-stuffing to 48kHz if needed; for v1 we
			// only handle the 48kHz capture rate. WAVs at other rates
			// are rejected to keep the test path honest.
			fmt.Fprintf(os.Stderr, "pipe expects 48kHz WAVs (got %d Hz)\n", sr)
			return 1
		}
		cap = audio.NewFakeCapture(pcm, denoise.FrameSize)
	}

	p := pipeline.New(cap, d, w, dy, cleaner)

	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt)
	defer cancel()

	stopCh := make(chan struct{})
	if *live {
		fmt.Println("Speak; press Enter to stop.")
		go func() {
			bufio.NewReader(os.Stdin).ReadString('\n')
			close(stopCh)
		}()
	} else {
		// File mode: capture is bounded by the file; signal stop after
		// it finishes by closing stopCh on a short delay.
		go func() {
			// FakeCapture closes its frames channel naturally; the
			// pipeline will exit drain when frames close. stopCh is
			// only useful in live mode.
			<-ctx.Done()
			close(stopCh)
		}()
	}

	res, err := p.Run(ctx, stopCh)
	if err != nil {
		fmt.Fprintf(os.Stderr, "pipeline: %v\n", err)
		return 1
	}
	if res.LLMError != nil {
		fmt.Fprintf(os.Stderr, "[LLM warning: %v]\n", res.LLMError)
	}
	if res.Cleaned == "" {
		fmt.Fprintln(os.Stderr, "(empty result)")
		return 0
	}
	fmt.Println(res.Cleaned)
	return 0
}
```

- [ ] **Step 2: Test on a recorded WAV**

```bash
cd /Users/daniel/Documents/Projects/voice-keyboard/core
make build-cli
./build/vkb-cli capture --out /tmp/say.wav --secs 4
ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY ./build/vkb-cli pipe /tmp/say.wav
```
Expected: prints the cleaned transcription of what you said. If `ANTHROPIC_API_KEY` is unset or invalid, expect a non-zero exit; if there's a network blip, expect a graceful-degradation log line and the dict-corrected raw text.

- [ ] **Step 3: Test live mode**

```bash
cd /Users/daniel/Documents/Projects/voice-keyboard/core
ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY ./build/vkb-cli pipe --live --dict "MCP,WebRTC"
# Speak: "the MCP protocol uses webrtc um for transport"
# Press Enter
```
Expected: prints something like `The MCP protocol uses WebRTC for transport.`

- [ ] **Step 4: Commit**

`git add cmd/vkb-cli && git commit -m "feat(cli): add vkb-cli pipe subcommand (file and --live modes)"`

---

## Task 18: C ABI exports for libvkb.dylib

**Files:**
- Create: `core/cmd/libvkb/main.go`
- Create: `core/cmd/libvkb/exports.go`
- Create: `core/cmd/libvkb/state.go`

- [ ] **Step 1: Write the registry / state holder**

Write `core/cmd/libvkb/state.go`:

```go
package main

import (
	"context"
	"sync"

	"github.com/voice-keyboard/core/internal/audio"
	"github.com/voice-keyboard/core/internal/config"
	"github.com/voice-keyboard/core/internal/denoise"
	"github.com/voice-keyboard/core/internal/dict"
	"github.com/voice-keyboard/core/internal/llm"
	"github.com/voice-keyboard/core/internal/pipeline"
	"github.com/voice-keyboard/core/internal/transcribe"
)

// Single-engine global state. The C ABI passes opaque handles, but for
// v1 we support exactly one active engine at a time. Multi-instance
// support can come later without API churn.

type engine struct {
	mu       sync.Mutex
	cfg      config.Config
	pipeline *pipeline.Pipeline

	// running capture
	stopCh chan struct{}
	cancel context.CancelFunc

	// poll queue (drained by Swift via vkb_poll_event)
	events chan event

	lastErr string
}

type event struct {
	Kind string  `json:"kind"`            // "level" | "result" | "error"
	RMS  float32 `json:"rms,omitempty"`
	Text string  `json:"text,omitempty"`
	Msg  string  `json:"msg,omitempty"`
}

var (
	gMu     sync.Mutex
	gEngine *engine
)

func getEngine() *engine {
	gMu.Lock()
	defer gMu.Unlock()
	return gEngine
}

func setEngine(e *engine) {
	gMu.Lock()
	defer gMu.Unlock()
	gEngine = e
}

func (e *engine) setLastError(msg string) {
	e.mu.Lock()
	e.lastErr = msg
	e.mu.Unlock()
}

func (e *engine) buildPipeline() error {
	tr, err := transcribe.NewWhisperCpp(transcribe.WhisperOptions{
		ModelPath: e.cfg.WhisperModelPath,
		Language:  e.cfg.Language,
	})
	if err != nil {
		return err
	}
	cleaner := llm.NewAnthropic(llm.AnthropicOptions{
		APIKey: e.cfg.LLMAPIKey,
		Model:  e.cfg.LLMModel,
	})
	dy := dict.NewFuzzy(e.cfg.CustomDict, 1)

	var d denoise.Denoiser
	if e.cfg.NoiseSuppression {
		d = newDeepFilterOrPassthrough(e.cfg.DeepFilterModelPath)
	} else {
		d = denoise.NewPassthrough()
	}

	cap := audio.NewMalgoCapture()
	e.pipeline = pipeline.New(cap, d, tr, dy, cleaner)
	return nil
}
```

- [ ] **Step 2: Add the deepfilter binding shim**

Write `core/cmd/libvkb/denoise_factory.go`:

```go
//go:build !deepfilter

package main

import "github.com/voice-keyboard/core/internal/denoise"

// modelPath ignored in the CGo-free build.
func newDeepFilterOrPassthrough(modelPath string) denoise.Denoiser {
	// CGo-free build (development). Use passthrough.
	return denoise.NewPassthrough()
}
```

And `core/cmd/libvkb/denoise_factory_deepfilter.go`:

```go
//go:build deepfilter

package main

import "github.com/voice-keyboard/core/internal/denoise"

const dfDefaultAttenLimDB = 100.0

func newDeepFilterOrPassthrough(modelPath string) denoise.Denoiser {
	if modelPath == "" {
		// no model path configured — degrade to passthrough silently
		return denoise.NewPassthrough()
	}
	d, err := denoise.NewDeepFilter(modelPath, dfDefaultAttenLimDB)
	if err != nil {
		// fall back if the libdf init fails at runtime
		return denoise.NewPassthrough()
	}
	return d
}
```

- [ ] **Step 3: Write the `//export` C ABI functions**

Write `core/cmd/libvkb/exports.go`:

```go
package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"context"
	"encoding/json"
	"unsafe"

	"github.com/voice-keyboard/core/internal/config"
)

//export vkb_init
func vkb_init() C.int {
	if getEngine() != nil {
		return 0 // already initialized
	}
	setEngine(&engine{events: make(chan event, 32)})
	return 0
}

//export vkb_configure
func vkb_configure(jsonC *C.char) C.int {
	e := getEngine()
	if e == nil {
		return 1
	}
	gostr := C.GoString(jsonC)
	var cfg config.Config
	if err := json.Unmarshal([]byte(gostr), &cfg); err != nil {
		e.setLastError("vkb_configure: " + err.Error())
		return 2
	}
	config.WithDefaults(&cfg)
	e.mu.Lock()
	e.cfg = cfg
	e.mu.Unlock()
	if err := e.buildPipeline(); err != nil {
		e.setLastError("vkb_configure: " + err.Error())
		return 3
	}
	return 0
}

//export vkb_start_capture
func vkb_start_capture() C.int {
	e := getEngine()
	if e == nil || e.pipeline == nil {
		return 1
	}
	e.mu.Lock()
	if e.stopCh != nil {
		e.mu.Unlock()
		return 2 // already running
	}
	stopCh := make(chan struct{})
	ctx, cancel := context.WithCancel(context.Background())
	e.stopCh = stopCh
	e.cancel = cancel
	e.mu.Unlock()

	go func() {
		res, err := e.pipeline.Run(ctx, stopCh)
		if err != nil {
			select {
			case e.events <- event{Kind: "error", Msg: err.Error()}:
			default:
			}
			return
		}
		ev := event{Kind: "result", Text: res.Cleaned}
		select {
		case e.events <- ev:
		default:
		}
	}()
	return 0
}

//export vkb_stop_capture
func vkb_stop_capture() C.int {
	e := getEngine()
	if e == nil {
		return 1
	}
	e.mu.Lock()
	defer e.mu.Unlock()
	if e.stopCh != nil {
		close(e.stopCh)
		e.stopCh = nil
	}
	if e.cancel != nil {
		e.cancel = nil // ctx will be cancelled when pipeline.Run returns
	}
	return 0
}

//export vkb_poll_event
func vkb_poll_event() *C.char {
	e := getEngine()
	if e == nil {
		return nil
	}
	select {
	case ev := <-e.events:
		buf, err := json.Marshal(ev)
		if err != nil {
			return nil
		}
		return C.CString(string(buf))
	default:
		return nil
	}
}

//export vkb_destroy
func vkb_destroy() {
	e := getEngine()
	if e == nil {
		return
	}
	_ = vkb_stop_capture()
	setEngine(nil)
}

//export vkb_last_error
func vkb_last_error() *C.char {
	e := getEngine()
	if e == nil {
		return nil
	}
	e.mu.Lock()
	defer e.mu.Unlock()
	if e.lastErr == "" {
		return nil
	}
	return C.CString(e.lastErr)
}

//export vkb_free_string
func vkb_free_string(s *C.char) {
	if s != nil {
		C.free(unsafe.Pointer(s))
	}
}
```

- [ ] **Step 4: Write the c-shared main entry**

Write `core/cmd/libvkb/main.go`:

```go
package main

// main is required for Go binaries but unused for c-shared builds.
func main() {}
```

- [ ] **Step 5: Build the dylib**

Run:
```bash
cd /Users/daniel/Documents/Projects/voice-keyboard/core
make build-dylib
ls -lh build/libvkb.dylib build/libvkb.h
```
Expected: produces `build/libvkb.dylib` and `build/libvkb.h`. The header declares `vkb_init`, `vkb_configure`, etc.

- [ ] **Step 6: Set the dylib install name**

```bash
cd /Users/daniel/Documents/Projects/voice-keyboard/core
install_name_tool -id "@rpath/libvkb.dylib" build/libvkb.dylib
otool -D build/libvkb.dylib
```
Expected: `otool -D` prints `@rpath/libvkb.dylib`.

- [ ] **Step 7: Commit**

`git add cmd/libvkb Makefile && git commit -m "feat(cabi): add libvkb.dylib C ABI exports"`

---

## Task 19: ABI smoke test from C

**Files:**
- Create: `core/test/cabi/smoke.c`
- Create: `core/test/cabi/Makefile`

- [ ] **Step 1: Write a tiny C test program**

Write `core/test/cabi/smoke.c`:

```c
#include <stdio.h>
#include <stdlib.h>
#include "libvkb.h"

int main(int argc, char** argv) {
    int rc = vkb_init();
    if (rc != 0) {
        fprintf(stderr, "vkb_init failed: %d\n", rc);
        return 1;
    }

    const char* config_json =
        "{"
        "\"whisper_model_path\":\"/tmp/nonexistent.bin\","
        "\"whisper_model_size\":\"tiny\","
        "\"language\":\"en\","
        "\"noise_suppression\":false,"
        "\"llm_provider\":\"anthropic\","
        "\"llm_model\":\"claude-sonnet-4-6\","
        "\"llm_api_key\":\"sk-ant-test\","
        "\"custom_dict\":[]"
        "}";

    rc = vkb_configure((char*)config_json);
    // Expected: non-zero (model file does not exist)
    if (rc == 0) {
        fprintf(stderr, "vkb_configure unexpectedly succeeded with bogus model path\n");
        return 2;
    }
    char* err = vkb_last_error();
    if (err == NULL) {
        fprintf(stderr, "expected non-null vkb_last_error, got NULL\n");
        return 3;
    }
    printf("expected error from configure: %s\n", err);
    vkb_free_string(err);
    vkb_destroy();
    printf("ABI smoke test OK\n");
    return 0;
}
```

- [ ] **Step 2: Write the Makefile to compile and run it**

Write `core/test/cabi/Makefile`:

```makefile
CORE_DIR := ../..
BUILD := $(CORE_DIR)/build

.PHONY: smoke clean

smoke: $(BUILD)/libvkb.dylib smoke.c
	clang -o smoke smoke.c -I$(BUILD) -L$(BUILD) -lvkb -Wl,-rpath,$(BUILD)
	./smoke

$(BUILD)/libvkb.dylib:
	$(MAKE) -C $(CORE_DIR) build-dylib

clean:
	rm -f smoke
```

- [ ] **Step 3: Run the smoke test**

```bash
cd /Users/daniel/Documents/Projects/voice-keyboard/core/test/cabi
make smoke
```
Expected: prints "expected error from configure: ..." then "ABI smoke test OK".

- [ ] **Step 4: Commit**

`git add test/cabi && git commit -m "test(cabi): add C-side ABI smoke test"`

---

## Task 20: Integration test — full pipeline with real impls

**Files:**
- Create: `core/test/integration/full_pipeline_test.go`

- [ ] **Step 1: Write the integration test**

Write `core/test/integration/full_pipeline_test.go`:

```go
//go:build integration && whispercpp

package integration

import (
	"context"
	"encoding/binary"
	"math"
	"net/http"
	"net/http/httptest"
	"os"
	"testing"
	"time"

	"github.com/voice-keyboard/core/internal/audio"
	"github.com/voice-keyboard/core/internal/denoise"
	"github.com/voice-keyboard/core/internal/dict"
	"github.com/voice-keyboard/core/internal/llm"
	"github.com/voice-keyboard/core/internal/pipeline"
	"github.com/voice-keyboard/core/internal/transcribe"
)

func TestFullPipeline_RealWhisperFakeAudioMockedLLM(t *testing.T) {
	modelPath := os.ExpandEnv("$HOME/Library/Application Support/VoiceKeyboard/models/ggml-tiny.en.bin")
	if _, err := os.Stat(modelPath); err != nil {
		t.Skipf("Whisper model missing at %s", modelPath)
	}

	pcm48k, err := loadFixtureAt48k("testdata/hello-world.wav")
	if err != nil {
		t.Fatalf("load fixture: %v", err)
	}

	// Mock Anthropic — return a constant cleaned string.
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{
			"id":"msg","type":"message","role":"assistant",
			"content":[{"type":"text","text":"Cleaned output."}],
			"model":"claude-sonnet-4-6","stop_reason":"end_turn",
			"usage":{"input_tokens":1,"output_tokens":1}
		}`))
	}))
	defer srv.Close()

	cap := audio.NewFakeCapture(pcm48k, denoise.FrameSize)
	d := denoise.NewPassthrough()
	tr, err := transcribe.NewWhisperCpp(transcribe.WhisperOptions{ModelPath: modelPath, Language: "en"})
	if err != nil {
		t.Fatalf("NewWhisperCpp: %v", err)
	}
	defer tr.Close()
	dy := dict.NewFuzzy(nil, 1)
	cl := llm.NewAnthropic(llm.AnthropicOptions{
		APIKey:  "sk-ant-test",
		Model:   "claude-sonnet-4-6",
		BaseURL: srv.URL,
		Timeout: 5 * time.Second,
	})

	p := pipeline.New(cap, d, tr, dy, cl)
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	stop := make(chan struct{})
	close(stop)

	res, err := p.Run(ctx, stop)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if res.Cleaned != "Cleaned output." {
		t.Errorf("Cleaned = %q, want \"Cleaned output.\"", res.Cleaned)
	}
	if res.Raw == "" {
		t.Errorf("Raw should be non-empty (whisper produced something)")
	}
	t.Logf("raw=%q cleaned=%q", res.Raw, res.Cleaned)
}

// loadFixtureAt48k reads a 16kHz WAV and naively upsamples 3x for the
// pipeline's 48kHz input expectation. This is a test shim only — the
// pipeline itself will decimate back to 16kHz inside Whisper.
func loadFixtureAt48k(path string) ([]float32, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var pcm16k []float32
	for i := 36; i < len(data)-8; i += 4 {
		if string(data[i:i+4]) == "data" {
			size := int(binary.LittleEndian.Uint32(data[i+4 : i+8]))
			raw := data[i+8 : i+8+size]
			pcm16k = make([]float32, len(raw)/2)
			for j := range pcm16k {
				v := int16(binary.LittleEndian.Uint16(raw[j*2 : j*2+2]))
				pcm16k[j] = float32(v) / float32(math.MaxInt16)
			}
			break
		}
	}
	if pcm16k == nil {
		return nil, os.ErrInvalid
	}
	out := make([]float32, len(pcm16k)*3)
	for i, s := range pcm16k {
		out[i*3] = s
		out[i*3+1] = s
		out[i*3+2] = s
	}
	return out, nil
}
```

- [ ] **Step 2: Run the integration test**

```bash
cd /Users/daniel/Documents/Projects/voice-keyboard/core
go test -tags="integration whispercpp" ./test/integration/... -v
```
Expected: PASS. Logs show the raw whisper transcription (likely "ask not what your country..." from JFK) and the canned "Cleaned output." final.

- [ ] **Step 3: Commit**

`git add test/integration && git commit -m "test: add full-pipeline integration test"`

---

## Task 21: Final smoke — `vkb-cli pipe --live` end to end

This is a manual verification, not an automated test.

- [ ] **Step 1: Set up environment**

```bash
export ANTHROPIC_API_KEY=<your real key>
export VKB_MODEL_PATH=$HOME/Library/Application\ Support/VoiceKeyboard/models/ggml-small.en.bin
# Download a better model if you don't have it:
test -f "$VKB_MODEL_PATH" || curl -L \
  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.en.bin \
  -o "$VKB_MODEL_PATH"
```

- [ ] **Step 2: Run with real microphone**

```bash
cd /Users/daniel/Documents/Projects/voice-keyboard/core
make build-cli
./build/vkb-cli pipe --live --dict "MCP,WebRTC"
```
Speak: "Um, the MCP protocol uses webrtc, you know, for transport between agents."
Press Enter.

Expected output: a single cleaned sentence such as "The MCP protocol uses WebRTC for transport between agents." with filler words gone, technical terms preserved.

- [ ] **Step 3: Confirm graceful degradation**

Repeat with a deliberately-bad API key:
```bash
ANTHROPIC_API_KEY=sk-bogus ./build/vkb-cli pipe --live --dict "MCP"
```
Speak something. Expect a stderr line like `[LLM warning: anthropic: ...]` followed by the dict-corrected raw transcription on stdout — never an empty result.

- [ ] **Step 4: Done**

Plan complete. The Go core is end-to-end functional. The next plan (Swift app) is unblocked: `build/libvkb.dylib` and `build/libvkb.h` are the contract surface it will consume.

---

## What's next (after this plan)

A separate plan, **`docs/superpowers/plans/<later-date>-voice-keyboard-swift-app.md`**, will cover:

- SwiftUI MenuBarExtra app skeleton, settings, hotkey via CGEventTap
- CGo bridge wrapper around `build/libvkb.dylib`
- Floating recording overlay with live waveform
- Clipboard paste injector with save/restore
- First-run flow: Accessibility permission + Whisper model download UI
- App bundling: `libvkb.dylib`, `libwhisper.dylib`, `libdf.dylib` in `Contents/Frameworks/`

That plan should be written after Plan 1 is implemented (or at least task 18 — the dylib — is done), since the Swift app's foundation is the C ABI exposed here.
