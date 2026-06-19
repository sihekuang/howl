# Multilingual code-switch support (primary + secondary language)

**Date:** 2026-06-19
**Status:** Design — approved, pending spec review
**Feature branch (suggested):** `feat/multilingual-codeswitch`

## Problem

A bilingual user dictates with **word-level code-switching** inside a single
utterance — e.g. *"let's 一起 go to the 会议"* — and wants **both** languages
transcribed correctly in one result. Today Howl forces a single language and,
worse, the non-`large` model sizes are English-only `.en` builds, so selecting
"Chinese" silently loads a model that physically cannot emit Chinese.

## Feasibility verdict

**Possible as a configurable best-effort feature — not as guaranteed
word-level switching.** Whisper conditions each ~30-second decode on a *single*
language token; there is no native "two languages at once" mode. However:

- `large-v3` is trained on code-switched data and *does* emit mixed scripts.
- Whisper's vocabulary is shared (byte-level BPE) across all scripts, so a
  decoder anchored on English can still emit Chinese/Korean tokens.
- The strongest controllable lever is the **`initial_prompt`** — and Howl
  already feeds the custom dictionary into the initial prompt
  (`transcribe.DictionaryPrompt`, shipped in 0.10.0). A **bilingual dictionary
  becomes the code-switch primer.**

So this design is intentionally small: it rides the existing language and
initial-prompt plumbing, adds one new setting, fixes a latent model-selection
bug, and adds a synthesized end-to-end correctness test.

## Scope

**In scope**
- A user-configurable **secondary language** (default `none`), persisted in
  preferences alongside the existing **primary language** (the current
  `language` field, default `en`).
- Anchor-on-primary engine behavior with the dictionary acting as the bilingual
  primer when a secondary is set.
- Model selection: require `ggml-large-v3` whenever a multilingual model is
  needed; fix the latent `.en`-only bug.
- Two-tier testing, including a **synthesized** bilingual fixture for a real
  end-to-end correctness check.

**Out of scope (YAGNI for v1)**
- Chunk → per-segment language detect → merge (Approach C below). Heavy core
  rework; still misses word-level switches; revisit only if v1 proves
  insufficient.
- Smaller multilingual model variants (`ggml-small.bin`, `ggml-medium.bin`).
  One model rule (`large-v3`) for v1; smaller variants are a later size/speed
  optimization.
- A hardcoded per-language priming seed. The dictionary *is* the seed.
- Translate-to-English mode (whisper's `translate` flag).
- Three-or-more simultaneous languages.

## Approaches considered

**A — Anchor on primary, prime the secondary (CHOSEN).**
`whisper.language = primary`; when a secondary is set, load a multilingual
model and let the existing dictionary `initial_prompt` carry both scripts.
One decode pass, no new Go decode logic, predictable (keeps the
dominant-language structure intact), reuses shipped infrastructure. Quality is
model-bounded — strong for different-script pairs (EN+ZH, EN+KO), weaker for
same-script pairs (EN+ES).

**B — Auto-detect, no anchor.** `whisper.language = "auto"` when a secondary is
set. Rejected: for short dictations whisper picks **one** language for the whole
window, so a mostly-English line with a couple of Chinese words can flip
entirely to Chinese (or drop the Chinese). Worse for the target case. (Kept as a
documented fallback toggle if real-world results favor it.)

**C — Chunk → per-segment detect → merge.** Rejected for v1: significant core
rework, added latency, boundary artifacts, fragile merge, and it still misses
word-level mid-phrase switches.

## Design

### 1. Settings & persistence

Keep the existing `language` field as the **primary** language. Add one field.

- `mac/.../Storage/SettingsStore.swift` (`UserSettings`):
  - existing `language: String` — default `"en"` (unchanged); now labeled
    "Primary language" in the UI.
  - **new** `secondaryLanguage: String` — default `"none"`,
    `decodeIfPresent(..) ?? "none"` so existing stored settings migrate
    cleanly. Persists to UserDefaults like every other field.
- `mac/.../Bridge/EngineConfig.swift`:
  - **new** `secondaryLanguage: String`, encoded/decoded as JSON key
    `secondary_language`; populated from `settings.secondaryLanguage` in the
    `init(settings:apiKey:paths:)` factory (alongside the existing
    `language: settings.language`).
- `core/internal/config/config.go` (`config.Config`):
  - **new** `SecondaryLanguage string \`json:"secondary_language"\``. In
    `WithDefaults`, empty → `"none"`. (Primary `Language` default behavior is
    unchanged.)
- `core/internal/presets/resolve.go`: pass `SecondaryLanguage: secrets.Language`
  is **not** correct — secondary comes from its own field. Thread
  `secrets.SecondaryLanguage` (new on `EngineSecrets`) into the resolved
  `config.Config`, mirroring how `Language` is threaded at `resolve.go:63`.
  Secondary, like primary, is a **global** setting, not per-preset.

### 2. Engine mechanism (Approach A)

- `core/internal/pipeline/build/build.go` already builds:
  ```go
  transcribe.NewWhisperCpp(transcribe.WhisperOptions{
      ModelPath:     cfg.WhisperModelPath,
      Language:      cfg.Language,                       // primary = anchor
      InitialPrompt: transcribe.DictionaryPrompt(cfg.CustomDict),
  })
  ```
  This is **already the desired behavior**. No new decode branching is required:
  - Secondary = `none` → primary is forced exactly as today (zero regression).
  - Secondary set → primary stays the anchor; the dictionary prompt (which the
    user populates with terms in both scripts) primes the secondary script.
- `cfg.SecondaryLanguage` is threaded through for **observability** and future
  use. Log it next to the existing dictionary log in
  `core/cmd/libhowl/exports.go` (the `howl_configure` log added in 0.10.0), so
  `/tmp/howl.log` shows e.g.
  `howl_configure: primary=en secondary=zh, 4 dictionary term(s): [...]`.
- whisper.cpp imposes no hard script filter on a set language token
  (`whisper_cpp.go:137-139` only sets `params.language`); other-script tokens
  remain reachable. No change needed there.

### 3. Model strategy + latent-bug fix

Model-file selection is Swift-side (`mac/Howl/AppDelegate.swift`). Introduce a
single rule:

```
needsMultilingual = (primary != "en") || (secondaryLanguage != "none")
```

- `whisperModelFilename(size:)` (currently forces `ggml-\(size).en.bin` for all
  sizes except `large`): when `needsMultilingual`, resolve to
  `ggml-large-v3.bin` regardless of the chosen size. Otherwise unchanged.
  - This satisfies "require large-v3 for code-switch" **and** fixes the latent
    bug where picking `ja/ko/zh/es/…` with a non-`large` size loaded an
    English-only model.
- `whisperModel(size:)` / `availableSize(preferred:)` consume
  `whisperModelFilename`, so they inherit the rule automatically.
- **Download/availability UX:** `large-v3` is 3.1 GB. When the user enables a
  secondary language (or a non-English primary) and `ggml-large-v3.bin` is
  absent, trigger the **existing** model-download path and surface a status note
  in `modelStatusRow` ("Code-switch needs the large multilingual model (3.1 GB)
  — downloading…"). Until it lands, `availableSize` falls back to the current
  model, so dictation keeps working in the primary language.

### 4. UI (`mac/Howl/UI/Settings/GeneralTab.swift`)

- Rename the existing "Language" picker to **"Primary language"** (bound to
  `settings.language`; drop `"auto"` from this list — primary is an explicit
  anchor, default `en`).
- Add a **"Secondary language"** picker bound to `settings.secondaryLanguage`,
  options `["none", "en", "es", "fr", "de", "it", "pt", "ja", "ko", "zh"]`
  (full set minus `auto`, since secondary is never an anchor), default `none`,
  labeled "None" for the `none` tag. If `secondaryLanguage == language`
  (same as primary), treat it as `none` — a language can't be its own
  secondary.
- When `secondaryLanguage != "none"`, show a limitations caption (mirroring the
  STT-prompt-budget caption pattern from 0.10.0):
  > Code-switching is best-effort — whisper transcribes each window as one
  > language. For best results, add your common terms in **both** languages to
  > the Dictionary, and note that the large multilingual model (3.1 GB) is
  > required.

### Data flow (summary)

```
UserSettings{language(primary), secondaryLanguage}
  → EngineConfig{language, secondary_language}
  → config.Config{Language, SecondaryLanguage}
  → build.go: WhisperOptions{Language: primary,
                             InitialPrompt: DictionaryPrompt(bilingual dict)}
  ↘ AppDelegate model selection: needsMultilingual → ggml-large-v3.bin
```

## Testing

Two tiers (decision: Tier-2 is local/opt-in, skipped in CI).

### Tier 1 — wiring tests (always in CI; no model, no audio)

- **Go** (`core/internal/config`, `core/internal/presets`): `secondary_language`
  parses from JSON; empty → `"none"` via `WithDefaults`; `presets.Resolve`
  threads `SecondaryLanguage` from secrets into `config.Config`.
- **Go** (`core/cmd/libhowl` or a focused unit): the configure log line includes
  the secondary language and dictionary terms.
- **Swift** (`HowlCore` SwiftPM tests): `UserSettings` encode/decode round-trip
  including `secondaryLanguage` with the `?? "none"` default; `EngineConfig`
  emits `secondary_language`; **`whisperModelFilename` returns
  `ggml-large-v3.bin` when `needsMultilingual` and the `.en` build otherwise**
  (the bug-fix guard). `whisperModelFilename` / the `needsMultilingual`
  predicate must be reachable from the `HowlCore` test target (move/expose the
  helper if it currently lives only in the app target).

These run on every PR exactly like today's `test.yml` Go-whispercpp + Swift
checks.

### Tier 2 — synthesized end-to-end correctness test (local/opt-in)

Proves code-switch actually works through the real `whispercpp` pipeline.

- **Synthesis (committed generator + committed fixture):**
  - `core/test/integration/gen-codeswitch-fixture.sh`: uses macOS `say` with
    per-language voices — an English voice for the English words and a Chinese
    voice (e.g. `Ting-Ting`) for the Chinese words — stitched into one clip,
    then `afconvert` to **16 kHz mono PCM WAV** (whisper's required format).
  - Commit the resulting fixture
    `core/test/integration/testdata/codeswitch-en-zh.wav` (~100 KB), following
    the committed-small-clip convention in `core/CLAUDE.md` and the existing
    `hello-world.wav`. Committing the WAV decouples the test from which TTS
    voices are installed on a given machine.
  - The known transcript content is recorded in the test (English keyword +
    expected Chinese characters).
- **Test** (`core/internal/transcribe/codeswitch_test.go`, `//go:build
  whispercpp`):
  - Mirror `whisper_cpp_test.go`: `t.Skipf` when `ggml-large-v3.bin` is absent
    (`$HOME/Library/Application Support/Howl/models/ggml-large-v3.bin`) and when
    the fixture can't be read; reuse the existing `readWavMono16k` helper.
  - Build `NewWhisperCpp(WhisperOptions{ModelPath: large-v3, Language: "en",
    InitialPrompt: DictionaryPrompt([...bilingual terms...])})`, transcribe the
    fixture.
  - **Assert (tolerant):** the transcript contains the expected Chinese
    characters (e.g. `会议`) **and** the English keyword. Tolerant `contains`
    matching, not exact equality — it is TTS audio and whisper output varies.
  - Log the full transcript (`t.Logf`) for manual inspection.
- **Relation to the eval harness (`core/CLAUDE.md`):** this is a recognition
  **coverage** check (does the pipeline retain both scripts), not an
  isolation/SNR question — there is no interferer axis, so the SNR-sweep
  machinery does not apply. It still follows the harness conventions: committed
  small fixture, licensed source (macOS system TTS), wired into a `_test.go`.

## Risks / open notes

- **Code-switch quality is model-bounded.** large-v3 + bilingual prompt is the
  best official-model path; word-level switching may still be missed. The UI
  copy sets this expectation honestly.
- **Same-script pairs (EN+ES/FR/…)** benefit least — whisper tends to collapse
  to one language when scripts overlap. The feature is most valuable for
  different-script pairs.
- **CI cannot run Tier 2** (3.1 GB model). Tier 1 guards wiring on every PR;
  Tier 2 is the local proof. A future option (documented, not built) is a
  cached-model nightly/manual CI job.
- **`auto` fallback:** if real-world results show anchor-on-primary is too rigid
  for secondary-dominant utterances, flipping the secondary-set case to
  `language = "auto"` is a one-line change behind the same setting.
