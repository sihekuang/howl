# Speech to Text Prompt — Budget & Limitations Surface

**Date:** 2026-06-18
**Status:** Approved

## Problem

The custom dictionary already feeds whisper's `initial_prompt` — the Go
core builds it with `DictionaryPrompt(cfg.CustomDict)` at `build.go:61` and
bounds it to `MaxInitialPromptLen` (896 bytes ≈ ~224 tokens, since
whisper.cpp only keeps the last ~`n_text_ctx/2` prompt tokens).

So the dictionary has **two consumers** with **very different budgets**:

1. **LLM cleanup prompt** — the dictionary is embedded via `{{dictionary}}`.
   Large budget; every term fits.
2. **Speech to text prompt** — the dictionary *is* whisper's initial
   prompt, joined `", "`. Tiny budget; a large dictionary is **silently
   truncated**, so only the leading terms actually bias recognition.

Today nothing surfaces this. A user who adds a 50-term occupation pack has
no idea that only the first chunk of it primes whisper recognition (even
though all of it still reaches LLM cleanup). There is no separate free-form
"prompt" — the **dictionary terms ARE the speech-to-text prompt**.

## Decision

A **UI-only** change in the Dictionary tab that:

1. **Names** the dictionary's recognition role as the "Speech to text
   prompt" (whisper's initial prompt), distinct from its LLM-cleanup role.
2. Adds a **token/byte budget check** against whisper's ~224-token /
   896-byte initial-prompt budget — separate from the existing "added to
   every cleanup request" token count (which measures the LLM budget).
3. Explains the **limitation**: when the dictionary exceeds whisper's
   budget, only the leading terms bias recognition, **but every term is
   still applied during LLM cleanup** — so overflow degrades recognition
   priming, not correction.

Plus a focused refactor: **right-size the built-in occupation packs** so
each comfortably fits whisper's budget, guarded by an automated test.

### Explicitly NOT in scope

- **No new free-form prompt field.** Earlier drafts invented a separate
  `sttPrompt`; that was a misread. The dictionary is the prompt.
- **No Go changes for the core feature.** `DictionaryPrompt` already builds
  and bounds the whisper prompt. No `Config` / `EngineConfig` /
  `UserSettings` field, no new combiner helper.
- Changing whisper's prompt-token retention or `MaxInitialPromptLen`.

## How the budget check mirrors Go

The Swift check must reflect what the Go side actually does so the meter is
honest. Go joins terms with `", "` and truncates the joined string to 896
bytes on a UTF-8 boundary (`DictionaryPrompt` → `boundInitialPrompt`). The
Swift helper mirrors this byte-based rule:

- `budgetBytes = 896` — a Swift constant mirroring Go's
  `transcribe.MaxInitialPromptLen`, with a comment pointing at the Go
  source so the two stay in sync. (No need to plumb the constant across the
  C ABI for a value that changes ~never.)
- `joined = terms.joined(separator: ", ")`; `usedBytes = joined.utf8.count`.
- `fits = usedBytes <= budgetBytes`.
- `termsThatFit` = all terms when it fits; otherwise the count of leading
  terms whose cumulative joined length stays within 896 bytes (the terms
  that actually reach whisper, matching Go's front-of-string truncation).

Because the Dictionary tab inserts new terms at the **front** of
`customDict`, the most recently added terms are the ones that bias
recognition; the oldest fall off first. The limitations copy notes this.

## Changes

### `mac/Packages/HowlCore/Sources/HowlCore/Storage/DictStats.swift`

Add a pure, testable helper alongside the existing `compute`:

```swift
public struct WhisperPromptFit: Equatable, Sendable {
    public var usedBytes: Int
    public var budgetBytes: Int      // 896, mirrors transcribe.MaxInitialPromptLen
    public var usedTokens: Int       // usedBytes / 4, matching DictStats' estimate
    public var budgetTokens: Int     // budgetBytes / 4 ≈ 224
    public var termsThatFit: Int
    public var totalTerms: Int
    public var overBudget: Bool      // usedBytes > budgetBytes
}

public static func whisperPromptFit(from terms: [String]) -> WhisperPromptFit
```

Keeping it in `DictStats` (HowlCore) makes it reachable from the existing
`DictStats` package tests and keeps view code thin.

### `mac/Howl/UI/Settings/DictionaryTab.swift`

In the existing terms-card header / stats area, add a **Speech-to-text
prompt** indicator next to (and visually distinct from) the current
"Added to every cleanup request" stat:

- Reads `DictStats.whisperPromptFit(from: settings.customDict)`.
- Shows e.g. `Speech-to-text prompt: ~X / ~224 tokens` (or
  `K of N terms fit`), turning amber/red when `overBudget`.
- Over-budget note: "Whisper biases recognition on the first ~K terms; the
  rest still apply during cleanup."
- A short, always-visible limitations line explaining the dual role:
  "Your dictionary also primes speech recognition. Whisper's prompt is tiny
  (~224 tokens) — over that, extra terms only affect cleanup, not
  recognition."

The existing LLM-cleanup token stat stays as-is; the two indicators sit
side by side, each clearly labeled with which budget it measures.

## Right-size the occupation packs

Measured current sizes (joined `", "`, UTF-8 bytes) — **all already within
budget**:

| pack | terms | bytes | ~tokens |
|---|---|---|---|
| software-engineer | 51 | 377 | 94 |
| ai-ml | 41 | 342 | 85 |
| medical | 38 | 356 | 89 |
| legal | 32 | 313 | 78 |
| finance | 41 | 266 | 66 |
| designer | 28 | 245 | 61 |
| academic | 27 | 212 | 53 |

So no pack overflows today. The goal is to (a) **keep it that way** with an
automated guard, and (b) **value-order** each pack so the highest-value
terms survive when a pack is combined with other packs / manual terms and
the total crosses whisper's budget.

### Make packs testable — relocate to HowlCore

`OccupationPacks` lives in the app target
(`mac/Howl/UI/Settings/OccupationPacks.swift`), which the HowlCore package
— where all unit tests live (there is no app test bundle) — cannot import.
Relocate the file into `mac/Packages/HowlCore/Sources/HowlCore/` and make
`OccupationPacks`, its `Pack` struct, and their members `public`. The data
is pure strings (no UI), so this is a clean move: `DictionaryTab` already
`import HowlCore`s and keeps referencing `OccupationPacks.all` unchanged.
Run `make project` so xcodegen drops the file from the app target's source
list.

### Value-order each pack

Within each pack, order terms most-distinctive-first — the spellings
whisper most reliably mangles and that are most central to the domain.
Because the Dictionary tab inserts pack terms at the **front** of
`customDict` and Go truncates the joined string from the **back**,
front-loaded high-value terms are the ones that survive when the combined
dictionary exceeds budget. This is curation, not mechanics; the guard test
below enforces only size, not order.

### Guard test

Assert every `OccupationPacks.all` pack's joined `", "` byte length stays
within a **soft cap of `budgetBytes / 2` (448 bytes)** — small enough that
a single pack fits comfortably *and* any two packs still fit whisper's
896-byte prompt. All current packs pass (largest 377). The test fails
loudly if a future edit pushes a pack over, pointing the author at the
budget (split the pack or trim it). Reuses the same `budgetBytes` constant
as `whisperPromptFit`.

## Testing

### Swift (HowlCore package tests, `DictStatsTests` or sibling)
- `whisperPromptFit` with an empty list → 0 bytes, all-fit, not over budget.
- A small dictionary well under 896 bytes → `termsThatFit == totalTerms`,
  `overBudget == false`.
- A large dictionary over 896 bytes → `overBudget == true`,
  `termsThatFit < totalTerms`, and `termsThatFit` matches a hand-computed
  count for a known input.
- A boundary case sized to land near exactly 896 bytes.
- Multibyte terms (e.g. CJK) so `usedBytes` uses UTF-8 byte length, not
  character count.

### Swift — occupation pack guard
- Every `OccupationPacks.all` pack's joined `", "` byte length ≤ 448
  (`budgetBytes / 2`). Fails loudly when a pack edit exceeds the cap.
- (Sanity) pack `id`s are unique and no pack has an empty term list.

### Manual
- Add several occupation packs (or a large manual list) to push the
  dictionary past whisper's budget — no single pack overflows after
  right-sizing. Confirm the Dictionary tab shows the over-budget state and
  the limitations copy, and that LLM cleanup still receives every term
  (unchanged behavior).

## Related work (separate, not blocking)

The earlier code-review finding stands on its own: `replay.go:114` builds
whisper with **no** initial prompt, so the Compare/replay harness gets none
of the dictionary's recognition bias that the live pipeline gets. That is a
one-line Go fix (`InitialPrompt: transcribe.DictionaryPrompt(cfg.CustomDict)`)
and can ship independently of this UI work. Tracked here so it isn't lost.
