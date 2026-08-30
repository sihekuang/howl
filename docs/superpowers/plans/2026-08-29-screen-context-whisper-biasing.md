# Screen Context → Whisper Biasing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Read the focused window's text on window-focus change, extract keywords with the active LLM provider, and feed them into Whisper's `initial_prompt` alongside the custom dictionary — without ever exceeding Whisper's real 224-token prompt window.

**Architecture:** Swift reads the focused window (Accessibility API first, Vision OCR fallback) and debounces/caches; Go owns keyword extraction, prompt composition, and the token budget. Two new C-ABI exports keep the network call (`howl_extract_keywords`) separate from the instant state write (`howl_set_screen_keywords`), so a cache hit costs no network. The composed prompt is trimmed against the loaded model's actual vocabulary via `whisper_token_count`.

**Tech Stack:** Go 1.x with cgo (`whispercpp` build tag), whisper.cpp, Swift 6 (strict concurrency), SwiftUI + AppKit, swift-testing, XcodeGen, ScreenCaptureKit, Vision.

**Spec:** `docs/superpowers/specs/2026-08-29-screen-context-whisper-biasing-design.md`

## Global Constraints

- **Total prompt bound:** `transcribe.MaxInitialPromptLen = 896` bytes (unchanged) as a byte pre-filter; the authoritative bound is **224 tokens**, measured with `whisper_token_count`.
- **Screen sub-caps:** `MaxScreenPromptLen = 384` bytes (loose pre-filter), `MaxScreenPromptTokens = 96` (authoritative), `MaxKeywords = 24`, `MaxKeywordBytes = 40`.
- **Ordering is load-bearing:** dictionary terms always compose first; every truncation path drops from the tail so screen keywords are sacrificed before dictionary terms.
- **Window text cap:** 8192 bytes before it reaches any provider.
- **Timings:** 800 ms focus-dwell debounce; 5 s extraction timeout; cache 32 entries / 10-minute TTL.
- **Scope:** the LLM cleanup stage is NOT modified. No changes to `llm.DefaultPrompt`, `Pipeline.Clean`, or cleanup behaviour.
- **Failure policy:** every failure degrades silently to dictionary-only dictation. PTT never blocks on extraction.
- **Privacy:** raw window text is never logged and never written to session manifests; only the final keyword list is.
- **Build tags:** pure-Go files and their tests carry NO build tag. Anything touching cgo carries `//go:build whispercpp`.
- **Go tests:** `cd core && make test-unit` (or `go test ./internal/...`).
- **Swift tests:** `cd mac/Packages/HowlCore && swift test`.
- **Branch:** `feat/screen-context-whisper-biasing`.

**Verified before writing this plan** (do not re-litigate):
- `whisper_token_count(struct whisper_context*, const char*)` is declared in `/opt/homebrew/opt/whisper-cpp/include/whisper.h:355` and exported from `libwhisper.dylib` (`nm -gU` → `T _whisper_token_count`).
- `pipeline/build.nonClosingTranscriber` embeds `transcribe.Transcriber`, so it forwards ONLY interface methods. It must explicitly forward `SetContextPrompt` or the type assertion silently fails for shared transcribers (Task 2, Step 7).

---

### Task 1: `ContextPrompt` — pure prompt composition

Composes dictionary + screen terms with dictionary-first ordering, case-insensitive dedupe, and byte pre-filters. Pure Go, no cgo, so it is fully unit-testable without a model.

**Files:**
- Modify: `core/internal/transcribe/prompt.go`
- Test: `core/internal/transcribe/prompt_test.go`

**Interfaces:**
- Consumes: existing `boundInitialPrompt`, `MaxInitialPromptLen`.
- Produces:
  - `transcribe.MaxScreenPromptLen = 384`
  - `transcribe.MaxScreenPromptTokens = 96`
  - `transcribe.ContextPrompt(dictTerms, screenTerms []string) (string, []string)`
  - `transcribe.cleanTerms(terms []string) []string` (package-private)

- [ ] **Step 1: Write the failing tests**

Add `"fmt"` to `prompt_test.go`'s import block (it currently imports `strings`, `testing`, `unicode/utf8`), then append:

```go
func TestContextPrompt_DictionaryComesFirst(t *testing.T) {
	got, screen := ContextPrompt([]string{"MCP", "WebRTC"}, []string{"SpeakerGate"})
	want := "MCP, WebRTC, SpeakerGate"
	if got != want {
		t.Errorf("ContextPrompt() = %q, want %q", got, want)
	}
	if len(screen) != 1 || screen[0] != "SpeakerGate" {
		t.Errorf("surviving screen terms = %v, want [SpeakerGate]", screen)
	}
}

func TestContextPrompt_DedupesScreenAgainstDictionary(t *testing.T) {
	got, screen := ContextPrompt([]string{"WebRTC"}, []string{"webrtc", "SpeakerGate", "WEBRTC"})
	want := "WebRTC, SpeakerGate"
	if got != want {
		t.Errorf("ContextPrompt() = %q, want %q", got, want)
	}
	if len(screen) != 1 || screen[0] != "SpeakerGate" {
		t.Errorf("surviving screen terms = %v, want [SpeakerGate]", screen)
	}
}

func TestContextPrompt_DedupesWithinScreenTerms(t *testing.T) {
	got, _ := ContextPrompt(nil, []string{"Howl", "howl", "HOWL"})
	if got != "Howl" {
		t.Errorf("ContextPrompt() = %q, want %q", got, "Howl")
	}
}

func TestContextPrompt_SkipsEmptyAndWhitespaceTerms(t *testing.T) {
	got, _ := ContextPrompt([]string{"  MCP  ", "", "   "}, []string{"\tSpeakerGate\n", ""})
	if got != "MCP, SpeakerGate" {
		t.Errorf("ContextPrompt() = %q, want %q", got, "MCP, SpeakerGate")
	}
}

func TestContextPrompt_ScreenTermsBoundedByScreenSubCap(t *testing.T) {
	// 30 x 20-byte terms = 22*30-2 = 658 bytes joined, well over the 384 cap.
	// Largest k with 22k-2 <= 384 is 17 (372 bytes).
	screenIn := make([]string, 30)
	for i := range screenIn {
		screenIn[i] = fmt.Sprintf("term%016d", i) // exactly 20 bytes, unique
	}
	_, screen := ContextPrompt(nil, screenIn)
	if len(screen) != 17 {
		t.Errorf("surviving screen terms = %d, want 17 (screen sub-cap)", len(screen))
	}
}

func TestContextPrompt_TotalBoundEvictsScreenTermsNotDictionary(t *testing.T) {
	// Dictionary alone fills nearly the whole 896-byte budget.
	dict := []string{strings.Repeat("d", MaxInitialPromptLen-10)}
	got, screen := ContextPrompt(dict, []string{"SpeakerGate", "DeepFilterNet"})
	if len(got) > MaxInitialPromptLen {
		t.Fatalf("prompt len %d exceeds %d", len(got), MaxInitialPromptLen)
	}
	if !strings.HasPrefix(got, dict[0]) {
		t.Error("dictionary term was truncated; screen terms must be evicted first")
	}
	if len(screen) != 0 {
		t.Errorf("surviving screen terms = %v, want none", screen)
	}
}

func TestContextPrompt_EmptyInputsYieldEmptyPrompt(t *testing.T) {
	got, screen := ContextPrompt(nil, nil)
	if got != "" {
		t.Errorf("ContextPrompt(nil, nil) = %q, want empty", got)
	}
	if len(screen) != 0 {
		t.Errorf("surviving screen terms = %v, want none", screen)
	}
}

func TestContextPrompt_ScreenOnlyIsAllowed(t *testing.T) {
	got, screen := ContextPrompt(nil, []string{"SpeakerGate"})
	if got != "SpeakerGate" {
		t.Errorf("ContextPrompt() = %q, want %q", got, "SpeakerGate")
	}
	if len(screen) != 1 {
		t.Errorf("surviving screen terms = %v, want 1", screen)
	}
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd core && go test ./internal/transcribe/ -run TestContextPrompt`
Expected: compile FAILURE — `undefined: ContextPrompt`.

- [ ] **Step 3: Write the implementation**

In `core/internal/transcribe/prompt.go`, add after `MaxInitialPromptLen`:

```go
// MaxScreenPromptLen is a loose byte pre-filter on the screen-derived
// portion of the prompt, applied where no whisper context is available
// (composition, tests, howl-cli). The authoritative bound is
// MaxScreenPromptTokens, enforced in WhisperCpp.SetContextPrompt.
const MaxScreenPromptLen = 384

// MaxScreenPromptTokens caps the screen-derived portion of whisper's
// 224-token prompt window, leaving the majority for the custom
// dictionary. Deliberately conservative: an oversized initial_prompt is
// a documented cause of hallucinated words in the transcript.
const MaxScreenPromptTokens = 96
```

Add at the end of the file:

```go
// cleanTerms trims each term and drops empty entries, preserving order.
func cleanTerms(terms []string) []string {
	out := make([]string, 0, len(terms))
	for _, t := range terms {
		if t = strings.TrimSpace(t); t != "" {
			out = append(out, t)
		}
	}
	return out
}

// ContextPrompt composes a whisper initial prompt from the user's custom
// dictionary and keywords derived from the focused window.
//
// Dictionary terms are emitted first and screen terms second, because
// every truncation path in this package drops from the tail — so an
// oversized prompt sacrifices screen keywords and never the dictionary
// the user explicitly configured.
//
// Screen terms are deduped case-insensitively against the dictionary
// (and against each other) and bounded to MaxScreenPromptLen; the whole
// result is bounded to MaxInitialPromptLen.
//
// Returns the prompt plus the screen terms that actually survived
// truncation — the latter is what callers record in the session
// manifest, so the manifest reflects what whisper saw rather than what
// was offered.
func ContextPrompt(dictTerms, screenTerms []string) (string, []string) {
	dict := cleanTerms(dictTerms)
	screen := cleanTerms(screenTerms)

	seen := make(map[string]struct{}, len(dict)+len(screen))
	for _, t := range dict {
		seen[strings.ToLower(t)] = struct{}{}
	}

	// Screen terms: dedupe, then fill up to the screen sub-cap.
	kept := make([]string, 0, len(screen))
	used := 0
	for _, t := range screen {
		key := strings.ToLower(t)
		if _, dup := seen[key]; dup {
			continue
		}
		add := len(t)
		if len(kept) > 0 {
			add += 2 // ", " separator
		}
		if used+add > MaxScreenPromptLen {
			break
		}
		seen[key] = struct{}{}
		used += add
		kept = append(kept, t)
	}

	all := make([]string, 0, len(dict)+len(kept))
	all = append(all, dict...)
	all = append(all, kept...)
	if len(all) == 0 {
		return "", nil
	}

	prompt := boundInitialPrompt(strings.Join(all, ", "))

	// Re-derive which screen terms survived the overall byte bound by
	// walking the same join the bound was applied to.
	surviving := make([]string, 0, len(kept))
	running := 0
	for i, t := range all {
		add := len(t)
		if i > 0 {
			add += 2
		}
		if running+add > len(prompt) {
			break
		}
		running += add
		if i >= len(dict) {
			surviving = append(surviving, t)
		}
	}
	return prompt, surviving
}
```

Then simplify `DictionaryPrompt` to reuse the shared helper (behaviour is identical):

```go
func DictionaryPrompt(terms []string) string {
	cleaned := cleanTerms(terms)
	if len(cleaned) == 0 {
		return ""
	}
	return boundInitialPrompt(strings.Join(cleaned, ", "))
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd core && go test ./internal/transcribe/`
Expected: PASS, including the pre-existing `TestBoundInitialPrompt*` and `TestDictionaryPrompt*` tests.

- [ ] **Step 5: Commit**

```bash
git add core/internal/transcribe/prompt.go core/internal/transcribe/prompt_test.go
git commit -m "feat(transcribe): compose whisper prompt from dictionary + screen keywords

Dictionary terms compose first so tail truncation sacrifices screen
keywords, never the dictionary the user configured."
```

---

### Task 2: `SetContextPrompt` — exact token trimming against the model vocab

This is the task the whole design exists for. The 896-byte bound assumes ~4 bytes/token, which is wrong for jargon (~1.5–3 bytes/token). Whisper keeps only the LAST 224 tokens, so a byte-legal prompt can silently lose its head — the dictionary.

**Files:**
- Create: `core/internal/transcribe/promptsetter.go` (NO build tag — `pipeline` and `libhowl` assert against it)
- Modify: `core/internal/transcribe/whisper_cpp.go`
- Modify: `core/internal/pipeline/build/build.go`
- Test: `core/internal/transcribe/whisper_cpp_test.go`

**Interfaces:**
- Consumes: `ContextPrompt`, `cleanTerms`, `MaxScreenPromptTokens` (Task 1).
- Produces:
  - `transcribe.MaxPromptTokens = 224`
  - `transcribe.PromptSetter` interface with `SetContextPrompt(dictTerms, screenTerms []string)`
  - `(*WhisperCpp).SetContextPrompt(dictTerms, screenTerms []string)`
  - `(*WhisperCpp).tokenCount(text string) int` (package-private)

- [ ] **Step 1: Create the untagged interface file**

Create `core/internal/transcribe/promptsetter.go`:

```go
package transcribe

// MaxPromptTokens is whisper's real initial-prompt window
// (n_text_ctx/2). Whisper silently keeps only the LAST MaxPromptTokens
// tokens of a longer prompt, so exceeding it does not error — it
// quietly discards the head of the prompt.
const MaxPromptTokens = 224

// PromptSetter is an optional Transcriber extension for backends that
// can re-bias per capture. Detected via type assertion, mirroring the
// StreamingCleaner pattern in the llm package, so Transcriber
// implementations that don't support it (test fakes, future backends)
// need no changes.
type PromptSetter interface {
	// SetContextPrompt recomposes the initial prompt from the custom
	// dictionary and screen-derived keywords, trimming to whisper's
	// real token window. Must not be called while a Transcribe is in
	// flight on the same instance.
	SetContextPrompt(dictTerms, screenTerms []string)
}
```

- [ ] **Step 2: Write the failing test**

Append to `core/internal/transcribe/whisper_cpp_test.go`:

```go
// TestWhisperCpp_SetContextPrompt_TrimsToRealTokenWindow is the
// regression test for the reason this feature needed a token-based
// bound. Dense jargon tokenizes at ~1.5-3 bytes/token, so a prompt that
// passes the 896-byte pre-filter can still exceed whisper's 224-token
// window — where whisper would silently drop the HEAD, i.e. the user's
// dictionary.
func TestWhisperCpp_SetContextPrompt_TrimsToRealTokenWindow(t *testing.T) {
	modelPath := os.ExpandEnv("$HOME/Library/Application Support/Howl/models/ggml-tiny.en.bin")
	if _, err := os.Stat(modelPath); err != nil {
		t.Skipf("model not available at %s", modelPath)
	}
	w, err := NewWhisperCpp(WhisperOptions{ModelPath: modelPath, Language: "en"})
	if err != nil {
		t.Fatalf("NewWhisperCpp: %v", err)
	}
	defer w.Close()

	// 60 dense CamelCase identifiers: byte-legal, token-illegal.
	screen := make([]string, 60)
	for i := range screen {
		screen[i] = fmt.Sprintf("XqzGlyphWarpNode%02d", i)
	}
	dict := []string{"MCP", "WebRTC", "DeepFilterNet"}

	w.SetContextPrompt(dict, screen)
	got := w.initialPrompt

	if n := w.tokenCount(got); n > MaxPromptTokens {
		t.Errorf("prompt is %d tokens, want <= %d", n, MaxPromptTokens)
	}
	for _, term := range dict {
		if !strings.Contains(got, term) {
			t.Errorf("dictionary term %q was evicted; screen keywords must be dropped first", term)
		}
	}
}

func TestWhisperCpp_SetContextPrompt_ScreenSubCapInTokens(t *testing.T) {
	modelPath := os.ExpandEnv("$HOME/Library/Application Support/Howl/models/ggml-tiny.en.bin")
	if _, err := os.Stat(modelPath); err != nil {
		t.Skipf("model not available at %s", modelPath)
	}
	w, err := NewWhisperCpp(WhisperOptions{ModelPath: modelPath, Language: "en"})
	if err != nil {
		t.Fatalf("NewWhisperCpp: %v", err)
	}
	defer w.Close()

	screen := make([]string, 40)
	for i := range screen {
		screen[i] = fmt.Sprintf("ZzyxKernBlob%02d", i)
	}
	w.SetContextPrompt(nil, screen)

	if n := w.tokenCount(w.initialPrompt); n > MaxScreenPromptTokens {
		t.Errorf("screen-only prompt is %d tokens, want <= %d", n, MaxScreenPromptTokens)
	}
}

func TestWhisperCpp_SetContextPrompt_EmptyClearsPrompt(t *testing.T) {
	modelPath := os.ExpandEnv("$HOME/Library/Application Support/Howl/models/ggml-tiny.en.bin")
	if _, err := os.Stat(modelPath); err != nil {
		t.Skipf("model not available at %s", modelPath)
	}
	w, err := NewWhisperCpp(WhisperOptions{ModelPath: modelPath, Language: "en"})
	if err != nil {
		t.Fatalf("NewWhisperCpp: %v", err)
	}
	defer w.Close()

	w.SetContextPrompt([]string{"MCP"}, nil)
	w.SetContextPrompt(nil, nil)
	if w.initialPrompt != "" {
		t.Errorf("initialPrompt = %q, want empty after clearing", w.initialPrompt)
	}
}
```

Add `"fmt"` to that file's import block.

- [ ] **Step 3: Run test to verify it fails**

Run: `cd core && go test -tags="whispercpp" ./internal/transcribe/ -run SetContextPrompt`
Expected: compile FAILURE — `w.SetContextPrompt undefined` and `w.tokenCount undefined`.

(If it SKIPS instead, download the model first:
`curl -L --create-dirs -o "$HOME/Library/Application Support/Howl/models/ggml-tiny.en.bin" https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny.en.bin`)

- [ ] **Step 4: Write the implementation**

In `core/internal/transcribe/whisper_cpp.go`, add `whisper_token_count` to the cgo preamble helpers — it is already declared in `whisper.h`, so no C shim is needed.

Add a mutex to the struct:

```go
type WhisperCpp struct {
	ctx           *C.struct_whisper_context
	lang          string
	threads       int

	// mu guards initialPrompt, which SetContextPrompt rewrites between
	// captures while Transcribe reads it.
	mu            sync.Mutex
	initialPrompt string
}
```

Add the methods:

```go
// tokenCount returns how many whisper tokens text occupies in THIS
// model's vocabulary. Byte-length heuristics are not a substitute:
// jargon and CamelCase identifiers tokenize far denser than prose.
func (w *WhisperCpp) tokenCount(text string) int {
	if text == "" || w.ctx == nil {
		return 0
	}
	cText := C.CString(text)
	defer C.free(unsafe.Pointer(cText))
	return int(C.whisper_token_count(w.ctx, cText))
}

// SetContextPrompt recomposes the initial prompt from the custom
// dictionary and screen-derived keywords, then trims it to whisper's
// real token window by dropping whole terms from the tail.
//
// Two stages, both dropping from the tail so screen keywords are always
// sacrificed before dictionary terms:
//  1. screen keywords alone must fit MaxScreenPromptTokens
//  2. the whole prompt must fit MaxPromptTokens
//
// Must not be called while Transcribe is running on this instance; the
// engine calls it from howl_start_capture, where no capture is in flight.
func (w *WhisperCpp) SetContextPrompt(dictTerms, screenTerms []string) {
	_, screen := ContextPrompt(dictTerms, screenTerms)
	dict := cleanTerms(dictTerms)

	for len(screen) > 0 && w.tokenCount(strings.Join(screen, ", ")) > MaxScreenPromptTokens {
		screen = screen[:len(screen)-1]
	}

	all := make([]string, 0, len(dict)+len(screen))
	all = append(all, dict...)
	all = append(all, screen...)
	for len(all) > 0 && w.tokenCount(strings.Join(all, ", ")) > MaxPromptTokens {
		all = all[:len(all)-1]
	}

	w.mu.Lock()
	w.initialPrompt = strings.Join(all, ", ")
	w.mu.Unlock()
}
```

Compile-time assertion, next to the existing `var _ Transcriber = (*WhisperCpp)(nil)`:

```go
var _ PromptSetter = (*WhisperCpp)(nil)
```

- [ ] **Step 5: Make `Transcribe` read the prompt under the lock**

In `Transcribe`, replace the direct `w.initialPrompt` read:

```go
	// Optional custom-vocabulary prompt. Left nil (whisper's default)
	// when no prompt was configured.
	w.mu.Lock()
	prompt := w.initialPrompt
	w.mu.Unlock()
	if prompt != "" {
		cPrompt := C.CString(prompt)
		defer C.free(unsafe.Pointer(cPrompt))
		params.initial_prompt = cPrompt
	}
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `cd core && go test -tags="whispercpp" ./internal/transcribe/`
Expected: PASS.

- [ ] **Step 7: Forward `SetContextPrompt` through `nonClosingTranscriber`**

`nonClosingTranscriber` embeds the `Transcriber` interface, so it forwards ONLY interface methods — a type assertion for `PromptSetter` against the wrapper would silently fail, and shared transcribers (replay/Compare) would never get screen keywords.

In `core/internal/pipeline/build/build.go`, below the existing `Close`:

```go
// SetContextPrompt forwards to the wrapped transcriber when it supports
// re-biasing. Without this the embedded interface hides the method and
// the PromptSetter assertion in libhowl silently no-ops for shared
// transcribers.
func (n nonClosingTranscriber) SetContextPrompt(dictTerms, screenTerms []string) {
	if ps, ok := n.Transcriber.(transcribe.PromptSetter); ok {
		ps.SetContextPrompt(dictTerms, screenTerms)
	}
}
```

- [ ] **Step 8: Verify the whole core still builds and tests**

Run: `cd core && make build-dylib && make test-unit`
Expected: dylib builds; all unit tests PASS.

- [ ] **Step 9: Commit**

```bash
git add core/internal/transcribe/promptsetter.go \
        core/internal/transcribe/whisper_cpp.go \
        core/internal/transcribe/whisper_cpp_test.go \
        core/internal/pipeline/build/build.go
git commit -m "feat(transcribe): trim initial prompt to whisper's real 224-token window

The 896-byte bound assumes ~4 bytes/token, which holds for prose but not
for jargon (~1.5-3). A byte-legal prompt can reach 300-450 tokens, and
whisper silently keeps only the last 224 -- dropping the dictionary at
the head. Measure with whisper_token_count instead."
```

---

### Task 3: `screenctx.Sanitize` — bound and clean the LLM's response

Pure, no network, no cgo. LLM output is untrusted text: it arrives with bullets, numbering, quotes, prose, and duplicates.

**Files:**
- Create: `core/internal/screenctx/sanitize.go`
- Test: `core/internal/screenctx/sanitize_test.go`

**Interfaces:**
- Consumes: nothing (leaf).
- Produces: `screenctx.MaxKeywords = 24`, `screenctx.MaxKeywordBytes = 40`, `screenctx.Sanitize(raw string) []string`

- [ ] **Step 1: Write the failing tests**

Create `core/internal/screenctx/sanitize_test.go`:

```go
package screenctx

import (
	"strings"
	"testing"
)

func TestSanitize(t *testing.T) {
	tests := []struct {
		name string
		in   string
		want []string
	}{
		{"empty", "", nil},
		{"whitespace only", "   \n\t ", nil},
		{"plain comma list", "MCP, WebRTC, SpeakerGate", []string{"MCP", "WebRTC", "SpeakerGate"}},
		{"newline separated", "MCP\nWebRTC\nSpeakerGate", []string{"MCP", "WebRTC", "SpeakerGate"}},
		{"semicolon separated", "MCP; WebRTC", []string{"MCP", "WebRTC"}},
		{"strips dash bullets", "- MCP\n- WebRTC", []string{"MCP", "WebRTC"}},
		{"strips asterisk bullets", "* MCP\n* WebRTC", []string{"MCP", "WebRTC"}},
		{"strips unicode bullets", "• MCP\n• WebRTC", []string{"MCP", "WebRTC"}},
		{"strips numbering", "1. MCP\n2) WebRTC", []string{"MCP", "WebRTC"}},
		{"strips double quotes", `"MCP", "WebRTC"`, []string{"MCP", "WebRTC"}},
		{"strips single quotes", "'MCP', 'WebRTC'", []string{"MCP", "WebRTC"}},
		{"strips backticks", "`MCP`, `WebRTC`", []string{"MCP", "WebRTC"}},
		{"dedupes case-insensitively keeping first", "MCP, mcp, MCp", []string{"MCP"}},
		{"drops numeric-only tokens", "MCP, 12345, 3.14, WebRTC", []string{"MCP", "WebRTC"}},
		{"keeps alphanumeric mixes", "MCP, ggml-tiny, v0.10.2rc", []string{"MCP", "ggml-tiny", "v0.10.2rc"}},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got := Sanitize(tc.in)
			if len(got) != len(tc.want) {
				t.Fatalf("Sanitize(%q) = %v, want %v", tc.in, got, tc.want)
			}
			for i := range got {
				if got[i] != tc.want[i] {
					t.Errorf("Sanitize(%q)[%d] = %q, want %q", tc.in, i, got[i], tc.want[i])
				}
			}
		})
	}
}

func TestSanitize_DropsOverLongTokens(t *testing.T) {
	long := strings.Repeat("a", MaxKeywordBytes+1)
	got := Sanitize("MCP, " + long + ", WebRTC")
	if len(got) != 2 || got[0] != "MCP" || got[1] != "WebRTC" {
		t.Errorf("Sanitize() = %v, want [MCP WebRTC]", got)
	}
}

func TestSanitize_KeepsTokenExactlyAtMaxLength(t *testing.T) {
	exact := strings.Repeat("a", MaxKeywordBytes)
	got := Sanitize(exact)
	if len(got) != 1 || got[0] != exact {
		t.Errorf("Sanitize() dropped a token of exactly MaxKeywordBytes")
	}
}

func TestSanitize_CapsAtMaxKeywords(t *testing.T) {
	parts := make([]string, MaxKeywords+10)
	for i := range parts {
		parts[i] = "Term" + string(rune('A'+i%26)) + string(rune('a'+i/26))
	}
	got := Sanitize(strings.Join(parts, ", "))
	if len(got) != MaxKeywords {
		t.Errorf("Sanitize() returned %d terms, want cap of %d", len(got), MaxKeywords)
	}
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd core && go test ./internal/screenctx/`
Expected: FAILURE — no such package / `undefined: Sanitize`.

- [ ] **Step 3: Write the implementation**

Create `core/internal/screenctx/sanitize.go`:

```go
// Package screenctx turns the text of the user's focused window into a
// short keyword list that biases whisper's initial prompt. It does NOT
// participate in LLM cleanup — its only consumer is the ASR prompt.
package screenctx

import (
	"regexp"
	"strings"
	"unicode"
)

const (
	// MaxKeywords caps how many terms reach the prompt. Whisper's
	// prompt window is tiny and oversized prompts induce hallucination,
	// so this is deliberately conservative.
	MaxKeywords = 24

	// MaxKeywordBytes drops tokens too long to be a real term — the LLM
	// occasionally returns a sentence fragment despite instructions.
	MaxKeywordBytes = 40
)

// listPrefix matches leading bullet or numbering markup ("- ", "* ",
// "• ", "1. ", "2) ") that models add despite being told not to.
var listPrefix = regexp.MustCompile(`^\s*(?:[-*•]|\d+[.)])\s*`)

// Sanitize turns a raw LLM response into a bounded, deduped keyword
// list. Input is untrusted model output, so every assumption about
// format is enforced rather than trusted.
func Sanitize(raw string) []string {
	fields := strings.FieldsFunc(raw, func(r rune) bool {
		return r == '\n' || r == '\r' || r == ',' || r == ';'
	})

	out := make([]string, 0, len(fields))
	seen := make(map[string]struct{}, len(fields))
	for _, f := range fields {
		t := listPrefix.ReplaceAllString(f, "")
		t = strings.TrimSpace(t)
		t = strings.Trim(t, "\"'`")
		t = strings.TrimSpace(t)

		if t == "" || len(t) > MaxKeywordBytes || isNumeric(t) {
			continue
		}
		key := strings.ToLower(t)
		if _, dup := seen[key]; dup {
			continue
		}
		seen[key] = struct{}{}
		out = append(out, t)
		if len(out) == MaxKeywords {
			break
		}
	}
	if len(out) == 0 {
		return nil
	}
	return out
}

// isNumeric reports whether s is only digits and numeric punctuation.
// Bare numbers are worthless as recognition hints.
func isNumeric(s string) bool {
	for _, r := range s {
		if !unicode.IsDigit(r) && r != '.' && r != ',' && r != '-' && r != '+' {
			return false
		}
	}
	return true
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd core && go test ./internal/screenctx/ -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add core/internal/screenctx/
git commit -m "feat(screenctx): sanitize LLM keyword output into a bounded list"
```

---

### Task 4: `screenctx.Extract` — LLM-backed keyword extraction

Reuses the existing `llm.Cleaner` machinery with an overridden prompt template. This is why no new provider plumbing is needed: all four providers, their HTTP clients, and key handling come for free.

**Files:**
- Create: `core/internal/screenctx/extract.go`
- Test: `core/internal/screenctx/extract_test.go`

**Interfaces:**
- Consumes: `screenctx.Sanitize` (Task 3), `llm.Cleaner`, `llm.ProviderByName`, `llm.Options`, `config.Config`.
- Produces:
  - `screenctx.MaxWindowTextBytes = 8192`
  - `screenctx.ExtractTimeout = 5 * time.Second`
  - `screenctx.ExtractPrompt` (string const)
  - `screenctx.Extract(ctx context.Context, cleaner llm.Cleaner, windowText string, dictTerms []string) ([]string, error)`
  - `screenctx.NewExtractor(cfg config.Config) (llm.Cleaner, error)`

- [ ] **Step 1: Write the failing tests**

Create `core/internal/screenctx/extract_test.go`:

```go
package screenctx

import (
	"context"
	"errors"
	"strings"
	"testing"
	"unicode/utf8"

	"github.com/voice-keyboard/core/internal/config"
)

// fakeCleaner records what it was asked to clean and returns a canned
// response, mirroring the fakeCleaner pattern in internal/pipeline.
type fakeCleaner struct {
	out      string
	err      error
	gotRaw   string
	gotTerms []string
	calls    int
}

func (f *fakeCleaner) Clean(_ context.Context, raw string, preserveTerms []string) (string, error) {
	f.calls++
	f.gotRaw = raw
	f.gotTerms = preserveTerms
	return f.out, f.err
}

func TestExtract_SanitizesProviderResponse(t *testing.T) {
	f := &fakeCleaner{out: "- SpeakerGate\n- DeepFilterNet\n- speakergate"}
	got, err := Extract(context.Background(), f, "some window text", nil)
	if err != nil {
		t.Fatalf("Extract: %v", err)
	}
	want := []string{"SpeakerGate", "DeepFilterNet"}
	if len(got) != len(want) {
		t.Fatalf("Extract() = %v, want %v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("Extract()[%d] = %q, want %q", i, got[i], want[i])
		}
	}
}

func TestExtract_TruncatesWindowText(t *testing.T) {
	f := &fakeCleaner{out: "MCP"}
	huge := strings.Repeat("x", MaxWindowTextBytes*2)
	if _, err := Extract(context.Background(), f, huge, nil); err != nil {
		t.Fatalf("Extract: %v", err)
	}
	if len(f.gotRaw) > MaxWindowTextBytes {
		t.Errorf("provider received %d bytes, want <= %d", len(f.gotRaw), MaxWindowTextBytes)
	}
}

func TestExtract_PassesDictionaryAsPreserveTerms(t *testing.T) {
	f := &fakeCleaner{out: "MCP"}
	dict := []string{"WebRTC", "DeepFilterNet"}
	if _, err := Extract(context.Background(), f, "text", dict); err != nil {
		t.Fatalf("Extract: %v", err)
	}
	if len(f.gotTerms) != 2 || f.gotTerms[0] != "WebRTC" {
		t.Errorf("preserveTerms = %v, want %v", f.gotTerms, dict)
	}
}

func TestExtract_EmptyTextSkipsProviderCall(t *testing.T) {
	f := &fakeCleaner{out: "should not be called"}
	got, err := Extract(context.Background(), f, "   \n\t ", nil)
	if err != nil {
		t.Fatalf("Extract: %v", err)
	}
	if got != nil {
		t.Errorf("Extract() = %v, want nil", got)
	}
	if f.calls != 0 {
		t.Errorf("provider called %d times for empty text, want 0", f.calls)
	}
}

func TestExtract_PropagatesProviderError(t *testing.T) {
	f := &fakeCleaner{err: errors.New("network down")}
	got, err := Extract(context.Background(), f, "text", nil)
	if err == nil {
		t.Fatal("Extract() error = nil, want provider error")
	}
	if got != nil {
		t.Errorf("Extract() = %v, want nil on error", got)
	}
}

func TestExtract_TruncationDoesNotSplitRune(t *testing.T) {
	f := &fakeCleaner{out: "MCP"}
	// Multibyte runes straddling the byte cap must not be sliced.
	huge := strings.Repeat("世", MaxWindowTextBytes)
	if _, err := Extract(context.Background(), f, huge, nil); err != nil {
		t.Fatalf("Extract: %v", err)
	}
	if !utf8.ValidString(f.gotRaw) {
		t.Error("truncated window text is not valid UTF-8")
	}
}

func TestExtractPrompt_ContainsBothPlaceholders(t *testing.T) {
	// Without both placeholders, llm.RenderPrompt appends its
	// cleanup-flavoured trailer and the extraction prompt stops
	// making sense.
	if !strings.Contains(ExtractPrompt, "{{transcription}}") {
		t.Error("ExtractPrompt missing {{transcription}}")
	}
	if !strings.Contains(ExtractPrompt, "{{dictionary}}") {
		t.Error("ExtractPrompt missing {{dictionary}}")
	}
}

func TestNewExtractor_UnknownProviderErrors(t *testing.T) {
	_, err := NewExtractor(config.Config{LLMProvider: "nope"})
	if err == nil {
		t.Fatal("NewExtractor() error = nil, want unknown-provider error")
	}
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd core && go test ./internal/screenctx/ -run 'Extract|NewExtractor'`
Expected: compile FAILURE — `undefined: Extract`, `undefined: ExtractPrompt`.

- [ ] **Step 3: Write the implementation**

Create `core/internal/screenctx/extract.go`:

```go
package screenctx

import (
	"context"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/voice-keyboard/core/internal/config"
	"github.com/voice-keyboard/core/internal/llm"
)

const (
	// MaxWindowTextBytes bounds what leaves the process. Window text can
	// be arbitrarily large; this caps both cost and latency.
	MaxWindowTextBytes = 8192

	// ExtractTimeout bounds the provider call. Extraction is a
	// best-effort background enhancement — it must never outlive the
	// user's interest in the window it describes.
	ExtractTimeout = 5 * time.Second
)

// ExtractPrompt is the template handed to llm.Options.Prompt. It MUST
// contain both {{transcription}} and {{dictionary}}: llm.RenderPrompt
// appends its own cleanup-flavoured trailer for any placeholder it
// doesn't find, which would corrupt this instruction.
const ExtractPrompt = `You extract vocabulary hints for a speech-recognition system. Below is the text currently visible in the user's focused window. The user is about to dictate while looking at it.

List the words and phrases a speech recogniser is most likely to get wrong: proper nouns, people's names, product and project names, code identifiers, acronyms, filenames, and domain jargon.

Hard rules:
- Return ONLY a comma-separated list. No preamble, no numbering, no explanation.
- At most 20 items, most useful first.
- Every item must appear verbatim in the window text. Do not invent, translate, or correct.
- Skip ordinary English words a recogniser already handles.
- Skip anything resembling a secret, password, API key, or token.
- These terms are already covered — do NOT repeat them: {{dictionary}}
- If nothing qualifies, return an empty string.

Window text:
{{transcription}}`

// Extract asks the provider for keywords describing windowText and
// returns the sanitized result. dictTerms are passed as the "already
// covered" list so the model doesn't spend the budget on duplicates.
//
// Returns (nil, nil) for empty input without calling the provider.
func Extract(ctx context.Context, cleaner llm.Cleaner, windowText string, dictTerms []string) ([]string, error) {
	text := truncateUTF8(strings.TrimSpace(windowText), MaxWindowTextBytes)
	if text == "" {
		return nil, nil
	}
	raw, err := cleaner.Clean(ctx, text, dictTerms)
	if err != nil {
		return nil, err
	}
	return Sanitize(raw), nil
}

// NewExtractor builds a keyword-extraction Cleaner from the configured
// provider. It reuses the cleanup provider's model and credentials but
// overrides the prompt template, so no new provider plumbing, HTTP
// client, or key handling is needed. The LLM cleanup stage is entirely
// unaffected — this is a separate Cleaner instance.
func NewExtractor(cfg config.Config) (llm.Cleaner, error) {
	provider, err := llm.ProviderByName(cfg.LLMProvider)
	if err != nil {
		return nil, err
	}
	opts := llm.Options{
		Model:   cfg.LLMModel,
		BaseURL: cfg.LLMBaseURL,
		Prompt:  ExtractPrompt,
		Timeout: ExtractTimeout,
	}
	if provider.NeedsAPIKey {
		opts.APIKey = cfg.LLMAPIKey
	}
	return provider.New(opts)
}

// truncateUTF8 cuts s to at most max bytes on a rune boundary.
func truncateUTF8(s string, max int) string {
	if len(s) <= max {
		return s
	}
	cut := max
	for cut > 0 && !utf8.RuneStart(s[cut]) {
		cut--
	}
	return strings.TrimSpace(s[:cut])
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd core && go test ./internal/screenctx/`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add core/internal/screenctx/extract.go core/internal/screenctx/extract_test.go
git commit -m "feat(screenctx): extract keywords via the active LLM provider

Reuses llm.Cleaner with an overridden prompt template, so all four
providers work with no new plumbing. Cleanup stage is untouched."
```

---

### Task 5: C ABI exports and engine wiring

Two exports, deliberately split so a Swift-side cache hit costs no network. Neither goes through `howl_configure`, which rebuilds the pipeline (reloading the Whisper model) and is rejected mid-capture.

**Files:**
- Create: `core/cmd/libhowl/screenctx_export.go`
- Test: `core/cmd/libhowl/screenctx_export_test.go`
- Modify: `core/cmd/libhowl/state.go`
- Modify: `core/cmd/libhowl/exports.go`
- Modify: `core/internal/pipeline/pipeline.go`
- Modify: `core/internal/pipeline/manifest.go`
- Modify: `core/internal/sessions/manifest.go`

**Interfaces:**
- Consumes: `screenctx.NewExtractor`, `screenctx.Extract`, `screenctx.ExtractTimeout` (Task 4); `transcribe.PromptSetter` (Task 2).
- Produces:
  - C: `char *howl_extract_keywords(const char *json)` — input `{"text":"..."}`, output `{"keywords":[...]}` or `{"error":"..."}`
  - C: `int howl_set_screen_keywords(const char *json)` — input `{"keywords":[...]}`; 0 ok, 1 not initialized, 2 bad JSON
  - Go: `engine.screenKeywords []string`, `pipeline.Pipeline.ScreenKeywords []string`, `sessions.Manifest.ScreenKeywords []string`

- [ ] **Step 1: Add the engine field**

In `core/cmd/libhowl/state.go`, add to the `engine` struct after `lastErr`:

```go
	// screenKeywords holds the keyword list derived from the user's
	// focused window, set by howl_set_screen_keywords. Applied to the
	// transcriber at howl_start_capture — never mid-capture, so there
	// is no race against an in-flight Transcribe. Guarded by mu.
	screenKeywords []string
```

- [ ] **Step 2: Write the failing test**

Create `core/cmd/libhowl/screenctx_export_test.go`:

```go
//go:build whispercpp

package main

import (
	"encoding/json"
	"testing"
)

func TestSetScreenKeywords_StoresOnEngine(t *testing.T) {
	resetEngineForTest(t)
	rc := setScreenKeywordsJSON(`{"keywords":["SpeakerGate","DeepFilterNet"]}`)
	if rc != 0 {
		t.Fatalf("setScreenKeywordsJSON rc = %d, want 0", rc)
	}
	e := getEngine()
	e.mu.Lock()
	got := e.screenKeywords
	e.mu.Unlock()
	if len(got) != 2 || got[0] != "SpeakerGate" {
		t.Errorf("screenKeywords = %v, want [SpeakerGate DeepFilterNet]", got)
	}
}

func TestSetScreenKeywords_RejectsBadJSON(t *testing.T) {
	resetEngineForTest(t)
	if rc := setScreenKeywordsJSON(`not json`); rc != 2 {
		t.Errorf("rc = %d, want 2 for malformed JSON", rc)
	}
}

func TestSetScreenKeywords_EmptyListClearsPrevious(t *testing.T) {
	resetEngineForTest(t)
	setScreenKeywordsJSON(`{"keywords":["Stale"]}`)
	if rc := setScreenKeywordsJSON(`{"keywords":[]}`); rc != 0 {
		t.Fatalf("rc = %d, want 0", rc)
	}
	e := getEngine()
	e.mu.Lock()
	got := e.screenKeywords
	e.mu.Unlock()
	if len(got) != 0 {
		t.Errorf("screenKeywords = %v, want empty after clear", got)
	}
}

func TestExtractKeywords_UnknownProviderReturnsErrorJSON(t *testing.T) {
	resetEngineForTest(t)
	e := getEngine()
	e.mu.Lock()
	e.cfg.LLMProvider = "nope"
	e.mu.Unlock()

	out := extractKeywordsJSON(`{"text":"hello"}`)
	var resp struct {
		Error    string   `json:"error"`
		Keywords []string `json:"keywords"`
	}
	if err := json.Unmarshal([]byte(out), &resp); err != nil {
		t.Fatalf("response is not JSON: %v (%s)", err, out)
	}
	if resp.Error == "" {
		t.Errorf("expected an error field, got %s", out)
	}
}

func TestExtractKeywords_RejectsBadJSON(t *testing.T) {
	resetEngineForTest(t)
	out := extractKeywordsJSON(`not json`)
	if !json.Valid([]byte(out)) {
		t.Fatalf("response is not valid JSON: %s", out)
	}
	var resp struct {
		Error string `json:"error"`
	}
	_ = json.Unmarshal([]byte(out), &resp)
	if resp.Error == "" {
		t.Errorf("expected an error field, got %s", out)
	}
}
```

Add this helper to the same file — the export bodies must stay thin C wrappers so the logic is testable without cgo string juggling:

```go
// resetEngineForTest gives each test a clean engine. howl_init is
// idempotent on the C side; this mirrors it for Go-level tests.
func resetEngineForTest(t *testing.T) {
	t.Helper()
	if rc := howl_init(); rc != 0 {
		t.Fatalf("howl_init rc = %d", rc)
	}
	e := getEngine()
	e.mu.Lock()
	e.screenKeywords = nil
	e.mu.Unlock()
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `cd core && go test -tags="whispercpp deepfilter" ./cmd/libhowl/ -run 'ScreenKeywords|ExtractKeywords'`
Expected: compile FAILURE — `undefined: setScreenKeywordsJSON`, `undefined: extractKeywordsJSON`.

- [ ] **Step 4: Write the implementation**

Create `core/cmd/libhowl/screenctx_export.go`:

```go
//go:build whispercpp

package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"context"
	"encoding/json"

	"github.com/voice-keyboard/core/internal/screenctx"
)

// howl_extract_keywords derives whisper biasing keywords from the text
// of the user's focused window, using the configured LLM provider.
//
// Input:  {"text": "..."}
// Output: {"keywords": ["...", ...]} or {"error": "..."}
//
// BLOCKING — this makes a network call. Callers MUST invoke it off the
// main thread. It deliberately does not mutate engine state and does
// not hold e.mu across the network call. Free the result with
// howl_free_string.
//
//export howl_extract_keywords
func howl_extract_keywords(jsonC *C.char) *C.char {
	return C.CString(extractKeywordsJSON(C.GoString(jsonC)))
}

// howl_set_screen_keywords stores the keyword list for the next
// capture. Instant; no network. Returns 0 on success, 1 if the engine
// is not initialized, 2 on malformed JSON.
//
//export howl_set_screen_keywords
func howl_set_screen_keywords(jsonC *C.char) C.int {
	return C.int(setScreenKeywordsJSON(C.GoString(jsonC)))
}

// extractKeywordsJSON is the testable body of howl_extract_keywords.
func extractKeywordsJSON(in string) string {
	e := getEngine()
	if e == nil {
		return `{"error":"engine not initialized"}`
	}
	var req struct {
		Text string `json:"text"`
	}
	if err := json.Unmarshal([]byte(in), &req); err != nil {
		return errorJSON("invalid request json: " + err.Error())
	}

	// Snapshot the config so the network call below runs without
	// holding the engine lock.
	e.mu.Lock()
	cfg := e.cfg
	e.mu.Unlock()

	cleaner, err := screenctx.NewExtractor(cfg)
	if err != nil {
		return errorJSON(err.Error())
	}
	ctx, cancel := context.WithTimeout(context.Background(), screenctx.ExtractTimeout)
	defer cancel()

	kws, err := screenctx.Extract(ctx, cleaner, req.Text, cfg.CustomDict)
	if err != nil {
		return errorJSON(err.Error())
	}
	if kws == nil {
		kws = []string{}
	}
	out, err := json.Marshal(map[string][]string{"keywords": kws})
	if err != nil {
		return errorJSON(err.Error())
	}
	return string(out)
}

// setScreenKeywordsJSON is the testable body of howl_set_screen_keywords.
func setScreenKeywordsJSON(in string) int {
	e := getEngine()
	if e == nil {
		return 1
	}
	var req struct {
		Keywords []string `json:"keywords"`
	}
	if err := json.Unmarshal([]byte(in), &req); err != nil {
		e.setLastError("howl_set_screen_keywords: " + err.Error())
		return 2
	}
	e.mu.Lock()
	e.screenKeywords = req.Keywords
	e.mu.Unlock()
	return 0
}

// errorJSON renders an error response, never logging the window text
// that produced it.
func errorJSON(msg string) string {
	out, err := json.Marshal(map[string]string{"error": msg})
	if err != nil {
		return `{"error":"unknown"}`
	}
	return string(out)
}
```

- [ ] **Step 5: Apply the keywords at capture start**

In `core/cmd/libhowl/exports.go`, inside `howl_start_capture`, immediately after `pipe := e.pipeline` and while `e.mu` is still held:

```go
	// Re-bias whisper for this capture. Safe here and only here: no
	// capture is in flight, so this cannot race an in-flight Transcribe.
	// A transcriber that doesn't implement PromptSetter keeps whatever
	// prompt it was constructed with.
	if ps, ok := pipe.Transcriber.(transcribe.PromptSetter); ok {
		ps.SetContextPrompt(e.cfg.CustomDict, e.screenKeywords)
		log.Printf("[howl] howl_start_capture: applied %d screen keyword(s)", len(e.screenKeywords))
	}
```

Add `"github.com/voice-keyboard/core/internal/transcribe"` to that file's imports if not already present.

- [ ] **Step 6: Record the applied keywords in the session manifest**

The spec requires that raw window text never reaches a session manifest but the final keyword list does — so a developer inspecting a session can see what biased the ASR.

In `core/internal/pipeline/pipeline.go`, add to the `Pipeline` struct next to `Prompt`:

```go
	// ScreenKeywords are the screen-derived biasing terms applied to
	// the transcriber for this capture. Recorded in the session
	// manifest so a captured session shows what biased recognition.
	// The window TEXT they came from is deliberately never stored.
	ScreenKeywords []string
```

In `core/internal/sessions/manifest.go`, add to `Manifest` after `Transcripts`:

```go
	// ScreenKeywords are the screen-derived terms that reached whisper's
	// initial prompt. omitempty so existing manifests are unaffected.
	ScreenKeywords []string `json:"screen_keywords,omitempty"`
```

In `core/internal/pipeline/manifest.go`, populate it in the `sessions.Manifest{...}` literal:

```go
		ScreenKeywords: p.ScreenKeywords,
```

Then in `core/cmd/libhowl/exports.go`, in the same `howl_start_capture` block added in Step 5, stamp the pipeline so the manifest writer sees it:

```go
		pipe.ScreenKeywords = e.screenKeywords
```

- [ ] **Step 7: Run tests to verify they pass**

Run: `cd core && go test -tags="whispercpp deepfilter" ./cmd/libhowl/ ./internal/pipeline/ ./internal/sessions/`
Expected: PASS.

- [ ] **Step 8: Rebuild the dylib and confirm the new symbols exist**

Run:
```bash
cd core && make build-dylib
nm -gU build/libhowl.dylib | grep -E "howl_extract_keywords|howl_set_screen_keywords"
grep -E "howl_extract_keywords|howl_set_screen_keywords" build/libhowl.h
```
Expected: both symbols appear in the dylib AND in the generated header (Swift needs the header declarations).

- [ ] **Step 9: Commit**

```bash
git add core/cmd/libhowl/screenctx_export.go \
        core/cmd/libhowl/screenctx_export_test.go \
        core/cmd/libhowl/state.go \
        core/cmd/libhowl/exports.go \
        core/internal/pipeline/pipeline.go \
        core/internal/pipeline/manifest.go \
        core/internal/sessions/manifest.go
git commit -m "feat(libhowl): expose screen-keyword extraction over the C ABI

Split into a blocking extract call and an instant set call so a
Swift-side cache hit costs no network. Applied at start_capture, where
no capture is in flight, avoiding howl_configure's model reload."
```

---

### Task 6: Swift denylist and cache — pure, testable policy

**Files:**
- Create: `mac/Packages/HowlCore/Sources/HowlCore/ScreenContext/ScreenContextDenylist.swift`
- Create: `mac/Packages/HowlCore/Sources/HowlCore/ScreenContext/ScreenContextCache.swift`
- Test: `mac/Packages/HowlCore/Tests/HowlCoreTests/ScreenContextDenylistTests.swift`
- Test: `mac/Packages/HowlCore/Tests/HowlCoreTests/ScreenContextCacheTests.swift`

**Interfaces:**
- Consumes: nothing (leaves).
- Produces:
  - `ScreenContextDenylist.builtIn: [String]`
  - `ScreenContextDenylist(userAdditions: [String])` with `shouldSkip(bundleID: String?) -> Bool`
  - `ScreenContextCache(limit: Int = 32, ttl: TimeInterval = 600)` with `key(bundleID:windowTitle:text:) -> String`, `value(for: String, now: Date) -> [String]?`, `store(_ keywords: [String], for key: String, now: Date)`

- [ ] **Step 1: Write the failing tests**

Create `mac/Packages/HowlCore/Tests/HowlCoreTests/ScreenContextDenylistTests.swift`:

```swift
import Foundation
import Testing
@testable import HowlCore

@Suite("ScreenContextDenylist")
struct ScreenContextDenylistTests {

    @Test func built_in_list_covers_password_managers() {
        let d = ScreenContextDenylist(userAdditions: [])
        #expect(d.shouldSkip(bundleID: "com.1password.1password") == true)
        #expect(d.shouldSkip(bundleID: "com.apple.keychainaccess") == true)
    }

    @Test func ordinary_apps_are_not_skipped() {
        let d = ScreenContextDenylist(userAdditions: [])
        #expect(d.shouldSkip(bundleID: "com.microsoft.VSCode") == false)
    }

    @Test func matching_is_case_insensitive() {
        let d = ScreenContextDenylist(userAdditions: [])
        #expect(d.shouldSkip(bundleID: "COM.1Password.1Password") == true)
    }

    @Test func user_additions_are_honoured() {
        let d = ScreenContextDenylist(userAdditions: ["com.example.diary"])
        #expect(d.shouldSkip(bundleID: "com.example.diary") == true)
    }

    @Test func nil_bundle_id_is_skipped() {
        // An unidentifiable window is not worth the privacy risk.
        let d = ScreenContextDenylist(userAdditions: [])
        #expect(d.shouldSkip(bundleID: nil) == true)
    }

    @Test func blank_user_additions_are_ignored() {
        let d = ScreenContextDenylist(userAdditions: ["", "   "])
        #expect(d.shouldSkip(bundleID: "com.microsoft.VSCode") == false)
    }
}
```

Create `mac/Packages/HowlCore/Tests/HowlCoreTests/ScreenContextCacheTests.swift`:

```swift
import Foundation
import Testing
@testable import HowlCore

@Suite("ScreenContextCache")
struct ScreenContextCacheTests {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    @Test func stores_and_retrieves_by_key() {
        let c = ScreenContextCache()
        let k = c.key(bundleID: "com.a", windowTitle: "Doc", text: "hello")
        c.store(["MCP"], for: k, now: t0)
        #expect(c.value(for: k, now: t0) == ["MCP"])
    }

    @Test func miss_returns_nil() {
        let c = ScreenContextCache()
        let k = c.key(bundleID: "com.a", windowTitle: "Doc", text: "hello")
        #expect(c.value(for: k, now: t0) == nil)
    }

    @Test func same_text_produces_same_key() {
        let c = ScreenContextCache()
        let a = c.key(bundleID: "com.a", windowTitle: "Doc", text: "hello")
        let b = c.key(bundleID: "com.a", windowTitle: "Doc", text: "hello")
        #expect(a == b)
    }

    @Test func changed_text_produces_different_key() {
        let c = ScreenContextCache()
        let a = c.key(bundleID: "com.a", windowTitle: "Doc", text: "hello")
        let b = c.key(bundleID: "com.a", windowTitle: "Doc", text: "goodbye")
        #expect(a != b)
    }

    @Test func changed_bundle_id_produces_different_key() {
        let c = ScreenContextCache()
        let a = c.key(bundleID: "com.a", windowTitle: "Doc", text: "hello")
        let b = c.key(bundleID: "com.b", windowTitle: "Doc", text: "hello")
        #expect(a != b)
    }

    @Test func entry_expires_after_ttl() {
        let c = ScreenContextCache(limit: 32, ttl: 600)
        let k = c.key(bundleID: "com.a", windowTitle: "Doc", text: "hello")
        c.store(["MCP"], for: k, now: t0)
        #expect(c.value(for: k, now: t0.addingTimeInterval(599)) == ["MCP"])
        #expect(c.value(for: k, now: t0.addingTimeInterval(601)) == nil)
    }

    @Test func evicts_least_recently_used_past_limit() {
        let c = ScreenContextCache(limit: 2, ttl: 600)
        let k1 = c.key(bundleID: "com.a", windowTitle: "1", text: "one")
        let k2 = c.key(bundleID: "com.a", windowTitle: "2", text: "two")
        let k3 = c.key(bundleID: "com.a", windowTitle: "3", text: "three")
        c.store(["A"], for: k1, now: t0)
        c.store(["B"], for: k2, now: t0)
        _ = c.value(for: k1, now: t0)          // k1 becomes most-recent
        c.store(["C"], for: k3, now: t0)       // evicts k2
        #expect(c.value(for: k1, now: t0) == ["A"])
        #expect(c.value(for: k2, now: t0) == nil)
        #expect(c.value(for: k3, now: t0) == ["C"])
    }

    @Test func empty_keyword_list_is_cached_as_a_real_result() {
        // A window that legitimately yields no keywords must not be
        // re-extracted on every focus.
        let c = ScreenContextCache()
        let k = c.key(bundleID: "com.a", windowTitle: "Doc", text: "hello")
        c.store([], for: k, now: t0)
        #expect(c.value(for: k, now: t0) == [])
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd mac/Packages/HowlCore && swift test --filter ScreenContext`
Expected: compile FAILURE — `cannot find 'ScreenContextDenylist' in scope`.

- [ ] **Step 3: Write the denylist**

Create `mac/Packages/HowlCore/Sources/HowlCore/ScreenContext/ScreenContextDenylist.swift`:

```swift
import Foundation

/// Bundle IDs whose windows are never read for screen context.
///
/// Fail-closed: an app we cannot identify is skipped rather than read.
public struct ScreenContextDenylist: Sendable {
    /// Apps that are never read regardless of user settings. Password
    /// managers and the system keychain — windows whose contents are
    /// secrets by definition.
    public static let builtIn: [String] = [
        "com.1password.1password",
        "com.1password.1password7",
        "com.agilebits.onepassword7",
        "com.apple.keychainaccess",
        "com.bitwarden.desktop",
        "com.lastpass.lastpassmacdesktop",
        "com.dashlane.dashlanephonefinal",
        "in.sinew.Enpass-Desktop",
        "com.apple.Passwords",
    ]

    private let entries: Set<String>

    public init(userAdditions: [String]) {
        var all = Set(ScreenContextDenylist.builtIn.map { $0.lowercased() })
        for id in userAdditions {
            let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !trimmed.isEmpty { all.insert(trimmed) }
        }
        self.entries = all
    }

    /// Whether the focused window's owning app must not be read.
    /// A nil bundle ID (unidentifiable window) is skipped.
    public func shouldSkip(bundleID: String?) -> Bool {
        guard let id = bundleID?.lowercased(), !id.isEmpty else { return true }
        return entries.contains(id)
    }
}
```

- [ ] **Step 4: Write the cache**

Create `mac/Packages/HowlCore/Sources/HowlCore/ScreenContext/ScreenContextCache.swift`:

```swift
import CryptoKit
import Foundation

/// Keyword results keyed by window identity + content hash, so
/// re-focusing an unchanged window costs no LLM call.
///
/// `now` is injected on every access rather than read from the clock so
/// TTL behaviour is deterministic under test.
public final class ScreenContextCache: @unchecked Sendable {
    private struct Entry {
        let keywords: [String]
        let storedAt: Date
        var lastUsed: Date
    }

    private let limit: Int
    private let ttl: TimeInterval
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    public init(limit: Int = 32, ttl: TimeInterval = 600) {
        self.limit = limit
        self.ttl = ttl
    }

    /// Identity of a window's *content*. Hashing means the raw window
    /// text is never retained in memory beyond the extraction call.
    public func key(bundleID: String, windowTitle: String, text: String) -> String {
        let payload = "\(bundleID)\u{0}\(windowTitle)\u{0}\(text)"
        let digest = SHA256.hash(data: Data(payload.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    public func value(for key: String, now: Date = Date()) -> [String]? {
        lock.lock()
        defer { lock.unlock() }
        guard var entry = entries[key] else { return nil }
        if now.timeIntervalSince(entry.storedAt) > ttl {
            entries.removeValue(forKey: key)
            return nil
        }
        entry.lastUsed = now
        entries[key] = entry
        return entry.keywords
    }

    public func store(_ keywords: [String], for key: String, now: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        entries[key] = Entry(keywords: keywords, storedAt: now, lastUsed: now)
        guard entries.count > limit else { return }
        // Evict least-recently-used until back within the limit.
        let ordered = entries.sorted { $0.value.lastUsed < $1.value.lastUsed }
        for (k, _) in ordered.prefix(entries.count - limit) {
            entries.removeValue(forKey: k)
        }
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd mac/Packages/HowlCore && swift test --filter ScreenContext`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add mac/Packages/HowlCore/Sources/HowlCore/ScreenContext/ \
        mac/Packages/HowlCore/Tests/HowlCoreTests/ScreenContextDenylistTests.swift \
        mac/Packages/HowlCore/Tests/HowlCoreTests/ScreenContextCacheTests.swift
git commit -m "feat(screencontext): denylist and content-hash keyword cache"
```

---

### Task 7: Window text readers — AX fast path, OCR fallback

**Files:**
- Create: `mac/Packages/HowlCore/Sources/HowlCore/ScreenContext/WindowTextReader.swift`
- Create: `mac/Packages/HowlCore/Sources/HowlCore/ScreenContext/AXWindowTextReader.swift`
- Create: `mac/Packages/HowlCore/Sources/HowlCore/ScreenContext/OCRWindowTextReader.swift`
- Test: `mac/Packages/HowlCore/Tests/HowlCoreTests/WindowTextReaderTests.swift`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces:
  - `struct WindowSnapshot { let bundleID: String; let windowTitle: String; let text: String }`
  - `protocol WindowTextReader: Sendable { func read() async -> WindowSnapshot? }`
  - `AXWindowTextReader`, `OCRWindowTextReader`
  - `FallbackWindowTextReader(primary:fallback:minimumChars:)` — used by Task 8
  - `WindowTextReading.minimumUsefulChars = 200`

- [ ] **Step 1: Write the failing test**

Create `mac/Packages/HowlCore/Tests/HowlCoreTests/WindowTextReaderTests.swift`:

```swift
import Foundation
import Testing
@testable import HowlCore

/// Records whether it was consulted and returns a canned snapshot.
private final class FakeReader: WindowTextReader, @unchecked Sendable {
    let snapshot: WindowSnapshot?
    private(set) var callCount = 0
    init(_ snapshot: WindowSnapshot?) { self.snapshot = snapshot }
    func read() async -> WindowSnapshot? {
        callCount += 1
        return snapshot
    }
}

private func snap(_ text: String) -> WindowSnapshot {
    WindowSnapshot(bundleID: "com.a", windowTitle: "Doc", text: text)
}

@Suite("FallbackWindowTextReader")
struct WindowTextReaderTests {

    @Test func uses_primary_when_it_yields_enough_text() async {
        let primary = FakeReader(snap(String(repeating: "a", count: 250)))
        let fallback = FakeReader(snap("fallback"))
        let r = FallbackWindowTextReader(primary: primary, fallback: fallback, minimumChars: 200)

        let got = await r.read()
        #expect(got?.text.count == 250)
        #expect(fallback.callCount == 0)
    }

    @Test func falls_back_when_primary_yields_too_little() async {
        let primary = FakeReader(snap("short"))
        let fallback = FakeReader(snap(String(repeating: "b", count: 300)))
        let r = FallbackWindowTextReader(primary: primary, fallback: fallback, minimumChars: 200)

        let got = await r.read()
        #expect(got?.text.count == 300)
        #expect(fallback.callCount == 1)
    }

    @Test func falls_back_when_primary_returns_nil() async {
        let primary = FakeReader(nil)
        let fallback = FakeReader(snap(String(repeating: "b", count: 300)))
        let r = FallbackWindowTextReader(primary: primary, fallback: fallback, minimumChars: 200)

        let got = await r.read()
        #expect(got?.text.count == 300)
        #expect(fallback.callCount == 1)
    }

    @Test func returns_primary_result_when_fallback_also_fails() async {
        // Better a short AX snapshot than nothing at all.
        let primary = FakeReader(snap("short"))
        let fallback = FakeReader(nil)
        let r = FallbackWindowTextReader(primary: primary, fallback: fallback, minimumChars: 200)

        let got = await r.read()
        #expect(got?.text == "short")
    }

    @Test func returns_nil_when_both_fail() async {
        let r = FallbackWindowTextReader(primary: FakeReader(nil), fallback: FakeReader(nil), minimumChars: 200)
        #expect(await r.read() == nil)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd mac/Packages/HowlCore && swift test --filter WindowTextReaderTests`
Expected: compile FAILURE — `cannot find 'WindowSnapshot' in scope`.

- [ ] **Step 3: Write the protocol and composite**

Create `mac/Packages/HowlCore/Sources/HowlCore/ScreenContext/WindowTextReader.swift`:

```swift
import Foundation

/// Text read from the user's focused window, with the identity needed
/// to cache and denylist it.
public struct WindowSnapshot: Equatable, Sendable {
    public let bundleID: String
    public let windowTitle: String
    public let text: String

    public init(bundleID: String, windowTitle: String, text: String) {
        self.bundleID = bundleID
        self.windowTitle = windowTitle
        self.text = text
    }
}

/// Reads the text of the frontmost window. Implementations return nil
/// when they cannot read it at all (no permission, no focused window,
/// unsupported app).
public protocol WindowTextReader: Sendable {
    func read() async -> WindowSnapshot?
}

public enum WindowTextReading {
    /// Below this many characters an AX read is treated as unusable and
    /// the OCR fallback runs. Electron, Canvas, and terminal apps
    /// typically expose only a title or nothing at all.
    public static let minimumUsefulChars = 200
}

/// Tries `primary` first and falls back to `fallback` when the primary
/// yields nothing or too little to be useful.
///
/// This ordering is why most users never see a Screen Recording
/// permission prompt: native apps satisfy the AX path, and the
/// screenshot reader is only constructed lazily when AX comes up short.
public struct FallbackWindowTextReader: WindowTextReader {
    private let primary: any WindowTextReader
    private let fallback: any WindowTextReader
    private let minimumChars: Int

    public init(primary: any WindowTextReader,
                fallback: any WindowTextReader,
                minimumChars: Int = WindowTextReading.minimumUsefulChars) {
        self.primary = primary
        self.fallback = fallback
        self.minimumChars = minimumChars
    }

    public func read() async -> WindowSnapshot? {
        let first = await primary.read()
        if let first, first.text.count >= minimumChars {
            return first
        }
        if let second = await fallback.read(), second.text.count >= minimumChars {
            return second
        }
        // Fallback unavailable or no better — a short primary read still
        // beats nothing.
        return first
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd mac/Packages/HowlCore && swift test --filter WindowTextReaderTests`
Expected: PASS.

- [ ] **Step 5: Write the AX reader**

Create `mac/Packages/HowlCore/Sources/HowlCore/ScreenContext/AXWindowTextReader.swift`:

```swift
import AppKit
import ApplicationServices
import Foundation

/// Reads the focused window's text through the Accessibility API.
///
/// Requires no new TCC permission — Howl already holds Accessibility
/// for text injection. Returns nil for apps that expose no usable AX
/// text (Electron without AXManualAccessibility, Canvas apps, most
/// terminals); the caller falls back to OCR.
public struct AXWindowTextReader: WindowTextReader {
    /// Caps the AX tree walk so a pathological hierarchy can't stall
    /// the extraction path.
    private let maxNodes: Int
    private let maxChars: Int

    public init(maxNodes: Int = 3000, maxChars: Int = 8192) {
        self.maxNodes = maxNodes
        self.maxChars = maxChars
    }

    public func read() async -> WindowSnapshot? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleID = app.bundleIdentifier else { return nil }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        guard let window = copyElement(appElement, kAXFocusedWindowAttribute) else { return nil }

        let title = copyString(window, kAXTitleAttribute) ?? ""
        var collected = ""
        var visited = 0
        walk(window, into: &collected, visited: &visited)

        let text = collected.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return nil }
        return WindowSnapshot(bundleID: bundleID, windowTitle: title, text: text)
    }

    /// Depth-first walk accumulating AXValue and AXTitle strings.
    private func walk(_ element: AXUIElement, into out: inout String, visited: inout Int) {
        if visited >= maxNodes || out.count >= maxChars { return }
        visited += 1

        for attr in [kAXValueAttribute, kAXTitleAttribute] {
            if let s = copyString(element, attr) {
                let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    out += trimmed + "\n"
                    if out.count >= maxChars { return }
                }
            }
        }

        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else { return }
        for child in children {
            walk(child, into: &out, visited: &visited)
            if visited >= maxNodes || out.count >= maxChars { return }
        }
    }

    private func copyElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success else { return nil }
        guard let value = ref, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private func copyString(_ element: AXUIElement, _ attribute: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success else { return nil }
        return ref as? String
    }
}
```

- [ ] **Step 6: Write the OCR reader**

Create `mac/Packages/HowlCore/Sources/HowlCore/ScreenContext/OCRWindowTextReader.swift`:

```swift
import AppKit
import Foundation
import ScreenCaptureKit
import Vision

/// Screenshots the focused window and runs Apple's Vision OCR over it.
///
/// This is the fallback path for apps the Accessibility API cannot read
/// (Electron, Canvas, terminals). Constructing it does nothing; the
/// Screen Recording TCC prompt appears on the first actual `read()`.
/// Pixel buffers are never written to disk.
public struct OCRWindowTextReader: WindowTextReader {
    public init() {}

    public func read() async -> WindowSnapshot? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleID = app.bundleIdentifier else { return nil }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true
            )
            guard let window = content.windows.first(where: {
                $0.owningApplication?.processID == app.processIdentifier && $0.isOnScreen
            }) else { return nil }

            let config = SCStreamConfiguration()
            config.width = Int(window.frame.width)
            config.height = Int(window.frame.height)
            config.showsCursor = false

            let filter = SCContentFilter(desktopIndependentWindow: window)
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: config
            )

            let text = try recognizeText(in: image)
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return nil }
            return WindowSnapshot(
                bundleID: bundleID,
                windowTitle: window.title ?? "",
                text: trimmed
            )
        } catch {
            // Permission denied, window vanished mid-capture, or OCR
            // failure. All degrade to "no screen context" by design.
            return nil
        }
    }

    private func recognizeText(in image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false   // identifiers must not be "corrected"

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])

        guard let observations = request.results else { return "" }
        return observations
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
    }
}
```

- [ ] **Step 7: Verify the package still builds**

Run: `cd mac/Packages/HowlCore && swift build && swift test --filter ScreenContext`
Expected: builds clean under strict concurrency; tests PASS.

- [ ] **Step 8: Commit**

```bash
git add mac/Packages/HowlCore/Sources/HowlCore/ScreenContext/WindowTextReader.swift \
        mac/Packages/HowlCore/Sources/HowlCore/ScreenContext/AXWindowTextReader.swift \
        mac/Packages/HowlCore/Sources/HowlCore/ScreenContext/OCRWindowTextReader.swift \
        mac/Packages/HowlCore/Tests/HowlCoreTests/WindowTextReaderTests.swift
git commit -m "feat(screencontext): AX window reader with Vision OCR fallback"
```

---

### Task 8: Bridge methods, focus observer, and coordinator

**Files:**
- Modify: `mac/Packages/HowlCore/Sources/HowlCore/Bridge/CoreEngine.swift`
- Modify: `mac/Packages/HowlCore/Sources/HowlCore/Bridge/LibhowlEngine.swift`
- Create: `mac/Packages/HowlCore/Sources/HowlCore/ScreenContext/Debouncer.swift`
- Create: `mac/Packages/HowlCore/Sources/HowlCore/ScreenContext/ScreenContextObserver.swift`
- Create: `mac/Packages/HowlCore/Sources/HowlCore/ScreenContext/ScreenContextCoordinator.swift`
- Test: `mac/Packages/HowlCore/Tests/HowlCoreTests/ScreenContextCoordinatorTests.swift`
- Test: `mac/Packages/HowlCore/Tests/HowlCoreTests/DebouncerTests.swift`
- Modify: any in-repo `CoreEngine` test fake (search for `: CoreEngine` in `mac/Packages/HowlCore/Tests/`)

**Interfaces:**
- Consumes: `howl_extract_keywords` / `howl_set_screen_keywords` (Task 5); `ScreenContextDenylist`, `ScreenContextCache` (Task 6); `WindowTextReader`, `WindowSnapshot` (Task 7).
- Produces:
  - `CoreEngine.extractScreenKeywords(text: String) async -> [String]`
  - `CoreEngine.setScreenKeywords(_ keywords: [String]) async`
  - `ScreenContextCoordinator(reader:cache:denylist:isEnabled:extract:apply:)` — an actor — with `func refresh(now: Date) async` and `func scheduleRefresh()`
  - `Debouncer(interval: TimeInterval)` with `func schedule(_ action: @escaping @Sendable () async -> Void)` and `func cancel()`
  - `ScreenContextObserver(debounce: TimeInterval, onFocusSettled: @Sendable () async -> Void)` with `start()` / `stop()`

- [ ] **Step 1: Add the bridge methods**

In `CoreEngine.swift`, add to the protocol:

```swift
    /// Derive whisper biasing keywords from focused-window text via the
    /// configured LLM provider. Blocking on the C side, so the actor
    /// hop matters: never call this from a latency-sensitive path.
    /// Returns [] on any failure — screen context is best-effort.
    func extractScreenKeywords(text: String) async -> [String]

    /// Store the keyword list applied at the next startCapture.
    /// Instant; no network.
    func setScreenKeywords(_ keywords: [String]) async
```

In `LibhowlEngine.swift`, add the implementations:

```swift
    public func extractScreenKeywords(text: String) async -> [String] {
        struct Request: Encodable { let text: String }
        struct Response: Decodable {
            let keywords: [String]?
            let error: String?
        }
        guard let json = try? JSONEncoder().encode(Request(text: text)),
              let jsonString = String(data: json, encoding: .utf8) else { return [] }

        let raw: String? = jsonString.withCString { cstr in
            guard let out = howl_extract_keywords(UnsafeMutablePointer(mutating: cstr)) else { return nil }
            defer { howl_free_string(out) }
            return String(cString: out)
        }
        guard let raw,
              let data = raw.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(Response.self, from: data) else { return [] }
        // An error response degrades to "no screen context" by design.
        return decoded.keywords ?? []
    }

    public func setScreenKeywords(_ keywords: [String]) async {
        struct Request: Encodable { let keywords: [String] }
        guard let json = try? JSONEncoder().encode(Request(keywords: keywords)),
              let jsonString = String(data: json, encoding: .utf8) else { return }
        _ = jsonString.withCString { cstr in
            howl_set_screen_keywords(UnsafeMutablePointer(mutating: cstr))
        }
    }
```

- [ ] **Step 2: Update every existing `CoreEngine` fake**

Run: `grep -rln ": CoreEngine" mac/Packages/HowlCore/Tests mac/Howl`

For each conforming type found, add:

```swift
    func extractScreenKeywords(text: String) async -> [String] { [] }
    func setScreenKeywords(_ keywords: [String]) async {}
```

- [ ] **Step 3: Write the failing coordinator test**

Create `mac/Packages/HowlCore/Tests/HowlCoreTests/ScreenContextCoordinatorTests.swift`:

```swift
import Foundation
import Testing
@testable import HowlCore

private final class SpyEngine: @unchecked Sendable {
    var extractCalls = 0
    var lastExtractText = ""
    var setCalls: [[String]] = []
    var stubbedKeywords: [String] = ["SpeakerGate"]

    func extract(_ text: String) async -> [String] {
        extractCalls += 1
        lastExtractText = text
        return stubbedKeywords
    }
    func set(_ keywords: [String]) async {
        setCalls.append(keywords)
    }
}

private struct StubReader: WindowTextReader {
    let snapshot: WindowSnapshot?
    func read() async -> WindowSnapshot? { snapshot }
}

private func makeCoordinator(
    engine: SpyEngine,
    snapshot: WindowSnapshot?,
    enabled: Bool = true,
    denylist: [String] = [],
    cache: ScreenContextCache = ScreenContextCache()
) -> ScreenContextCoordinator {
    ScreenContextCoordinator(
        reader: StubReader(snapshot: snapshot),
        cache: cache,
        denylist: { ScreenContextDenylist(userAdditions: denylist) },
        isEnabled: { enabled },
        extract: { await engine.extract($0) },
        apply: { await engine.set($0) }
    )
}

private let t0 = Date(timeIntervalSince1970: 2_000_000)

@Suite("ScreenContextCoordinator")
struct ScreenContextCoordinatorTests {

    @Test func extracts_and_applies_keywords_on_refresh() async {
        let engine = SpyEngine()
        let c = makeCoordinator(engine: engine, snapshot: WindowSnapshot(bundleID: "com.a", windowTitle: "Doc", text: "SpeakerGate lives here"))
        await c.refresh(now: t0)
        #expect(engine.extractCalls == 1)
        #expect(engine.setCalls == [["SpeakerGate"]])
    }

    @Test func does_nothing_when_disabled() async {
        let engine = SpyEngine()
        let c = makeCoordinator(engine: engine, snapshot: WindowSnapshot(bundleID: "com.a", windowTitle: "Doc", text: "text"), enabled: false)
        await c.refresh(now: t0)
        #expect(engine.extractCalls == 0)
        #expect(engine.setCalls.isEmpty)
    }

    @Test func denylisted_app_is_never_read_or_extracted() async {
        let engine = SpyEngine()
        let c = makeCoordinator(
            engine: engine,
            snapshot: WindowSnapshot(bundleID: "com.1password.1password", windowTitle: "Vault", text: "hunter2"),
            denylist: []
        )
        await c.refresh(now: t0)
        #expect(engine.extractCalls == 0)
    }

    @Test func denylisted_app_clears_stale_keywords() async {
        // Focusing a denylisted app must not leave the previous
        // window's keywords armed for the next dictation.
        let engine = SpyEngine()
        let c = makeCoordinator(
            engine: engine,
            snapshot: WindowSnapshot(bundleID: "com.1password.1password", windowTitle: "Vault", text: "hunter2"),
            denylist: []
        )
        await c.refresh(now: t0)
        #expect(engine.setCalls == [[]])
    }

    @Test func second_refresh_of_unchanged_window_hits_cache() async {
        let engine = SpyEngine()
        let cache = ScreenContextCache()
        let snapshot = WindowSnapshot(bundleID: "com.a", windowTitle: "Doc", text: "unchanged text")
        let c = makeCoordinator(engine: engine, snapshot: snapshot, cache: cache)

        await c.refresh(now: t0)
        await c.refresh(now: t0)

        #expect(engine.extractCalls == 1)          // no second network call
        #expect(engine.setCalls.count == 2)        // but keywords re-applied
    }

    @Test func nil_snapshot_clears_keywords_without_extracting() async {
        let engine = SpyEngine()
        let c = makeCoordinator(engine: engine, snapshot: nil)
        await c.refresh(now: t0)
        #expect(engine.extractCalls == 0)
        #expect(engine.setCalls == [[]])
    }

    @Test func window_text_is_forwarded_verbatim_to_the_extractor() async {
        let engine = SpyEngine()
        let c = makeCoordinator(engine: engine, snapshot: WindowSnapshot(bundleID: "com.a", windowTitle: "Doc", text: "the exact text"))
        await c.refresh(now: t0)
        #expect(engine.lastExtractText == "the exact text")
    }
}
```

- [ ] **Step 4: Run test to verify it fails**

Run: `cd mac/Packages/HowlCore && swift test --filter ScreenContextCoordinator`
Expected: compile FAILURE — `cannot find 'ScreenContextCoordinator' in scope`.

- [ ] **Step 5: Write the coordinator**

Create `mac/Packages/HowlCore/Sources/HowlCore/ScreenContext/ScreenContextCoordinator.swift`:

```swift
import Foundation
import OSLog

/// Orchestrates denylist → read → cache → extract → apply.
///
/// Dependencies arrive as closures so the whole policy is testable
/// without AppKit, a live engine, or a network.
public actor ScreenContextCoordinator {
    private let reader: any WindowTextReader
    private let cache: ScreenContextCache
    private let denylist: @Sendable () -> ScreenContextDenylist
    private let isEnabled: @Sendable () -> Bool
    private let extract: @Sendable (String) async -> [String]
    private let apply: @Sendable ([String]) async -> Void

    private let log = Logger(subsystem: "com.howl.app", category: "screencontext")
    private var inFlight: Task<Void, Never>?

    public init(
        reader: any WindowTextReader,
        cache: ScreenContextCache,
        denylist: @escaping @Sendable () -> ScreenContextDenylist,
        isEnabled: @escaping @Sendable () -> Bool,
        extract: @escaping @Sendable (String) async -> [String],
        apply: @escaping @Sendable ([String]) async -> Void
    ) {
        self.reader = reader
        self.cache = cache
        self.denylist = denylist
        self.isEnabled = isEnabled
        self.extract = extract
        self.apply = apply
    }

    /// Re-derive keywords for whatever window is focused right now.
    /// Never throws and never blocks a dictation: every failure path
    /// ends in dictionary-only behaviour.
    public func refresh(now: Date = Date()) async {
        guard isEnabled() else { return }

        guard let snapshot = await reader.read() else {
            // No readable window — clear rather than leave the previous
            // window's keywords armed.
            await apply([])
            return
        }

        if denylist().shouldSkip(bundleID: snapshot.bundleID) {
            log.debug("screen context skipped for denylisted app")
            await apply([])
            return
        }

        let key = cache.key(
            bundleID: snapshot.bundleID,
            windowTitle: snapshot.windowTitle,
            text: snapshot.text
        )
        if let cached = cache.value(for: key, now: now) {
            await apply(cached)
            return
        }

        let keywords = await extract(snapshot.text)
        cache.store(keywords, for: key, now: now)
        await apply(keywords)
        // Deliberately logs the COUNT, never the terms or window text.
        log.debug("screen context applied \(keywords.count, privacy: .public) keyword(s)")
    }

    /// Schedule a refresh, superseding any still running — a newer
    /// window's context always wins over a stale in-flight extraction.
    public func scheduleRefresh() {
        inFlight?.cancel()
        inFlight = Task { [weak self] in
            await self?.refresh()
        }
    }
}
```

- [ ] **Step 6: Write the failing debounce test**

The spec requires proof that rapid focus changes collapse to one extraction. Keeping the timing logic in its own type is what makes that testable — an AppKit notification shim is not.

Create `mac/Packages/HowlCore/Tests/HowlCoreTests/DebouncerTests.swift`:

```swift
import Foundation
import Testing
@testable import HowlCore

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() {
        lock.lock(); value += 1; lock.unlock()
    }
    var count: Int {
        lock.lock(); defer { lock.unlock() }; return value
    }
}

@Suite("Debouncer")
struct DebouncerTests {

    @Test func runs_the_action_after_the_interval() async throws {
        let c = Counter()
        let d = Debouncer(interval: 0.05)
        d.schedule { c.increment() }
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(c.count == 1)
    }

    @Test func rapid_schedules_collapse_to_one_run() async throws {
        let c = Counter()
        let d = Debouncer(interval: 0.05)
        for _ in 0..<5 {
            d.schedule { c.increment() }
            try await Task.sleep(nanoseconds: 5_000_000)   // faster than the interval
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(c.count == 1)
    }

    @Test func cancel_prevents_a_pending_run() async throws {
        let c = Counter()
        let d = Debouncer(interval: 0.05)
        d.schedule { c.increment() }
        d.cancel()
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(c.count == 0)
    }

    @Test func separated_schedules_each_run() async throws {
        let c = Counter()
        let d = Debouncer(interval: 0.05)
        d.schedule { c.increment() }
        try await Task.sleep(nanoseconds: 200_000_000)
        d.schedule { c.increment() }
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(c.count == 2)
    }
}
```

- [ ] **Step 7: Run the debounce test to verify it fails**

Run: `cd mac/Packages/HowlCore && swift test --filter Debouncer`
Expected: compile FAILURE — `cannot find 'Debouncer' in scope`.

- [ ] **Step 8: Write the debouncer**

Create `mac/Packages/HowlCore/Sources/HowlCore/ScreenContext/Debouncer.swift`:

```swift
import Foundation

/// Runs an action once the caller has stopped scheduling it for
/// `interval` seconds. Extracted from the focus observer so the
/// collapse-rapid-events behaviour is testable without AppKit.
public final class Debouncer: @unchecked Sendable {
    private let interval: TimeInterval
    private let lock = NSLock()
    private var pending: Task<Void, Never>?

    public init(interval: TimeInterval) {
        self.interval = interval
    }

    /// Schedule `action`, superseding any run not yet started.
    public func schedule(_ action: @escaping @Sendable () async -> Void) {
        lock.lock()
        pending?.cancel()
        let seconds = interval
        pending = Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if Task.isCancelled { return }
            await action()
        }
        lock.unlock()
    }

    public func cancel() {
        lock.lock()
        pending?.cancel()
        pending = nil
        lock.unlock()
    }

    deinit { pending?.cancel() }
}
```

- [ ] **Step 9: Run the debounce test to verify it passes**

Run: `cd mac/Packages/HowlCore && swift test --filter Debouncer`
Expected: PASS.

- [ ] **Step 10: Write the observer**

Create `mac/Packages/HowlCore/Sources/HowlCore/ScreenContext/ScreenContextObserver.swift`:

```swift
import AppKit
import Foundation

/// Fires `onFocusSettled` once the frontmost app has stayed frontmost
/// for `debounce` seconds, so alt-tabbing through windows costs
/// nothing. Thin AppKit shim — the timing lives in Debouncer and the
/// policy in ScreenContextCoordinator, which is where the tests are.
@MainActor
public final class ScreenContextObserver {
    private let debouncer: Debouncer
    private let onFocusSettled: @Sendable () async -> Void
    private var observer: NSObjectProtocol?

    public init(debounce: TimeInterval = 0.8,
                onFocusSettled: @escaping @Sendable () async -> Void) {
        self.debouncer = Debouncer(interval: debounce)
        self.onFocusSettled = onFocusSettled
    }

    public func start() {
        guard observer == nil else { return }
        let action = onFocusSettled
        let debouncer = self.debouncer
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { _ in
            debouncer.schedule(action)
        }
        // Prime with whatever is already focused at startup.
        debouncer.schedule(action)
    }

    public func stop() {
        if let observer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observer = nil
        debouncer.cancel()
    }

    deinit {
        if let observer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }
}
```

- [ ] **Step 11: Run tests to verify they pass**

Run: `cd mac/Packages/HowlCore && swift test`
Expected: PASS, including previously existing suites.

- [ ] **Step 12: Commit**

```bash
git add mac/Packages/HowlCore/Sources/HowlCore/Bridge/CoreEngine.swift \
        mac/Packages/HowlCore/Sources/HowlCore/Bridge/LibhowlEngine.swift \
        mac/Packages/HowlCore/Sources/HowlCore/ScreenContext/Debouncer.swift \
        mac/Packages/HowlCore/Sources/HowlCore/ScreenContext/ScreenContextCoordinator.swift \
        mac/Packages/HowlCore/Sources/HowlCore/ScreenContext/ScreenContextObserver.swift \
        mac/Packages/HowlCore/Tests/HowlCoreTests/
git commit -m "feat(screencontext): focus observer, coordinator, and engine bridge"
```

---

### Task 9: Settings, wiring, and end-to-end verification

**Files:**
- Modify: `mac/Packages/HowlCore/Sources/HowlCore/Storage/SettingsStore.swift`
- Create: `mac/Howl/UI/Settings/ScreenContextSection.swift`
- Modify: `mac/Howl/UI/Settings/GeneralTab.swift`
- Modify: `mac/Howl/Composition/CompositionRoot.swift`
- Modify: `mac/Howl/Engine/EngineCoordinator.swift`
- Regenerate + commit: `mac/Howl.xcodeproj/project.pbxproj`
- Test: `mac/Packages/HowlCore/Tests/HowlCoreTests/ScreenContextSettingsTests.swift`

**Interfaces:**
- Consumes: `ScreenContextCoordinator`, `ScreenContextObserver` (Task 8); `AXWindowTextReader`, `OCRWindowTextReader`, `FallbackWindowTextReader` (Task 7).
- Produces: `UserSettings.screenContextEnabled: Bool` (default `true`), `UserSettings.screenContextDenylist: [String]` (default `[]`).

- [ ] **Step 1: Write the failing settings test**

Create `mac/Packages/HowlCore/Tests/HowlCoreTests/ScreenContextSettingsTests.swift`:

```swift
import Foundation
import Testing
@testable import HowlCore

@Suite("ScreenContext settings")
struct ScreenContextSettingsTests {

    @Test func screen_context_defaults_to_enabled() {
        #expect(UserSettings().screenContextEnabled == true)
    }

    @Test func denylist_defaults_to_empty() {
        #expect(UserSettings().screenContextDenylist.isEmpty)
    }

    @Test func survives_a_json_round_trip() throws {
        var s = UserSettings()
        s.screenContextEnabled = false
        s.screenContextDenylist = ["com.example.diary"]

        let data = try JSONEncoder().encode(s)
        let out = try JSONDecoder().decode(UserSettings.self, from: data)

        #expect(out.screenContextEnabled == false)
        #expect(out.screenContextDenylist == ["com.example.diary"])
    }

    @Test func legacy_settings_without_the_keys_decode_with_defaults() throws {
        // Existing installs have no screenContext keys; decoding must
        // not fail and must land on the shipped default. Build the
        // legacy payload by encoding a real UserSettings and deleting
        // the new keys, so this test can't rot against unrelated
        // changes to KeyboardShortcut/HIDBinding encoding.
        var s = UserSettings()
        s.screenContextEnabled = false
        s.screenContextDenylist = ["com.example.diary"]
        let data = try JSONEncoder().encode(s)
        var object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        object.removeValue(forKey: "screenContextEnabled")
        object.removeValue(forKey: "screenContextDenylist")
        let legacy = try JSONSerialization.data(withJSONObject: object)

        let out = try JSONDecoder().decode(UserSettings.self, from: legacy)
        #expect(out.screenContextEnabled == true)
        #expect(out.screenContextDenylist.isEmpty)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd mac/Packages/HowlCore && swift test --filter ScreenContextSettingsTests`
Expected: compile FAILURE — `value of type 'UserSettings' has no member 'screenContextEnabled'`.

- [ ] **Step 3: Add the settings fields**

In `SettingsStore.swift`, add to `UserSettings` after `selectedPresetName`:

```swift
    /// Whether Howl reads the focused window to bias whisper's
    /// recognition. Default ON. Reading uses the Accessibility API Howl
    /// already holds; the Screen Recording prompt only appears if an
    /// app needs the OCR fallback.
    public var screenContextEnabled: Bool
    /// Extra bundle IDs never read for screen context, on top of
    /// ScreenContextDenylist.builtIn.
    public var screenContextDenylist: [String]
```

Add to the `init` signature (at the end, preserving the existing order):

```swift
        screenContextEnabled: Bool = true,
        screenContextDenylist: [String] = []
```

and to the body:

```swift
        self.screenContextEnabled = screenContextEnabled
        self.screenContextDenylist = screenContextDenylist
```

`UserSettings` ALREADY has a hand-written `init(from decoder:) throws` (at
`SettingsStore.swift:78`) and an explicit `enum CodingKeys` with a listed
case for every field. Do NOT write a new `init(from decoder:)` — that is an
invalid redeclaration, and replacing the existing one risks regressing the
fields it already handles.

Make exactly two edits.

First, add the two new cases to the existing `enum CodingKeys` (required, or
the new keys will not compile):

```swift
        case screenContextEnabled, screenContextDenylist
```

Second, append these two lines to the END of the existing
`init(from decoder:)` body, immediately after the `selectedPresetName` line:

```swift
        // New in the screen-context feature; absent in existing installs.
        screenContextEnabled = try c.decodeIfPresent(Bool.self, forKey: .screenContextEnabled) ?? true
        screenContextDenylist = try c.decodeIfPresent([String].self, forKey: .screenContextDenylist) ?? []
```

Leave every existing line in that initializer exactly as it is. In
particular, every existing field uses the tolerant
`decodeIfPresent(...) ?? <default>` form. That is deliberate and
load-bearing: it is what lets a settings file written by an older build
decode without throwing. Do not "tighten" any of them to `decode(...)` —
doing so would make a missing key throw, which fails the whole
`UserSettings` decode and silently resets ALL of the user's settings to
defaults.

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd mac/Packages/HowlCore && swift test`
Expected: PASS — including the existing `SettingsStoreTests` and `UserSettingsApplyPresetTests`.

- [ ] **Step 5: Build the Settings UI**

Create `mac/Howl/UI/Settings/ScreenContextSection.swift`:

```swift
import HowlCore
import SwiftUI

/// Screen-context controls: the master toggle and the per-app denylist.
struct ScreenContextSection: View {
    @Binding var enabled: Bool
    @Binding var denylist: [String]
    @State private var newBundleID: String = ""

    var body: some View {
        Section("Screen Context") {
            Toggle("Use on-screen text to improve recognition", isOn: $enabled)
            Text("""
                 Howl reads the text of your focused window and sends it to your \
                 configured LLM provider to pull out names and jargon, which bias \
                 Whisper toward the right spellings. Password managers are never read.
                 """)
                .font(.caption)
                .foregroundStyle(.secondary)

            if enabled {
                LabeledContent("Never read") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(denylist, id: \.self) { id in
                            HStack {
                                Text(id).font(.system(.body, design: .monospaced))
                                Spacer()
                                Button("Remove") {
                                    denylist.removeAll { $0 == id }
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                        HStack {
                            TextField("com.example.app", text: $newBundleID)
                                .textFieldStyle(.roundedBorder)
                            Button("Add") {
                                let trimmed = newBundleID.trimmingCharacters(in: .whitespacesAndNewlines)
                                guard !trimmed.isEmpty, !denylist.contains(trimmed) else { return }
                                denylist.append(trimmed)
                                newBundleID = ""
                            }
                            .disabled(newBundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                }
            }
        }
    }
}
```

`GeneralTab` already declares `@Binding var settings: UserSettings` (line 9) and renders sections inside `var body` (line 40). Add this as a new section in that body, after the existing ones:

```swift
                ScreenContextSection(
                    enabled: $settings.screenContextEnabled,
                    denylist: $settings.screenContextDenylist
                )
```

- [ ] **Regenerate the Xcode project (required — a new file was added)**

`mac/Howl.xcodeproj` is tracked in git but generated by xcodegen from
`project.yml`, which globs `path: Howl`. Creating
`mac/Howl/UI/Settings/ScreenContextSection.swift` therefore changes the
source set, and the generated project must be regenerated and committed or
the new file is absent from the app target for everyone else.

Run:

```bash
cd mac && make project
```

Then include the regenerated `mac/Howl.xcodeproj/project.pbxproj` in your
commit. Never hand-edit the pbxproj.

- [ ] **Step 6: Wire it up in the composition root**

`CompositionRoot` is a `public final class` (line 5) holding `public let engine: any CoreEngine` (line 7) and `public let settings: any SettingsStore` (line 14), with `public lazy var` collaborators from line 53. `SettingsStore` is declared `: Sendable`, so capturing it in the `@Sendable` closures below is legal under strict concurrency.

Add these next to the other `lazy var` collaborators (after `conflictChecker`, line 62):

```swift
    let screenContextCache = ScreenContextCache()

    lazy var screenContextCoordinator = ScreenContextCoordinator(
        reader: FallbackWindowTextReader(
            primary: AXWindowTextReader(),
            fallback: OCRWindowTextReader()
        ),
        cache: screenContextCache,
        denylist: { [settings] in
            let userAdditions = (try? settings.get())?.screenContextDenylist ?? []
            return ScreenContextDenylist(userAdditions: userAdditions)
        },
        isEnabled: { [settings] in
            (try? settings.get())?.screenContextEnabled ?? true
        },
        extract: { [engine] text in await engine.extractScreenKeywords(text: text) },
        apply: { [engine] keywords in await engine.setScreenKeywords(keywords) }
    )

    lazy var screenContextObserver = ScreenContextObserver { [screenContextCoordinator] in
        // scheduleRefresh, not refresh: it cancels a still-running
        // extraction for a window the user has already left, so a newer
        // window's context always wins.
        await screenContextCoordinator.scheduleRefresh()
    }
```

In `mac/Howl/Engine/EngineCoordinator.swift`, add `composition.screenContextObserver.start()` at the end of `public func start()` (line 185), alongside the other listener registrations, and `composition.screenContextObserver.stop()` in `public func stop()` (line 233).

- [ ] **Step 7: Build the app**

Run: `cd mac && make build`
Expected: BUILD SUCCEEDED. Fix any strict-concurrency diagnostics before continuing.

- [ ] **Step 8: End-to-end manual verification**

1. `cd mac && make run`
2. Focus a code editor showing distinctive identifiers (e.g. `SpeakerGate`, `DeepFilterNet`). Wait ~1 s.
3. Confirm in `/tmp/howl.log`: `applied N screen keyword(s)` with `N > 0`.
4. Dictate a sentence containing one of those identifiers; confirm the spelling survives into the injected text.
5. Focus 1Password, wait, then dictate. Confirm the log shows `applied 0 screen keyword(s)` and no extraction ran.
6. Alt-tab rapidly through five windows. Confirm at most one extraction fires.
7. Toggle the setting off, focus a new window, dictate. Confirm no extraction occurs.
8. Confirm no raw window text appears anywhere in `/tmp/howl.log`.

Use `/usr/bin/log` (not bare `log`) if you need the unified log; `.notice` and above persist.

- [ ] **Step 9: Commit**

```bash
git add mac/Packages/HowlCore/Sources/HowlCore/Storage/SettingsStore.swift \
        mac/Packages/HowlCore/Tests/HowlCoreTests/ScreenContextSettingsTests.swift \
        mac/Howl/UI/Settings/ScreenContextSection.swift \
        mac/Howl/UI/Settings/GeneralTab.swift \
        mac/Howl/Composition/CompositionRoot.swift
git commit -m "feat(settings): screen-context toggle, denylist editor, and wiring"
```

---

## Verification Checklist

Run before opening a PR:

- [ ] `cd core && make test-unit` — PASS
- [ ] `cd core && go test -tags="whispercpp deepfilter" ./...` — PASS
- [ ] `cd core && make build-dylib` — dylib and header both regenerate
- [ ] `cd mac/Packages/HowlCore && swift test` — PASS
- [ ] `cd mac && make build` — BUILD SUCCEEDED
- [ ] Task 9 Step 8 manual checks all pass
- [ ] `grep -rn "windowText\|snapshot.text" core/ mac/ | grep -i "log\."` returns nothing — raw window text is never logged
