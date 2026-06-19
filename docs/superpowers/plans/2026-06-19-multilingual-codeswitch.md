# Multilingual Code-Switch Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a bilingual user configure a primary + optional secondary language so whisper retains both scripts in one dictation (best-effort code-switch), and fix the latent bug where non-English selections silently load English-only models.

**Architecture:** Add a `secondaryLanguage` setting that flows Swift→Go like the existing `language` field. The engine is unchanged — it already anchors whisper on the primary language and feeds the custom dictionary as the initial prompt (the validated code-switch primer). A pure `WhisperModelSelection` helper in HowlCore forces the `large-v3` multilingual model whenever multilingual weights are needed; the app threads its "effective size" into model-path resolution, download, and status UI. A synthesized EN+ZH fixture proves correctness end-to-end.

**Tech Stack:** Go (whispercpp cgo build tag) for the core; Swift (swift-testing in the HowlCore SwiftPM package) for settings/bridge/model-selection; macOS `say` + `afconvert` + `python3` (stdlib `wave`) to synthesize the test fixture; `whisper-cli`/large-v3 already validated the mechanism.

## Global Constraints

- **Primary language** = the existing `language` field (Swift `UserSettings.language` / Go `Config.Language`), default `"en"`. Do **not** rename it.
- **Secondary language** = new field `secondaryLanguage` (Swift) / `secondary_language` (JSON + Go `Config.SecondaryLanguage`), default `"none"`.
- **`needsMultilingual(primary, secondary)`** is true iff `primary != "en"` OR `effectiveSecondary != "none"`, where `effectiveSecondary = (secondary == primary ? "none" : secondary)`.
- **Model rule:** `needsMultilingual` → load model size `"large"` (resolves to `ggml-large-v3.bin`). Otherwise the user's requested size, unchanged (`ggml-<size>.en.bin`).
- **Engine mechanism:** anchor `whisper.language = primary`; the dictionary `initial_prompt` (`transcribe.DictionaryPrompt`) carries both scripts. **No new whisper decode branch.**
- **Primary picker** keeps `"auto"` in its list; **secondary picker** options are `["none","en","es","fr","de","it","pt","ja","ko","zh"]` (no `auto`), default `"none"`, `"none"` displayed as "None".
- **No app test target exists** — app-target changes (EngineCoordinator, GeneralTab, ModelPaths) are build-verified; all unit tests live in the `config`/`presets`/`transcribe` Go packages and the `HowlCore` SwiftPM test target.
- Go module path: `github.com/voice-keyboard/core`. Go tests run with `go test -tags whispercpp ./...`.
- **Tier-2 e2e test is local/opt-in:** it must `t.Skipf` (not fail) when `ggml-large-v3.bin` is absent, so CI stays green.
- Validation spike (see spec) already proved `-l en` + dictionary prompt retains `会议`; the production config is correct.

---

### Task 1: Go config — `SecondaryLanguage` field, defaults, and a testable log summary

**Files:**
- Modify: `core/internal/config/config.go`
- Modify: `core/cmd/libhowl/exports.go:124-127` (swap the dictionary log line)
- Test: `core/internal/config/config_test.go` (create)

**Interfaces:**
- Produces: `config.Config.SecondaryLanguage string` (json `secondary_language`); `func (c *Config) LogSummary() string`.
- Consumes: nothing new.

- [ ] **Step 1: Write the failing test**

Create `core/internal/config/config_test.go`:

```go
package config

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestWithDefaults_SecondaryLanguageDefaultsToNone(t *testing.T) {
	c := &Config{}
	WithDefaults(c)
	if c.SecondaryLanguage != "none" {
		t.Errorf("SecondaryLanguage = %q, want \"none\"", c.SecondaryLanguage)
	}
}

func TestConfig_UnmarshalsSecondaryLanguage(t *testing.T) {
	var c Config
	if err := json.Unmarshal([]byte(`{"secondary_language":"zh"}`), &c); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if c.SecondaryLanguage != "zh" {
		t.Errorf("SecondaryLanguage = %q, want \"zh\"", c.SecondaryLanguage)
	}
}

func TestConfig_LogSummary(t *testing.T) {
	c := &Config{Language: "en", SecondaryLanguage: "zh", CustomDict: []string{"会议"}}
	got := c.LogSummary()
	want := `primary=en secondary=zh, 1 dictionary term(s): ["会议"]`
	if got != want {
		t.Errorf("LogSummary() = %q, want %q", got, want)
	}
}

func TestConfig_LogSummary_EmptySecondaryReadsNone(t *testing.T) {
	c := &Config{Language: "en"}
	if got := c.LogSummary(); !strings.Contains(got, "secondary=none") {
		t.Errorf("LogSummary() = %q, want it to contain secondary=none", got)
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd core && go test ./internal/config/...`
Expected: FAIL — `c.SecondaryLanguage` undefined, `c.LogSummary` undefined.

- [ ] **Step 3: Add the field, default, and method**

In `core/internal/config/config.go`, add the field immediately after the `Language` field (line 14):

```go
	Language                string   `json:"language"`
	// SecondaryLanguage is the optional second language for code-switch
	// dictation. "none" (the default) means single-language behavior. When
	// set, the Mac app loads the multilingual large model and the custom
	// dictionary (whisper initial prompt) primes both scripts. The engine
	// itself stays anchored on Language; this field is threaded through for
	// model selection (Swift side) and observability.
	SecondaryLanguage       string   `json:"secondary_language"`
```

Add to `WithDefaults` (after the `Language` default block, ~line 94):

```go
	if c.SecondaryLanguage == "" {
		c.SecondaryLanguage = "none"
	}
```

Add `"fmt"` to the imports, and add this method (e.g. right after `PipelineTimeoutValue`):

```go
// LogSummary returns a one-line, log-safe summary of the recognition-relevant
// config — primary/secondary language and the custom dictionary — so the
// dictionary → initial-prompt and language propagation are observable in
// /tmp/howl.log on every howl_configure.
func (c *Config) LogSummary() string {
	secondary := c.SecondaryLanguage
	if secondary == "" {
		secondary = "none"
	}
	return fmt.Sprintf("primary=%s secondary=%s, %d dictionary term(s): %q",
		c.Language, secondary, len(c.CustomDict), c.CustomDict)
}
```

- [ ] **Step 4: Wire the log line in exports.go**

In `core/cmd/libhowl/exports.go`, replace the existing dictionary log (lines 124-127, the `log.Printf("[howl] howl_configure: received %d dictionary term(s)...` block) with:

```go
	// Log recognition-relevant config so dictionary → initial-prompt and
	// primary/secondary language propagation are observable in /tmp/howl.log.
	log.Printf("[howl] howl_configure: %s", cfg.LogSummary())
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd core && go test ./internal/config/... && go build -tags whispercpp ./cmd/libhowl/`
Expected: config tests PASS; libhowl builds clean.

- [ ] **Step 6: Commit**

```bash
git add core/internal/config/config.go core/internal/config/config_test.go core/cmd/libhowl/exports.go
git commit -m "feat(config): add secondary_language field + LogSummary"
```

---

### Task 2: Go presets — thread `SecondaryLanguage` through Resolve and its callers

**Files:**
- Modify: `core/internal/presets/resolve.go` (`EngineSecrets` struct + `Resolve`)
- Modify: `core/cmd/libhowl/replay_export.go:92-105` (`secretsFromEngineCfg`)
- Modify: `core/cmd/howl-cli/compare.go:~136` (`EngineSecrets{...}` literal)
- Test: `core/internal/presets/resolve_test.go` (add one test)

**Interfaces:**
- Consumes: `config.Config.SecondaryLanguage` (Task 1).
- Produces: `presets.EngineSecrets.SecondaryLanguage string`; `Resolve` copies it into the returned `config.Config`.

- [ ] **Step 1: Write the failing test**

Append to `core/internal/presets/resolve_test.go`:

```go
func TestResolve_ThreadsSecondaryLanguage(t *testing.T) {
	cfg := Resolve(Preset{}, EngineSecrets{Language: "en", SecondaryLanguage: "zh"})
	if cfg.SecondaryLanguage != "zh" {
		t.Errorf("Resolve SecondaryLanguage = %q, want \"zh\"", cfg.SecondaryLanguage)
	}
	if cfg.Language != "en" {
		t.Errorf("Resolve Language = %q, want \"en\"", cfg.Language)
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd core && go test ./internal/presets/...`
Expected: FAIL — `EngineSecrets` has no field `SecondaryLanguage`.

- [ ] **Step 3: Add the field and thread it**

In `core/internal/presets/resolve.go`, add to the `EngineSecrets` struct right after `Language` (line 25):

```go
	Language            string
	SecondaryLanguage   string
```

In `Resolve`, add to the `config.Config{...}` literal right after `Language: secrets.Language,` (line 63):

```go
		Language:            secrets.Language,
		SecondaryLanguage:   secrets.SecondaryLanguage,
```

- [ ] **Step 4: Update the two callers that build EngineSecrets**

In `core/cmd/libhowl/replay_export.go` (`secretsFromEngineCfg`), add after the `Language: e.cfg.Language,` line (~line 104):

```go
		Language:            e.cfg.Language,
		SecondaryLanguage:   e.cfg.SecondaryLanguage,
```

In `core/cmd/howl-cli/compare.go`, find the `presets.EngineSecrets{` literal (~line 136) and add a `SecondaryLanguage:` line mirroring its existing `Language:` line (use the same source value the `Language` field reads from — e.g. `cfg.SecondaryLanguage`).

- [ ] **Step 5: Run tests + build to verify they pass**

Run: `cd core && go test ./internal/presets/... && go build -tags whispercpp ./cmd/libhowl/ ./cmd/howl-cli/`
Expected: presets tests PASS; both commands build clean.

- [ ] **Step 6: Commit**

```bash
git add core/internal/presets/resolve.go core/internal/presets/resolve_test.go core/cmd/libhowl/replay_export.go core/cmd/howl-cli/compare.go
git commit -m "feat(presets): thread secondary_language through Resolve + callers"
```

---

### Task 3: Go — synthesized EN+ZH fixture + Tier-2 code-switch correctness test

**Files:**
- Create: `core/test/integration/gen-codeswitch-fixture.sh`
- Create (generated, committed): `core/test/integration/testdata/codeswitch-en-zh.wav`
- Create: `core/internal/transcribe/codeswitch_test.go`

**Interfaces:**
- Consumes: existing `transcribe.NewWhisperCpp`, `transcribe.WhisperOptions`, `transcribe.DictionaryPrompt`, and the existing `readWavMono16k` helper in `whisper_cpp_test.go` (same package).
- Produces: nothing other tasks depend on.

- [ ] **Step 1: Write the generator script**

Create `core/test/integration/gen-codeswitch-fixture.sh`:

```bash
#!/usr/bin/env bash
# Regenerates testdata/codeswitch-en-zh.wav: an English+Chinese code-switch
# utterance synthesized with macOS `say` (per-language voices) and normalized
# to 16 kHz mono 16-bit PCM WAV — whisper's required input format. Commit the
# resulting WAV so the test does not depend on which TTS voices a machine has.
#
# Usage: ./gen-codeswitch-fixture.sh   (override voices with EN_VOICE / ZH_VOICE)
set -euo pipefail
cd "$(dirname "$0")"
OUT="testdata/codeswitch-en-zh.wav"
EN_VOICE="${EN_VOICE:-Samantha}"
ZH_VOICE="${ZH_VOICE:-Meijia}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Segments: English … Chinese … English. Known content asserted by the test.
say -v "$EN_VOICE" -o "$TMP/1.aiff" "Let's schedule the"
say -v "$ZH_VOICE" -o "$TMP/2.aiff" "会议"
say -v "$EN_VOICE" -o "$TMP/3.aiff" "for tomorrow afternoon"

for i in 1 2 3; do
  afconvert "$TMP/$i.aiff" "$TMP/$i.wav" -f WAVE -d LEI16@16000 -c 1
done

# Concatenate with python stdlib `wave` (preinstalled with macOS CLT).
python3 - "$TMP/1.wav" "$TMP/2.wav" "$TMP/3.wav" "$OUT" <<'PY'
import sys, wave
*ins, out = sys.argv[1:]
o = None
for p in ins:
    with wave.open(p, 'rb') as w:
        if o is None:
            o = wave.open(out, 'wb'); o.setparams(w.getparams())
        o.writeframes(w.readframes(w.getnframes()))
o.close()
PY
echo "wrote $OUT"
```

Make it executable: `chmod +x core/test/integration/gen-codeswitch-fixture.sh`

- [ ] **Step 2: Generate the fixture**

Run: `core/test/integration/gen-codeswitch-fixture.sh`
Expected: prints `wrote testdata/codeswitch-en-zh.wav`; the WAV exists and is small (~100 KB). Verify: `ls -la core/test/integration/testdata/codeswitch-en-zh.wav`.

- [ ] **Step 3: Write the test**

Create `core/internal/transcribe/codeswitch_test.go`:

```go
//go:build whispercpp

package transcribe

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"unicode"
)

// TestWhisperCpp_CodeSwitch_EN_ZH proves the production config retains BOTH
// scripts: whisper anchored on English (primary) with the custom dictionary as
// the initial prompt still emits the Chinese term — exactly how build.go wires
// the live pipeline. Requires the multilingual large-v3 model; skips when
// absent (local/opt-in, not run in CI — see
// docs/superpowers/plans/2026-06-19-multilingual-codeswitch.md).
func TestWhisperCpp_CodeSwitch_EN_ZH(t *testing.T) {
	modelPath := os.ExpandEnv("$HOME/Library/Application Support/Howl/models/ggml-large-v3.bin")
	if _, err := os.Stat(modelPath); err != nil {
		t.Skipf("multilingual model not available at %s; download ggml-large-v3.bin to run this test", modelPath)
	}

	wavPath := filepath.Join("..", "..", "test", "integration", "testdata", "codeswitch-en-zh.wav")
	pcm, err := readWavMono16k(wavPath)
	if err != nil {
		t.Skipf("fixture unavailable (regenerate via core/test/integration/gen-codeswitch-fixture.sh): %v", err)
	}

	// Production parity: anchor on the English primary; the bilingual
	// dictionary primes the Chinese term via the initial prompt.
	w, err := NewWhisperCpp(WhisperOptions{
		ModelPath:     modelPath,
		Language:      "en",
		InitialPrompt: DictionaryPrompt([]string{"会议", "schedule"}),
	})
	if err != nil {
		t.Fatalf("NewWhisperCpp: %v", err)
	}
	defer w.Close()

	got, err := w.Transcribe(context.Background(), pcm)
	if err != nil {
		t.Fatalf("Transcribe: %v", err)
	}
	t.Logf("code-switch transcription: %q", got)

	// Han characters present → the English-anchored decode kept the second
	// script (robust to simplified/traditional and to whisper's word choice).
	hasHan := false
	for _, r := range got {
		if unicode.Is(unicode.Han, r) {
			hasHan = true
			break
		}
	}
	if !hasHan {
		t.Errorf("expected Han characters (code-switch retained), got %q", got)
	}

	// English structure retained too (not flipped wholesale to Chinese).
	lower := strings.ToLower(got)
	if !strings.Contains(lower, "schedule") &&
		!strings.Contains(lower, "tomorrow") &&
		!strings.Contains(lower, "afternoon") {
		t.Errorf("expected an English keyword (schedule/tomorrow/afternoon), got %q", got)
	}
}
```

- [ ] **Step 4: Run the test (it should PASS here — large-v3 is present)**

Run: `cd core && go test -tags whispercpp -run TestWhisperCpp_CodeSwitch_EN_ZH ./internal/transcribe/... -v`
Expected: PASS, with a log line showing both `会议` and the English words.

**If `hasHan` fails** (Han not retained even with the prompt): do NOT loosen the assertion. This contradicts the validation spike and is a real signal — stop and report it as a concern (the fallback would be `Language: "auto"`, a design change needing sign-off). If only the *exact* word differs (e.g. whisper picks different Chinese characters), that's fine — the test asserts "any Han", not a specific string.

- [ ] **Step 5: Commit (including the generated WAV)**

```bash
chmod +x core/test/integration/gen-codeswitch-fixture.sh
git add core/test/integration/gen-codeswitch-fixture.sh core/test/integration/testdata/codeswitch-en-zh.wav core/internal/transcribe/codeswitch_test.go
git commit -m "test(transcribe): synthesized EN+ZH code-switch correctness fixture + test"
```

---

### Task 4: Swift HowlCore — `UserSettings.secondaryLanguage`

**Files:**
- Modify: `mac/Packages/HowlCore/Sources/HowlCore/Storage/SettingsStore.swift`
- Test: `mac/Packages/HowlCore/Tests/HowlCoreTests/UserSettingsSecondaryLanguageTests.swift` (create)

**Interfaces:**
- Produces: `UserSettings.secondaryLanguage: String` (default `"none"`).

- [ ] **Step 1: Write the failing test**

Create `mac/Packages/HowlCore/Tests/HowlCoreTests/UserSettingsSecondaryLanguageTests.swift`:

```swift
import Testing
import Foundation
@testable import HowlCore

@Suite struct UserSettingsSecondaryLanguageTests {
    @Test func defaultsToNone() {
        #expect(UserSettings().secondaryLanguage == "none")
    }

    @Test func roundTripsThroughCodable() throws {
        var s = UserSettings()
        s.secondaryLanguage = "zh"
        let data = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(UserSettings.self, from: data)
        #expect(back.secondaryLanguage == "zh")
    }

    @Test func decodesMissingKeyAsNone() throws {
        // Legacy stored settings (no secondary_language key) must default.
        let json = #"{"whisperModelSize":"small","language":"en"}"#.data(using: .utf8)!
        let s = try JSONDecoder().decode(UserSettings.self, from: json)
        #expect(s.secondaryLanguage == "none")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd mac/Packages/HowlCore && swift test --filter UserSettingsSecondaryLanguageTests`
Expected: FAIL — `secondaryLanguage` is not a member of `UserSettings`.

- [ ] **Step 3: Add the field**

In `SettingsStore.swift`, add the stored property after `language` (line 5):

```swift
    public var language: String
    /// Optional second language for code-switch dictation. "none" (default)
    /// means single-language behavior. When set, the engine loads the
    /// multilingual large model and the dictionary primes both scripts.
    public var secondaryLanguage: String
```

Add the init parameter after `language: String = "en",` (line 44) and its assignment after `self.language = language` (line 61):

```swift
        language: String = "en",
        secondaryLanguage: String = "none",
```
```swift
        self.language = language
        self.secondaryLanguage = secondaryLanguage
```

Add the decode after the `language` decode (line 81):

```swift
        language = try c.decodeIfPresent(String.self, forKey: .language) ?? "en"
        secondaryLanguage = try c.decodeIfPresent(String.self, forKey: .secondaryLanguage) ?? "none"
```

Add `secondaryLanguage` to `CodingKeys` (line 99):

```swift
        case whisperModelSize, language, secondaryLanguage, disableNoiseSuppression
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd mac/Packages/HowlCore && swift test --filter UserSettingsSecondaryLanguageTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add mac/Packages/HowlCore/Sources/HowlCore/Storage/SettingsStore.swift mac/Packages/HowlCore/Tests/HowlCoreTests/UserSettingsSecondaryLanguageTests.swift
git commit -m "feat(settings): add UserSettings.secondaryLanguage (default none)"
```

---

### Task 5: Swift HowlCore — `EngineConfig.secondaryLanguage` (JSON `secondary_language`)

**Files:**
- Modify: `mac/Packages/HowlCore/Sources/HowlCore/Bridge/EngineConfig.swift`
- Test: `mac/Packages/HowlCore/Tests/HowlCoreTests/EngineConfigSecondaryLanguageTests.swift` (create)

**Interfaces:**
- Consumes: `UserSettings.secondaryLanguage` (Task 4).
- Produces: `EngineConfig.secondaryLanguage: String` encoded as JSON `secondary_language`; the `init(settings:apiKey:paths:)` factory maps it.

- [ ] **Step 1: Write the failing test**

Create `mac/Packages/HowlCore/Tests/HowlCoreTests/EngineConfigSecondaryLanguageTests.swift`:

```swift
import Testing
import Foundation
@testable import HowlCore

@Suite struct EngineConfigSecondaryLanguageTests {
    private func paths() -> EnginePaths {
        EnginePaths(
            whisperModelPath: "/m.bin", resolvedWhisperSize: "large",
            deepFilterModelPath: "", voiceProfileDir: "",
            tseModelPath: "", speakerEncoderPath: "", onnxLibPath: "",
            tseAssetsPresent: false)
    }

    @Test func encodesSecondaryLanguageKey() throws {
        var s = UserSettings()
        s.secondaryLanguage = "zh"
        let cfg = EngineConfig(settings: s, apiKey: "k", paths: paths())
        let json = try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(cfg)) as! [String: Any]
        #expect(json["secondary_language"] as? String == "zh")
    }

    @Test func factoryMapsFromSettings() {
        var s = UserSettings()
        s.secondaryLanguage = "ko"
        let cfg = EngineConfig(settings: s, apiKey: "k", paths: paths())
        #expect(cfg.secondaryLanguage == "ko")
    }

    @Test func decodesMissingKeyAsNone() throws {
        let json = #"{"whisper_model_path":"/m","whisper_model_size":"small","language":"en","disable_noise_suppression":false,"deep_filter_model_path":"","llm_provider":"anthropic","llm_model":"x","llm_api_key":"","custom_dict":[]}"#.data(using: .utf8)!
        let cfg = try JSONDecoder().decode(EngineConfig.self, from: json)
        #expect(cfg.secondaryLanguage == "none")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd mac/Packages/HowlCore && swift test --filter EngineConfigSecondaryLanguageTests`
Expected: FAIL — `secondaryLanguage` not a member of `EngineConfig`.

- [ ] **Step 3: Add the field, codable, and factory wiring**

In `EngineConfig.swift`:

Property after `language` (line 8):
```swift
    public var language: String
    public var secondaryLanguage: String
```

Init parameter after `language: String,` (line 46) and assignment after `self.language = language` (line 68):
```swift
        language: String,
        secondaryLanguage: String = "none",
```
```swift
        self.language = language
        self.secondaryLanguage = secondaryLanguage
```

Encode after the `language` encode (line 93):
```swift
        try c.encode(language, forKey: .language)
        try c.encode(secondaryLanguage, forKey: .secondaryLanguage)
```

Decode after the `language` decode (line 127):
```swift
        self.language = try c.decode(String.self, forKey: .language)
        self.secondaryLanguage = try c.decodeIfPresent(String.self, forKey: .secondaryLanguage) ?? "none"
```

CodingKeys after `case language` (line 151):
```swift
        case language
        case secondaryLanguage = "secondary_language"
```

Factory: in `init(settings:apiKey:paths:)`, add after `language: settings.language,` (line 226):
```swift
            language: settings.language,
            secondaryLanguage: settings.secondaryLanguage,
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd mac/Packages/HowlCore && swift test --filter EngineConfigSecondaryLanguageTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add mac/Packages/HowlCore/Sources/HowlCore/Bridge/EngineConfig.swift mac/Packages/HowlCore/Tests/HowlCoreTests/EngineConfigSecondaryLanguageTests.swift
git commit -m "feat(bridge): add EngineConfig.secondary_language + factory wiring"
```

---

### Task 6: Swift HowlCore — `WhisperModelSelection` (the testable model rule)

**Files:**
- Create: `mac/Packages/HowlCore/Sources/HowlCore/Bridge/WhisperModelSelection.swift`
- Test: `mac/Packages/HowlCore/Tests/HowlCoreTests/WhisperModelSelectionTests.swift` (create)

**Interfaces:**
- Produces: `WhisperModelSelection.needsMultilingual(primary:secondary:) -> Bool`, `WhisperModelSelection.effectiveSize(requested:primary:secondary:) -> String`, `WhisperModelSelection.effectiveSecondary(primary:secondary:) -> String`, `WhisperModelSelection.noSecondary` (`"none"`).
- Consumes: nothing.

- [ ] **Step 1: Write the failing test**

Create `mac/Packages/HowlCore/Tests/HowlCoreTests/WhisperModelSelectionTests.swift`:

```swift
import Testing
@testable import HowlCore

@Suite struct WhisperModelSelectionTests {
    @Test func englishOnlyNeedsNoMultilingual() {
        #expect(!WhisperModelSelection.needsMultilingual(primary: "en", secondary: "none"))
        #expect(WhisperModelSelection.effectiveSize(requested: "small", primary: "en", secondary: "none") == "small")
    }

    @Test func secondaryForcesLarge() {
        #expect(WhisperModelSelection.needsMultilingual(primary: "en", secondary: "zh"))
        #expect(WhisperModelSelection.effectiveSize(requested: "small", primary: "en", secondary: "zh") == "large")
    }

    // The latent bug: non-English primary on a small (.en-only) size.
    @Test func nonEnglishPrimaryForcesLarge() {
        #expect(WhisperModelSelection.needsMultilingual(primary: "zh", secondary: "none"))
        #expect(WhisperModelSelection.effectiveSize(requested: "small", primary: "zh", secondary: "none") == "large")
    }

    @Test func autoPrimaryForcesLarge() {
        #expect(WhisperModelSelection.effectiveSize(requested: "small", primary: "auto", secondary: "none") == "large")
    }

    @Test func secondaryEqualToPrimaryCollapsesToNone() {
        #expect(WhisperModelSelection.effectiveSecondary(primary: "en", secondary: "en") == "none")
        #expect(!WhisperModelSelection.needsMultilingual(primary: "en", secondary: "en"))
        #expect(WhisperModelSelection.effectiveSize(requested: "small", primary: "en", secondary: "en") == "small")
    }

    @Test func largeStaysLarge() {
        #expect(WhisperModelSelection.effectiveSize(requested: "large", primary: "en", secondary: "none") == "large")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd mac/Packages/HowlCore && swift test --filter WhisperModelSelectionTests`
Expected: FAIL — `WhisperModelSelection` is undefined.

- [ ] **Step 3: Implement the helper**

Create `mac/Packages/HowlCore/Sources/HowlCore/Bridge/WhisperModelSelection.swift`:

```swift
import Foundation

/// Pure model-selection logic shared by the app's `ModelPaths` and tested in
/// HowlCore. Code-switch / non-English dictation needs whisper's multilingual
/// weights; the bundled tiny/base/small/medium are English-only `.en` builds,
/// so any multilingual need forces the large multilingual model
/// (`ggml-large-v3.bin`).
public enum WhisperModelSelection {
    /// Sentinel meaning "no secondary language".
    public static let noSecondary = "none"

    /// Collapses the degenerate `secondary == primary` case to "none" — a
    /// language can't be its own secondary.
    public static func effectiveSecondary(primary: String, secondary: String) -> String {
        secondary == primary ? noSecondary : secondary
    }

    /// True when the configuration needs multilingual weights: a non-English
    /// primary (including "auto"), or any secondary language set.
    public static func needsMultilingual(primary: String, secondary: String) -> Bool {
        if primary != "en" { return true }
        return effectiveSecondary(primary: primary, secondary: secondary) != noSecondary
    }

    /// The model size to actually load. Forces "large" (the only multilingual
    /// build Howl ships) when multilingual weights are needed; otherwise the
    /// user's requested size is honored.
    public static func effectiveSize(requested: String, primary: String, secondary: String) -> String {
        needsMultilingual(primary: primary, secondary: secondary) ? "large" : requested
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd mac/Packages/HowlCore && swift test --filter WhisperModelSelectionTests`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add mac/Packages/HowlCore/Sources/HowlCore/Bridge/WhisperModelSelection.swift mac/Packages/HowlCore/Tests/HowlCoreTests/WhisperModelSelectionTests.swift
git commit -m "feat(bridge): WhisperModelSelection — force large-v3 when multilingual"
```

---

### Task 7: App — EngineCoordinator loads the effective (multilingual) model

**Files:**
- Modify: `mac/Howl/Engine/EngineCoordinator.swift:564-582` (`resolveEnginePaths`) and the `applyConfig` log at line 550.

**Interfaces:**
- Consumes: `WhisperModelSelection.effectiveSize` (Task 6), `UserSettings.secondaryLanguage` (Task 4).
- Produces: nothing other tasks depend on.

(No unit test — app target has no test host. Verified by build + the `applyConfig` log.)

- [ ] **Step 1: Use the effective size when resolving the model**

In `resolveEnginePaths(for:)`, replace the first line (currently `let resolvedSize = ModelPaths.availableSize(preferred: settings.whisperModelSize)`, line 565) with:

```swift
        // Code-switch / non-English dictation needs the multilingual model;
        // WhisperModelSelection forces "large" when so, otherwise honors the
        // user's chosen size.
        let requestedSize = WhisperModelSelection.effectiveSize(
            requested: settings.whisperModelSize,
            primary: settings.language,
            secondary: settings.secondaryLanguage)
        let resolvedSize = ModelPaths.availableSize(preferred: requestedSize)
```

Leave the rest of the function (modelPath, fallback log comparing against `settings.whisperModelSize`, `EnginePaths(...)`) unchanged — comparing the resolved size against the user's requested size still correctly reports a fallback when the multilingual model isn't downloaded yet.

- [ ] **Step 2: Add secondary to the applyConfig log (observability)**

In `applyConfig` (line 550), extend the existing `log.info(...)` string by adding ` sec=\(settings.secondaryLanguage, privacy: .public)` immediately after the `lang=\(settings.language, privacy: .public)` interpolation.

- [ ] **Step 3: Build the app to verify it compiles**

Run: `cd mac && make build`
Expected: build succeeds.

- [ ] **Step 4: Commit**

```bash
git add mac/Howl/Engine/EngineCoordinator.swift
git commit -m "feat(engine): load multilingual model when secondary language set"
```

---

### Task 8: App — GeneralTab primary/secondary pickers + limitations copy + effective-size status

**Files:**
- Modify: `mac/Howl/UI/Settings/GeneralTab.swift`

**Interfaces:**
- Consumes: `WhisperModelSelection.effectiveSize` (Task 6), `UserSettings.secondaryLanguage` (Task 4).

(No unit test — app target has no test host. Verified by build + manual UI check.)

- [ ] **Step 1: Add the secondary-language option list**

After the `languages` constant (line 38), add:

```swift
    private let secondaryLanguages = ["none", "en", "es", "fr", "de", "it", "pt", "ja", "ko", "zh"]
```

- [ ] **Step 2: Add an `effectiveModelSize` computed property**

Add near the other private helpers (e.g. just above `modelStatusRow`, ~line 205):

```swift
    /// The model size the engine will actually load given the language
    /// settings — "large" when multilingual is needed (so the status row and
    /// download target the model that will really be used).
    private var effectiveModelSize: String {
        WhisperModelSelection.effectiveSize(
            requested: settings.whisperModelSize,
            primary: settings.language,
            secondary: settings.secondaryLanguage)
    }
```

- [ ] **Step 3: Rename the primary picker and add the secondary picker + caption**

Replace the existing language `Picker` block (lines 69-71):

```swift
            Picker("Language", selection: $settings.language) {
                ForEach(languages, id: \.self) { Text($0).tag($0) }
            }
```

with:

```swift
            Picker("Primary language", selection: $settings.language) {
                ForEach(languages, id: \.self) { Text($0).tag($0) }
            }
            Picker("Secondary language", selection: $settings.secondaryLanguage) {
                ForEach(secondaryLanguages, id: \.self) { lang in
                    Text(lang == "none" ? "None" : lang).tag(lang)
                }
            }
            if settings.secondaryLanguage != "none" {
                Text("Code-switching is best-effort — whisper transcribes each window as one language. For best results, add your common terms in both languages to the Dictionary. Requires the large multilingual model (3.1 GB).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
```

- [ ] **Step 4: Point the model status row + download at the effective size**

In `modelStatusRow`, change line 207 from `let size = settings.whisperModelSize` to:

```swift
        let size = effectiveModelSize
```

In `activeFallbackSize`, change line 261 from `let preferred = settings.whisperModelSize` to:

```swift
        let preferred = effectiveModelSize
```

(`modelStatusRow` already calls `runDownload(size: size)` and builds paths from `size`, so both now target the multilingual model automatically.)

- [ ] **Step 5: Build the app to verify it compiles**

Run: `cd mac && make build`
Expected: build succeeds.

- [ ] **Step 6: Manual smoke check**

Launch (`cd mac && make run`), open Settings → General. Confirm: a "Secondary language" picker defaulting to "None"; selecting "zh" reveals the limitations caption and the model status row switches to the Large model (offering download if large-v3 is absent).

- [ ] **Step 7: Commit**

```bash
git add mac/Howl/UI/Settings/GeneralTab.swift
git commit -m "feat(ui): primary/secondary language pickers + code-switch guidance"
```

---

## Self-Review

**Spec coverage:**
- Settings & persistence (primary kept as `language`, new `secondaryLanguage`/`secondary_language` default `none`) → Tasks 1, 4, 5.
- Engine mechanism (anchor primary + dictionary prompt, no new decode branch; secondary threaded for observability) → existing `build.go` (unchanged) + Tasks 1 (`LogSummary`), 2 (presets), 7 (log).
- Model strategy + latent-bug fix (`needsMultilingual` → large-v3) → Tasks 6 (rule), 7 (engine path), 8 (UI/download).
- UI (primary/secondary pickers, limitations caption, large-v3 status) → Task 8.
- Compare/replay parity (secondary through `presets.Resolve` + callers) → Task 2.
- Tier-1 wiring tests → Tasks 1, 2, 4, 5, 6. Tier-2 synthesized e2e (local/opt-in, skip in CI) → Task 3.

**Placeholder scan:** No TBD/TODO; every code step has complete code. The one non-literal instruction (compare.go's `EngineSecrets` literal in Task 2 Step 4) names the exact field to mirror and the file/line — concrete, because the surrounding literal's source value is local to that file.

**Type consistency:** `secondaryLanguage` (Swift) ↔ `secondary_language` (JSON) ↔ `SecondaryLanguage` (Go) consistent across Tasks 1/2/4/5. `WhisperModelSelection.effectiveSize(requested:primary:secondary:)` signature identical in its definition (Task 6) and both call sites (Tasks 7, 8). `LogSummary()` defined in Task 1, used in Task 1 Step 4. `needsMultilingual`/`effectiveSecondary`/`noSecondary` defined once (Task 6).
