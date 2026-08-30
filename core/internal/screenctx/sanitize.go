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
