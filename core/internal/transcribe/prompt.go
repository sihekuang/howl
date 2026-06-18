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

// DictionaryPrompt builds a whisper initial prompt from a list of custom
// vocabulary terms (names, jargon, acronyms). The terms are joined into
// a comma-separated glossary that biases whisper toward the spellings
// the user cares about. Empty/whitespace terms are skipped; an empty
// list yields "" (no prompt). The result is bounded to
// MaxInitialPromptLen.
func DictionaryPrompt(terms []string) string {
	cleaned := make([]string, 0, len(terms))
	for _, t := range terms {
		if t = strings.TrimSpace(t); t != "" {
			cleaned = append(cleaned, t)
		}
	}
	if len(cleaned) == 0 {
		return ""
	}
	return boundInitialPrompt(strings.Join(cleaned, ", "))
}
