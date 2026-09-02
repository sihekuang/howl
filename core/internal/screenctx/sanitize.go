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

// Drop reasons reported by SanitizeWithDrops. These are exhaustive:
// they are the only branches in the sanitizer that can reject a
// candidate term.
const (
	// DropEmpty: nothing left after stripping bullets, numbering,
	// quotes, and surrounding whitespace.
	DropEmpty = "empty"
	// DropTooLong: longer than MaxKeywordBytes — the model returned a
	// sentence fragment rather than a term.
	DropTooLong = "too_long"
	// DropNumeric: digits and numeric punctuation only; worthless as a
	// recognition hint.
	DropNumeric = "numeric"
	// DropDuplicate: case-insensitive repeat of a term already kept.
	DropDuplicate = "duplicate"
	// DropKeywordCap: otherwise acceptable, but MaxKeywords terms had
	// already been kept by the time it was reached.
	DropKeywordCap = "keyword_cap"
)

// DroppedTerm is one rejected candidate and the reason it was rejected.
// Term is the term as it looked AFTER bullet/quote stripping — i.e.
// what would have reached the prompt — except for DropEmpty, where the
// stripped form is by definition empty and the whitespace-trimmed
// original is reported instead so the diagnostic still shows something.
type DroppedTerm struct {
	Term   string `json:"term"`
	Reason string `json:"reason"`
}

// Sanitize turns a raw LLM response into a bounded, deduped keyword
// list. Input is untrusted model output, so every assumption about
// format is enforced rather than trusted.
//
// Implemented in terms of SanitizeWithDrops so there is exactly one
// copy of the filtering rules: a second implementation would let the
// shipped keyword list and the diagnostic that claims to explain it
// disagree.
func Sanitize(raw string) []string {
	kept, _ := SanitizeWithDrops(raw)
	return kept
}

// SanitizeWithDrops is Sanitize plus a report of every candidate it
// rejected and why. kept is identical to Sanitize's return (nil, not an
// empty slice, when nothing survives); dropped is nil when nothing was
// rejected.
//
// Once MaxKeywords terms have been kept, remaining candidates are still
// examined so they can be reported: a candidate that would otherwise
// have been kept is reported as DropKeywordCap, while one that fails an
// earlier check is reported under that check's reason (the check that
// actually rejected it). Terms past the cap are deliberately NOT added
// to the dedupe set — they were never kept, so a later repeat of one
// is itself reported as DropKeywordCap rather than DropDuplicate.
func SanitizeWithDrops(raw string) (kept []string, dropped []DroppedTerm) {
	fields := strings.FieldsFunc(raw, func(r rune) bool {
		return r == '\n' || r == '\r' || r == ',' || r == ';'
	})

	out := make([]string, 0, len(fields))
	seen := make(map[string]struct{}, len(fields))
	for _, f := range fields {
		t := strings.TrimSpace(f)
		original := t
		// Fixed-point loop to strip nested bullets/numbering and quotes.
		// Handles both "- MCP" (quote-then-bullet) and - "MCP" (bullet-then-quote).
		for {
			oldT := t
			t = listPrefix.ReplaceAllString(t, "")
			t = strings.TrimSpace(t)
			t = strings.Trim(t, "\"'`")
			t = strings.TrimSpace(t)
			if t == oldT {
				break // Fixed point reached
			}
		}

		switch {
		case t == "":
			dropped = append(dropped, DroppedTerm{Term: original, Reason: DropEmpty})
			continue
		case len(t) > MaxKeywordBytes:
			dropped = append(dropped, DroppedTerm{Term: t, Reason: DropTooLong})
			continue
		case isNumeric(t):
			dropped = append(dropped, DroppedTerm{Term: t, Reason: DropNumeric})
			continue
		}
		key := strings.ToLower(t)
		if _, dup := seen[key]; dup {
			dropped = append(dropped, DroppedTerm{Term: t, Reason: DropDuplicate})
			continue
		}
		if len(out) == MaxKeywords {
			dropped = append(dropped, DroppedTerm{Term: t, Reason: DropKeywordCap})
			continue
		}
		seen[key] = struct{}{}
		out = append(out, t)
	}
	if len(out) == 0 {
		return nil, dropped
	}
	return out, dropped
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
