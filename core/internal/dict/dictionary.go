// Package dict provides custom-vocabulary correction for ASR output.
// The Dictionary interface is an extension point: today only fuzzy matching;
// Phase 2 may add phonetic (Metaphone) matching behind the same interface.
package dict

type Dictionary interface {
	// Match scans `text` for tokens that approximately match any of the
	// custom terms this Dictionary was constructed with. Each matched
	// token is replaced with its canonical form. The returned slice is
	// the canonical forms that were actually substituted, with no
	// duplicates and no preserved order. An empty input yields ("", nil).
	Match(text string) (corrected string, matchedTerms []string)
}
