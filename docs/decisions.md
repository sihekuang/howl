# Decisions Log

Append-only record of decisions made autonomously from converging evidence
(see the `evidence-based-decisions` skill). Entries the human partner
decided are recorded in the relevant design spec instead.

## 2026-08-29 — On-screen OCR engine: Apple Vision (`VNRecognizeTextRequest`)

**Decision:** For the screen-context feature, do OCR with Apple's Vision
framework (`VNRecognizeTextRequest`, `.accurate` recognition level) rather
than bundling Tesseract or any third-party OCR engine.

**Trigger:** The screen-context → Whisper-prompt feature needs to turn a
screenshot into text on macOS; no OCR engine exists in the repo yet.

**Basis:** Unanimous across 3+ independent sources — every source treats the
built-in Vision/Live Text stack as the default and best-performing OCR on
macOS, and the one project that exists specifically to expose OCR to another
language on Mac wraps Vision rather than shipping Tesseract. No source
recommended Tesseract on macOS. It is also on-device (no network, matching
Howl's local-first stance), zero-dependency, and already linked into the OS.

**Sources:**
- Apple, Vision framework / `VNRecognizeTextRequest` documentation — https://developer.apple.com/documentation/vision/vnrecognizetextrequest
- `ocrmac` (Maximilian Strauss) — a wrapper that exists because Vision beats the alternatives on Mac — https://github.com/straussmaximilian/ocrmac
- Evan Hahn, "Simple macOS script to extract text from images (OCR)" — https://evanhahn.com/mac-ocr-script/
- "How to Extract Text from Image on Mac" (2026) — https://www.screensnap.pro/blog/extract-text-from-text-mac

## 2026-08-29 — Whisper prompt budget: hard 224-token cap, dictionary keeps priority

**Decision:** Screen-derived keywords share the existing
`transcribe.MaxInitialPromptLen` (896 bytes ≈ 224 tokens) budget rather than
getting their own. The custom dictionary is composed FIRST and screen keywords
fill only the remainder, so overflow always evicts screen keywords, never
dictionary terms. The feature must be switchable off.

**Trigger:** "Make sure that we are not blowing up Whisper's context" — needed
a factual answer for how much prompt Whisper actually accepts and what happens
past it.

**Basis:** Unanimous across the OpenAI Whisper cookbook (authoritative) and 3
independent discussions/analyses: the prompt is capped at 224 tokens and
anything longer is *silently* truncated to the FINAL 224 tokens — so an
oversized prompt is not an error, it is silent, unpredictable loss. Sources
also unanimously document that prompts can induce hallucination (text not
present in the audio), which is why the feature needs an off switch and a
conservative sub-budget rather than "fill the window."

**Sources:**
- OpenAI Cookbook, "Whisper prompting guide" — https://developers.openai.com/cookbook/examples/whisper_prompting_guide
- openai/whisper Discussion #1824, "Prompt length (244 characters or tokens?)" — https://github.com/openai/whisper/discussions/1824
- openai/whisper Discussion #1386, "Maximum number of 'initial_prompt' characters/tokens" — https://github.com/openai/whisper/discussions/1386
- David Cochard, "Prompt Engineering in Whisper" (ailia Tech Blog) — https://medium.com/axinc-ai/prompt-engineering-in-whisper-6bb18003562d

## 2026-08-29 — libhowl ABI version: bump to 1.1.0 for the two new exports

**Decision:** Bump `abiVersion` in `core/cmd/libhowl/exports.go` from `1.0.0` to `1.1.0`
as part of adding `howl_extract_keywords` and `howl_set_screen_keywords`.

**Trigger:** Task 5 of the screen-context feature adds two new C-ABI exports. The
implementer correctly declined to guess whether the ABI version should move and
escalated it rather than picking one.

**Basis:** Existing project convention — the rule is written directly above the
constant it governs. `exports.go:718-721` states the bump policy verbatim: "major:
a function signature changes, or one is removed / **minor: a new function is added
(additive, back-compat)** / patch: a fix that doesn't change the surface (rare)."
Two additive functions is exactly the minor case. Verified safe: the doc comment
says the Mac app asserts only on the MAJOR version, and a grep of `mac/` for
`abi_version` / `abiVersion` finds no Swift consumer reading it at all today, so
moving the minor digit cannot break the host.

**Sources:**
- `core/cmd/libhowl/exports.go:718-727` — the bump policy and the constant
- `mac/Packages/HowlCore/Sources/HowlCore/Bridge/` — no consumer of `howl_abi_version`

## 2026-08-30 — Screen-context denylist: keep BOTH Dashlane bundle IDs

**Decision:** Add `com.dashlane.Dashlane` to `ScreenContextDenylist.builtIn` and KEEP the
existing `com.dashlane.dashlanephonefinal` rather than replacing it.

**Trigger:** A task review flagged that `com.dashlane.dashlanephonefinal` — taken verbatim
from the implementation plan — looks like a legacy iOS-era identifier rather than the
current macOS app's. In a denylist whose job is keeping Howl out of password-manager
windows, a wrong identifier means the vault gets read.

**Basis:** Two independent lines of evidence converge on `com.dashlane.Dashlane` as the
current macOS bundle identifier: the reviewer's research (a bundle-ID extraction site plus
Dashlane's own ~2014 iOS-extension code, which is where the `dashlanephonefinal` string
traces back to) and an independent web search of the same question. Dashlane is not
installed on this machine, so neither could be confirmed against a live `Info.plist` —
confidence is high, not certain.

Keeping both is not a hedge between two candidate answers; it is the correct engineering
choice regardless of which is current. A denylist is additive and matched case-insensitively
by exact bundle ID, so an extra entry costs one string comparison and cannot produce a false
positive against any other app. Users on older installs stay protected either way. The
asymmetry is stark: a redundant entry costs nothing, a missing one leaks a password vault.

**Sources:**
- Does It ARM, Dashlane app entry (bundle ID extracted from the shipped app) — https://doesitarm.com/app/dashlane
- Apple, "Get the bundle ID for a Mac app" (how the identifier is defined) — https://support.apple.com/guide/deployment/get-the-bundle-id-for-a-mac-app-dep0af2cd611/web
- Independent web search corroborating `com.dashlane.Dashlane` as the current macOS identifier

**Residual risk, surfaced to the user:** an exact-bundle-ID denylist is inherently
incomplete — it cannot cover password managers nobody listed, nor a banking site in a
browser tab. The spec accepted that trade-off; it is not a defect introduced here.

## 2026-08-30 — OCR capture must convert points to pixels (Retina scale)

**Decision:** In `OCRWindowTextReader`, set `SCStreamConfiguration.width/height` from the
window's size multiplied by the content filter's `pointPixelScale`, rather than from
`window.frame.width/height` directly. Also set `captureResolution = .best` (macOS 14+).

**Trigger:** A task review flagged, as a Minor, that the capture config was fed point
dimensions. Research upgraded it: on every Retina Mac this halves linear capture
resolution, and the text this feature exists to read is small-glyph code identifiers.

**Basis:** Unanimous across Apple's own documentation, Apple's sample code, and developer
forum guidance: `SCWindow.frame` / `SCDisplay` sizes are in POINTS, while
`SCStreamConfiguration.width/height` are in PIXELS. Apple's "Capturing screen content in
macOS" sample multiplies display dimensions by a scale factor for exactly this reason, and
ScreenCaptureKit exposes `SCContentFilter.pointPixelScale` as the supported way to make the
conversion for a window filter. No source suggested passing points directly is correct.

**Why this is not cosmetic:** at 2x, passing points yields an image with half the linear
resolution — a quarter of the pixels. Vision's accuracy on small glyphs degrades sharply
under downsampling, and the OCR path exists precisely for the apps AX cannot read
(Electron editors, terminals) where the target vocabulary is dense identifiers.

**Sources:**
- Apple, "Capturing screen content in macOS" (sample multiplies by scale factor) — https://developer.apple.com/documentation/ScreenCaptureKit/capturing-screen-content-in-macos
- Apple Developer Forums, "Take correctly sized screenshots with ScreenCaptureKit" (`SCContentFilter.pointPixelScale`) — https://developer.apple.com/forums/thread/765360
- Apple Developer Forums, "Why is the image captured by SCScreenshotManager.captureImage so blurry?" (same points/pixels root cause) — https://developer.apple.com/forums/thread/739593
