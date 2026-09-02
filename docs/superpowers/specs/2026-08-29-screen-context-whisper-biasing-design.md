# Screen Context → Whisper Biasing

**Date:** 2026-08-29
**Status:** Approved

## Problem

Whisper mis-transcribes exactly the words the user cares most about: product
names, code identifiers, acronyms, and people's names. The custom dictionary
already biases Whisper toward a *static* list of such terms via
`initial_prompt`, but it cannot know that the user is currently looking at a Go
file full of `SpeakerGate` and `DeepFilterNet`, or an email thread about a
person whose name is not in the dictionary.

The context is on screen. This feature reads it and feeds the useful part into
Whisper's `initial_prompt`, without degrading the dictionary feature that
already ships and without blowing Whisper's very small prompt budget.

## Scope

**In scope:** improving the *dictation* (ASR) side only.

**Explicitly out of scope:** the LLM cleanup stage is untouched. Its provider,
model, prompt template, and behaviour do not change. An LLM appears in this
design solely as a *keyword extractor*; the only output of this entire
subsystem is a short comma-separated term list entering
`whisper_full_params.initial_prompt`.

## Decisions

| Question | Decision |
|---|---|
| How to read on-screen text | Accessibility API first; screenshot + Vision OCR as fallback |
| How much screen | Focused window only |
| How keywords are extracted | LLM, reusing the active cleanup provider/model |
| When capture happens | On window focus change, so keywords are hot before PTT |
| Enablement | Global toggle, default ON |
| Sensitive windows | Built-in bundle-ID denylist + user additions |
| Trigger throttling | 800 ms focus dwell debounce + content-hash cache |
| Extractor failure | Silent fallback to dictionary-only |

Two supporting decisions were made from converging external evidence and are
recorded in `docs/decisions.md`: the OCR engine (Apple Vision
`VNRecognizeTextRequest`) and the prompt-budget policy (hard 224-token cap,
dictionary keeps priority).

## The Budget Problem

This is the core correctness concern and it drives the rest of the design.

`transcribe.MaxInitialPromptLen = 896` bytes is currently justified as "≈224
tokens" at roughly 4 bytes per token. That ratio holds for English prose. It
does **not** hold for the content this feature adds: rare jargon,
`CamelCaseIdentifiers`, and acronyms tokenize at roughly 1.5–3 bytes per token,
so 896 bytes of dense keywords can be **300–450 tokens**.

Whisper accepts only 224 prompt tokens and silently keeps the **last** 224,
discarding earlier tokens with no error. Under a byte-only cap, an oversized
prompt would therefore silently drop its *head* — and the head is the user's
custom dictionary. Adding screen keywords on top of a byte-only bound would
quietly regress the shipping dictionary feature.

**Resolution:** measure the composed prompt with `whisper_token_count(ctx,
text)` — already present in the `whisper.h` we link — and trim to ≤224 tokens
by dropping whole terms from the tail. The 896-byte bound is retained as a
cheap pre-filter; the token count is the authority.

**Ordering:** dictionary terms are composed first, screen keywords second. Both
truncation paths (byte pre-bound and token trim) drop from the tail, so
overflow always sacrifices screen keywords and never dictionary terms.

**Screen sub-cap:** screen keywords are additionally capped at **96 tokens** and
24 terms, so a noisy window cannot flood the prompt even when the dictionary is
empty. The cap is expressed and enforced in *tokens* during the token-trim
pass, for the same reason the total cap is: a byte figure would misestimate
jargon. `MaxScreenPromptLen = 384` bytes exists only as a cheap pre-filter that
runs before a whisper context is available, and is intentionally loose — it
never substitutes for the token cap. External sources are unanimous that
oversized `initial_prompt` values
induce hallucinated words — text appearing in the transcript that was never
spoken — so the design deliberately does not fill the available window.

## Data Flow

```
window focus change
  └─ debounce 800 ms dwell               (alt-tabbing through windows costs nothing)
  └─ bundle-ID denylist check            (bail before reading anything)
  └─ WindowTextReader
       ├─ AX walk of focused window      (fast path, no new permission)
       └─ if < 200 chars → SCScreenshotManager + Vision OCR
  └─ normalize + hash → cache hit? ──yes──► howl_set_screen_keywords(cached)
       │ no
  └─ howl_extract_keywords(text)         (Go; active cleanup provider; 5 s timeout)
       └─ LLM returns terms → sanitize → howl_set_screen_keywords()

PTT press → howl_start_capture
  └─ compose dictionary ++ screen keywords → token-trim → whisper initial_prompt
```

**PTT never waits.** If extraction has not finished, dictation proceeds with the
dictionary alone. The feature can only ever add context, never delay a
dictation.

## Go Core Changes

### `internal/transcribe/prompt.go`

Add composition that is pure and independently testable:

```go
// MaxScreenPromptLen is a loose byte pre-filter on the screen-derived
// portion of the prompt, applied before a whisper context is available.
// The authoritative bound is MaxScreenPromptTokens, enforced during the
// token-trim pass in SetContextPrompt.
const MaxScreenPromptLen = 384

// MaxScreenPromptTokens caps the screen-derived portion of the 224-token
// prompt window, leaving the majority for the custom dictionary.
const MaxScreenPromptTokens = 96

// ContextPrompt composes the whisper initial prompt from the custom
// dictionary and screen-derived keywords. Dictionary terms come first so
// tail truncation sacrifices screen keywords, never dictionary terms.
// Screen terms are deduped case-insensitively against the dictionary and
// bounded to MaxScreenPromptLen; the whole result is bounded to
// MaxInitialPromptLen. Returns the prompt plus the screen terms that
// survived truncation — the latter is what gets recorded in the session
// manifest, so the manifest reflects what whisper actually saw rather
// than what was offered.
func ContextPrompt(dictTerms, screenTerms []string) (string, []string)
```

`DictionaryPrompt` remains for callers with no screen context (`replay`, and
`build.FromOptions` at construction time).

### `internal/transcribe/whisper_cpp.go`

`WhisperCpp` gains a mutex-guarded prompt setter that applies the *exact* token
bound against the loaded model's vocabulary:

```go
// SetContextPrompt composes dictionary + screen terms and trims the result
// to whisper's real 224-token prompt window, measured with
// whisper_token_count against this model's vocab. Whole terms are dropped
// from the tail until the prompt fits.
func (w *WhisperCpp) SetContextPrompt(dictTerms, screenTerms []string)
```

Exposed to `pipeline` as an optional interface, mirroring the existing
`StreamingCleaner` type-assertion pattern rather than widening `Transcriber`:

```go
type PromptSetter interface {
    SetContextPrompt(dictTerms, screenTerms []string)
}
```

Transcribers that do not implement it (test fakes) are unaffected.

### `internal/screenctx/` (new package)

`extract.go` — builds a keyword-extraction `Cleaner` from
`llm.ProviderByName(cfg.LLMProvider)` with `llm.Options.Prompt` set to an
extraction template, then calls `Clean(ctx, windowText, cfg.CustomDict)`.

This reuses the existing prompt-template machinery deliberately: no new
provider plumbing, no new HTTP clients, no new key handling, and all four
providers (Anthropic, OpenAI, Ollama, LM Studio) work on day one. The template
uses both existing placeholders so `RenderPrompt` does not append its
cleanup-flavoured trailer:

- `{{transcription}}` receives the window text.
- `{{dictionary}}` receives the custom dictionary, framed as "already covered —
  do not repeat these", so the LLM does not spend the budget on duplicates.

`sanitize.go` — pure and table-tested. Splits the LLM response on newlines and
commas, strips bullets/numbering/quotes, drops tokens longer than 40 bytes and
numeric-only tokens, dedupes case-insensitively, and caps at 24 terms.

Input text is truncated to 8 KB before it reaches the provider, bounding both
cost and latency.

### `cmd/libhowl` exports

Two exports, split so that a cache hit costs no network:

```go
//export howl_extract_keywords
// Blocking. Takes JSON {"text": "..."}. Returns JSON {"keywords": [...]}
// or {"error": "..."}. Does NOT mutate engine state and does NOT hold
// e.mu for the duration of the network call. Callers must invoke it off
// the main thread and free the result with howl_free_string.
func howl_extract_keywords(jsonC *C.char) *C.char

//export howl_set_screen_keywords
// Instant. Takes JSON {"keywords": [...]}. Stores on the engine under
// e.mu. Returns 0 on success, 1 if the engine is not initialized,
// 2 on JSON parse error.
func howl_set_screen_keywords(jsonC *C.char) C.int
```

`engine` gains a `screenKeywords []string` field. `howl_start_capture` applies
it via the `PromptSetter` assertion before running the pipeline — at that point
no capture is in flight, so there is no data race against an in-flight
`Transcribe`.

This deliberately avoids `howl_configure`, which rebuilds the whole pipeline
(reloading the Whisper model) and is rejected while a capture is in flight.
Neither property is acceptable on a per-window-focus path.

## Swift Changes

New directory `mac/Packages/HowlCore/Sources/HowlCore/ScreenContext/`:

| File | Responsibility |
|---|---|
| `WindowTextReader.swift` | `protocol WindowTextReader`, plus `AXWindowTextReader`, `OCRWindowTextReader`, and a composite that tries AX then falls back |
| `ScreenContextObserver.swift` | `NSWorkspace.didActivateApplicationNotification` + AX focused-window observers; 800 ms dwell debounce |
| `ScreenContextDenylist.swift` | Built-in bundle IDs + user additions; `shouldSkip(bundleID:) -> Bool` |
| `ScreenContextCache.swift` | LRU, 32 entries, 10-minute TTL, keyed on SHA-256(bundleID + window title + normalized text) |
| `ScreenContextCoordinator.swift` | Orchestrates observer → denylist → reader → cache → engine |

Readers sit behind a protocol so the cache, denylist, hashing, and
AX-sufficiency threshold are all unit-testable with a fake reader. Only the
observer is a thin untested shim over AppKit notifications.

**AX sufficiency threshold:** if the AX walk yields fewer than 200 characters,
fall back to OCR. This covers Electron, Canvas-based, and terminal apps where
AX exposes little or nothing.

**Permission:** the Screen Recording TCC prompt appears only the first time an
OCR fallback actually fires. Users who work solely in native apps never see it.

**Settings UI** lives in `mac/Howl/UI/Settings/` (app target), not HowlCore,
per the existing split: a toggle plus a denylist editor.

## Privacy

- Default ON, per product decision.
- Built-in denylist ships with 1Password, Keychain Access, Bitwarden, LastPass,
  and similar; users can add bundle IDs.
- Window text is capped at 8 KB before leaving the process.
- Raw window text is **never** logged and **never** written into session
  manifests. Only the final keyword list is recorded.
- OCR pixel buffers are never persisted to disk.

**Known trade-off, accepted:** with default-ON and the extractor reusing the
cleanup provider, a fresh install configured with a cloud key sends
focused-window text to that provider without a separate opt-in. The debounce
and content-hash cache reduce the volume substantially, but this is a wider
promise than Howl's current "your audio never leaves your machine." A first-run
consent panel (reusing the `AccessibilityPanel` pattern) was considered and
deliberately deferred; it remains a small additive change if the posture
changes.

## Failure Handling

Every failure mode degrades silently to dictionary-only dictation, matching how
the cleanup stage already treats LLM failure — a background enhancement must
never cost the user their words:

| Failure | Behaviour |
|---|---|
| No LLM key / provider unreachable / rate limited | Log, clear any stale keywords from the previous window, dictate with dictionary only |
| Extraction exceeds 5 s timeout | Cancel, same as above |
| Newer focus change supersedes an in-flight extraction | Cancel the stale request, keep the newer one |
| AX yields nothing and OCR is denied | No screen keywords; no repeated TCC prompts |
| Focused window is on the denylist | No read of any kind occurs |

## Testing

**Go:**
- `sanitize` table tests: bullets, numbering, quotes, over-length tokens,
  numeric-only tokens, case-insensitive dedupe, the 24-term cap.
- `ContextPrompt`: dictionary-first ordering, dedupe against the dictionary,
  screen sub-cap enforcement, empty-dictionary and empty-screen cases.
- **Regression test for the reason this design exists:** a dense-jargon prompt
  that passes the 896-byte bound must still be trimmed to ≤224 real tokens by
  `SetContextPrompt`, and the dictionary terms must all survive.
- `screenctx.Extract` against a fake provider: success, malformed response,
  timeout, provider error.

**Swift** (swift-testing, `mac/Packages/HowlCore/Tests/HowlCoreTests/`):
- Cache hit/miss, TTL expiry, LRU eviction, key stability.
- Denylist matching including user additions.
- AX-sufficiency threshold routing to the OCR fallback, via a fake reader.
- Debounce behaviour: rapid focus changes collapse to one extraction.

## Out of Scope

- Feeding screen keywords to the LLM cleanup stage.
- Per-preset enablement (global toggle only for v1).
- Multi-window or whole-display capture.
- A non-LLM heuristic extractor as a fallback.
- Windows and Linux readers; the Go side is portable, the readers are macOS-only.
