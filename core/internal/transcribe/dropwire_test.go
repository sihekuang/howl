package transcribe

import "testing"

// The drop-stage strings are a WIRE CONTRACT, not internal labels. They
// cross the C ABI in howl_screen_context_preview's JSON and the Swift
// inspector buckets rows by comparing against these exact values.
//
// Renaming a constant is therefore a breaking change that the compiler
// cannot catch: Go keeps building, Swift keeps building, and the
// inspector silently mis-buckets or drops a row. This test makes the
// rename fail here, next to the constant, instead of surfacing as a
// quietly wrong diagnostic panel.
//
// If you genuinely need to rename one, update this test AND the Swift
// bucketing in ScreenContextSection together.
func TestPromptDropStages_WireContract(t *testing.T) {
	want := map[string]string{
		"DropEmptyTerm":             "empty",
		"DropDuplicateOfDictionary": "duplicate_of_dictionary",
		"DropDuplicate":             "duplicate",
		"DropBytePreFilter":         "byte_prefilter",
		"DropDictByteCap":           "dict_byte_cap",
		"DropScreenTokenCap":        "screen_token_cap",
		"DropPromptTokenCap":        "prompt_token_cap",
	}
	got := map[string]string{
		"DropEmptyTerm":             DropEmptyTerm,
		"DropDuplicateOfDictionary": DropDuplicateOfDictionary,
		"DropDuplicate":             DropDuplicate,
		"DropBytePreFilter":         DropBytePreFilter,
		"DropDictByteCap":           DropDictByteCap,
		"DropScreenTokenCap":        DropScreenTokenCap,
		"DropPromptTokenCap":        DropPromptTokenCap,
	}
	for name, w := range want {
		if got[name] != w {
			t.Errorf("%s = %q, want %q — this string crosses the C ABI and the Swift inspector matches it literally", name, got[name], w)
		}
	}
}
