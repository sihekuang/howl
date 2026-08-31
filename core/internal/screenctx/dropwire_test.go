package screenctx

import "testing"

// Sanitize's drop reasons cross the C ABI in howl_extract_keywords'
// JSON and the Swift inspector buckets rows by comparing against these
// exact values. A rename builds cleanly on both sides and silently
// mis-buckets the diagnostic panel, so pin them here.
//
// If you genuinely need to rename one, update this test AND the Swift
// bucketing in ScreenContextSection together.
func TestSanitizeDropReasons_WireContract(t *testing.T) {
	want := map[string]string{
		"DropEmpty":      "empty",
		"DropTooLong":    "too_long",
		"DropNumeric":    "numeric",
		"DropDuplicate":  "duplicate",
		"DropKeywordCap": "keyword_cap",
	}
	got := map[string]string{
		"DropEmpty":      DropEmpty,
		"DropTooLong":    DropTooLong,
		"DropNumeric":    DropNumeric,
		"DropDuplicate":  DropDuplicate,
		"DropKeywordCap": DropKeywordCap,
	}
	for name, w := range want {
		if got[name] != w {
			t.Errorf("%s = %q, want %q — this string crosses the C ABI and the Swift inspector matches it literally", name, got[name], w)
		}
	}
}
