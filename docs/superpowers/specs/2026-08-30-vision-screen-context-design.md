# Vision-based screen context — design

**Status: SUPERSEDED as the default (2026-09-01), not deleted.** Local
Vision OCR is the shipping strategy again; the vision model is now one
interchangeable strategy behind the `ScreenContentSource` seam. This
document still describes that strategy accurately — everything below
about the capture, the denylist guarantee, the empirical `no_vision`
probe, the canary and the Go image path is live code — but "the primary
path" throughout now means "the path you get by naming
`VisionModelScreenContentSource` in `CompositionRoot`".

## What changed, and why

The user's call: read the screen locally by default. Nothing about the
vision path was found wrong — the argument above still holds — but OCR
costs no tokens, no round trip and no provider capability, and it keeps
the window's contents on the machine.

Reversing the "Why" above honestly:

- **Portability** was the strongest argument for the model, and it is
  the one this costs. The Swift-side OCR is platform-specific again.
  Everything downstream is still shared Go: OCR feeds
  `screenctx.Extract` — the SAME text path `AXWindowTextReader` feeds —
  so a future shell still inherits extraction, sanitization and the
  whisper prompt budget by supplying either text or bytes.
- **Layout** remains a real advantage of the model, and remains
  available: switching back is one expression in `CompositionRoot`.

What made this a swap rather than a rewrite is the seam:
`ScreenContentSource` yields either `.text` (OCR, AX) or `.image` (a
vision model), and the coordinator picks the Go extractor from that
shape alone. The three strategies compose —
`FallbackScreenContentSource(primary:secondary:)` is how "OCR, falling
back to accessibility text when there is no screenshot" is expressed —
and no strategy can weaken the denylist, because each resolves identity
and applies the denylist in one MainActor hop via
`resolveReadableFrontmostApp`.

### Measured facts behind the OCR strategy

Measured on a real 1568x1323 Chrome capture containing six invented
identifiers, and re-verified by
`OCRWindowTextRecognizerVisionTests`:

- A whole-image `VNRecognizeTextRequest` at `.accurate` returns **zero**
  observations — not partial, nothing, silently. Vision downsamples
  large inputs to a fixed working resolution, so small text stops being
  legible. A naive implementation compiles, looks correct, and produces
  nothing forever.
- Tiling into overlapping bands sized in **pixels** fixes it: 512px
  bands with 96px overlap recovered 6/6 in ~0.5s.
- `.fast` is forbidden. It returns text and garbles exactly what
  matters (`PLQ-B8231-ZAPII` for `PLQ-88231-ZARN`).
  `usesLanguageCorrection` stays false: identifiers must never be
  "corrected".
- The capture is **not** downscaled before OCR. The 1568px long-edge cap
  below exists to cut vision-model token cost and now applies to
  `VisionModelScreenContentSource` only.
- Wide captures need splitting on X as well as Y: a 5120px-wide desktop
  grab yields ~200 characters as full-width bands and ~5400 once it is
  also split across X.

## Original design (still accurate for the vision strategy)

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
| `OCRWindowTextReader` | deleted then **replaced** by `OCRWindowTextRecognizer` + `OCRScreenContentSource` (2026-09-01), which tile — the original never did, which is why it read nothing on a large capture |
| `FallbackWindowTextReader`, `WindowTextReading.minimumUsefulChars` | **deleted** — no AX→OCR ladder |
| `AXWindowTextReader` | **kept, demoted** — reachable whenever pixels are unavailable: no vision model, or no screenshot |
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
