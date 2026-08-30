package transcribe

import (
	"strings"
	"unicode/utf8"
)

// MaxInitialPromptLen bounds the size (in bytes) of an initial prompt
// passed to whisper. whisper.cpp keeps only the last ~n_text_ctx/2
// prompt tokens internally, so an unbounded prompt is wasted work; we
// cap the input defensively to avoid pathological allocations and to
// keep the custom-vocabulary glossary within a sensible range. ~896
// bytes comfortably covers the useful token budget for the prompt.
const MaxInitialPromptLen = 896

// MaxScreenPromptLen is a loose byte pre-filter on the screen-derived
// portion of the prompt, applied in ContextPrompt (whose only
// production caller is WhisperCpp.SetContextPrompt; no howl-cli
// consumer exists). The authoritative bound is MaxScreenPromptTokens,
// enforced afterward in WhisperCpp.SetContextPrompt itself.
const MaxScreenPromptLen = 384

// MaxScreenPromptTokens caps the screen-derived portion of whisper's
// 224-token prompt window, leaving the majority for the custom
// dictionary. Deliberately conservative: an oversized initial_prompt is
// a documented cause of hallucinated words in the transcript.
const MaxScreenPromptTokens = 96

// boundInitialPrompt trims surrounding whitespace and truncates the
// prompt to at most MaxInitialPromptLen bytes on a UTF-8 rune boundary
// (so a multibyte rune is never split). An empty or whitespace-only
// prompt yields "", signalling "no initial prompt".
func boundInitialPrompt(prompt string) string {
	prompt = strings.TrimSpace(prompt)
	if len(prompt) <= MaxInitialPromptLen {
		return prompt
	}
	// Back off to the nearest rune boundary at or below the limit so we
	// don't slice through the middle of a multibyte rune.
	cut := MaxInitialPromptLen
	for cut > 0 && !utf8.RuneStart(prompt[cut]) {
		cut--
	}
	return strings.TrimSpace(prompt[:cut])
}

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

// boundTermsByBytes keeps terms from the front of `terms` whose
// comma-joined byte length (including ", " separators) fits within
// maxBytes, dropping the tail once it would not. A cheap byte-length
// pre-filter over a term LIST — distinct from (and coarser than) a
// token-count bound, and distinct from boundInitialPrompt (which
// operates on an already-joined string and can truncate mid-term,
// which is fine for free text but would corrupt a comma-separated
// term list). Existing callers needing the authoritative token bound
// still apply it afterward; this exists to make that check cheap by
// bounding how many terms it ever has to consider. Mirrors the
// accumulation loop ContextPrompt already uses for its screen-term
// byte cap.
func boundTermsByBytes(terms []string, maxBytes int) []string {
	kept := make([]string, 0, len(terms))
	used := 0
	for _, t := range terms {
		add := len(t)
		if len(kept) > 0 {
			add += 2 // ", " separator
		}
		if used+add > maxBytes {
			break
		}
		used += add
		kept = append(kept, t)
	}
	return kept
}

// DictionaryPrompt builds a whisper initial prompt from a list of custom
// vocabulary terms (names, jargon, acronyms). The terms are joined into
// a comma-separated glossary that biases whisper toward the spellings
// the user cares about. Empty/whitespace terms are skipped; an empty
// list yields "" (no prompt). The result is bounded to
// MaxInitialPromptLen.
func DictionaryPrompt(terms []string) string {
	cleaned := cleanTerms(terms)
	if len(cleaned) == 0 {
		return ""
	}
	return boundInitialPrompt(strings.Join(cleaned, ", "))
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
// result is bounded to MaxInitialPromptLen. Both are byte bounds, and
// deliberately loose — a cheap pre-filter, not the authoritative one.
//
// The returned PROMPT STRING is not what governs what whisper actually
// sees, and not what production uses: WhisperCpp.SetContextPrompt, the
// only production caller, discards it outright
// (`_, screen := ContextPrompt(...)`) and re-trims the returned screen
// SLICE against whisper's real token window (MaxScreenPromptTokens,
// then MaxPromptTokens) — that token-based pass is what actually
// governs the prompt whisper sees and what ends up in the session
// manifest. This function's tests exercise the string return directly
// (its normal Go contract), but no caller does.
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
