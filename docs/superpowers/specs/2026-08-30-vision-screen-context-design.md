# Vision-based screen context — design

**Status:** approved, superseding the OCR capture path in
`2026-08-29-screen-context-whisper-biasing-design.md`.

**Goal:** move screen-context capture from "Swift does OCR, Go gets text"
to "Swift grabs a screenshot, Go asks a vision model for keywords."

## Why

Not accuracy. Vision OCR was measured against rendered code at production
settings (`.accurate`, `usesLanguageCorrection = false`) and recovered
16/16 identifiers at 13pt and 11pt on both Retina and non-Retina,
including `whisper_token_count`, `16_000`, and dim low-contrast comments.
It only degrades below ~9pt at 1x. OCR is not the weak link.

The reasons are architectural:

- **Portability.** The platform-specific surface shrinks to "capture a
  screenshot." Everything downstream — extraction, sanitization, the
  whisper prompt budget — is already shared Go, so a future Windows or
  Linux shell inherits it by supplying bytes.
- **Layout.** A vision model sees structure. It can tell a filename in a
  tab bar from a variable in the code; a flat OCR dump cannot.

## Scope

| Component | Fate |
|---|---|
| `OCRWindowTextReader` | **deleted** — its job is now the model's |
| `FallbackWindowTextReader`, `WindowTextReading.minimumUsefulChars` | **deleted** — no AX→OCR ladder |
| `AXWindowTextReader` | **kept, demoted** — reachable only as the no-vision fallback |
| `resolveReadableFrontmostApp` | **kept and reused by the capturer** — see Privacy |
| Screenshot capture | **new**, primary path |
| Go `screenctx` | gains an image path beside the text path |

## Decisions

### 1. Vision capability is detected empirically, not from a table

Attempt the vision call. If the provider rejects it because the model
cannot accept images, mark that `(provider, model)` pair text-only for
the session and fall back to the AX text path.

A maintained capability table rots — vision models ship continuously and
Ollama/LM Studio serve arbitrary user-pulled models. One wasted request
per model change is cheaper than a table that silently lies. Cache the
verdict in memory only, keyed on provider+model, so a settings change
re-probes.

### 2. Images cross the ABI as raw bytes, not base64 JSON

New export taking a pointer and length rather than base64 inside the
existing JSON envelope. Base64 inflates by ~33% on a payload sent once
per debounced focus change; the existing string-in/string-out shape is
right for text and wrong for this.

### 3. Downscale to a long edge of 1568px, encode PNG

1568px is Anthropic's documented threshold above which images are
downscaled server-side anyway; OpenAI's tiling is comparable. PNG rather
than JPEG because JPEG artifacts land hardest on small glyphs.

The measured OCR data justifies the limit: text that reads perfectly at
1x only degrades below ~9pt, so halving a Retina capture stays inside the
safe zone. Downscaling further would not.

### 4. The denylist guarantee is unchanged and non-negotiable

The screenshot capturer MUST use `resolveReadableFrontmostApp`, which
resolves the frontmost app's identity **and** applies the denylist inside
a single `MainActor` hop with no suspension between them, then returns
the pid — so the window captured is by construction the window that was
cleared.

This took several review rounds to get right. The failure it prevents is
concrete and ordinary: focus settles in an editor, the debounce fires,
the user alt-tabs to a password manager, and the in-flight capture
targets the vault instead. A capturer that re-resolves frontmost
independently reintroduces exactly that.

The guard must precede every ScreenCaptureKit call, so a denylisted app
also never triggers the Screen Recording prompt.

### 5. Both paths converge on the existing pipeline

The image path produces the same comma-separated term list the text path
does, and feeds the same `Sanitize` → `ContextPrompt` →
`SetContextPrompt` chain. The whisper prompt budget, the dictionary-first
ordering, and the manifest recording are untouched.

## Consequences accepted

- **Every user now meets the Screen Recording prompt.** Today most never
  do, because AX handles their apps. This is the real cost of the
  one-path architecture and it is accepted deliberately.
- **Per-focus cost rises** from ~8KB of text to a downscaled PNG.
- **Text-only local models keep working** via the AX fallback, so the
  "reuse the active cleanup provider" decision survives.

## Out of scope

Changing what whisper receives, the prompt budget, the denylist policy,
or the cleanup stage.
