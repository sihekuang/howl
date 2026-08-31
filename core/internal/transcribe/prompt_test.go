package transcribe

import (
	"fmt"
	"strings"
	"testing"
	"unicode/utf8"
)

func TestBoundInitialPrompt(t *testing.T) {
	tests := []struct {
		name string
		in   string
		want string
	}{
		{"empty", "", ""},
		{"whitespace only", "   \n\t ", ""},
		{"trims surrounding whitespace", "  Kubernetes  ", "Kubernetes"},
		{"short prompt unchanged", "Howl, whisper.cpp, ggml", "Howl, whisper.cpp, ggml"},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			if got := boundInitialPrompt(tc.in); got != tc.want {
				t.Errorf("boundInitialPrompt(%q) = %q, want %q", tc.in, got, tc.want)
			}
		})
	}
}

func TestBoundInitialPrompt_TruncatesToMax(t *testing.T) {
	long := strings.Repeat("a", MaxInitialPromptLen+50)
	got := boundInitialPrompt(long)
	if len(got) > MaxInitialPromptLen {
		t.Fatalf("got len %d, want <= %d", len(got), MaxInitialPromptLen)
	}
	if len(got) != MaxInitialPromptLen {
		t.Errorf("expected truncation to exactly %d bytes for ASCII input, got %d", MaxInitialPromptLen, len(got))
	}
}

func TestBoundInitialPrompt_DoesNotSplitRune(t *testing.T) {
	// Each "世" is 3 bytes; build a string longer than the limit so the
	// truncation point lands in the middle of a multibyte rune.
	long := strings.Repeat("世", MaxInitialPromptLen) // 3 * Max bytes
	got := boundInitialPrompt(long)
	if len(got) > MaxInitialPromptLen {
		t.Fatalf("got len %d, want <= %d", len(got), MaxInitialPromptLen)
	}
	if !utf8.ValidString(got) {
		t.Errorf("truncated prompt is not valid UTF-8: %q", got)
	}
}

func TestDictionaryPrompt(t *testing.T) {
	tests := []struct {
		name  string
		terms []string
		want  string
	}{
		{"nil", nil, ""},
		{"empty slice", []string{}, ""},
		{"all blank skipped", []string{"", "  ", "\t"}, ""},
		{"joins terms", []string{"Kubernetes", "gRPC", "Anthropic"}, "Kubernetes, gRPC, Anthropic"},
		{"trims and skips blanks", []string{" Howl ", "", "ggml"}, "Howl, ggml"},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			if got := DictionaryPrompt(tc.terms); got != tc.want {
				t.Errorf("DictionaryPrompt(%v) = %q, want %q", tc.terms, got, tc.want)
			}
		})
	}
}

func TestDictionaryPrompt_Bounded(t *testing.T) {
	terms := make([]string, 200)
	for i := range terms {
		terms[i] = "supercalifragilistic"
	}
	got := DictionaryPrompt(terms)
	if len(got) > MaxInitialPromptLen {
		t.Errorf("DictionaryPrompt not bounded: len %d > %d", len(got), MaxInitialPromptLen)
	}
}

func TestContextPrompt_DictionaryComesFirst(t *testing.T) {
	got, screen := ContextPrompt([]string{"MCP", "WebRTC"}, []string{"SpeakerGate"})
	want := "MCP, WebRTC, SpeakerGate"
	if got != want {
		t.Errorf("ContextPrompt() = %q, want %q", got, want)
	}
	if len(screen) != 1 || screen[0] != "SpeakerGate" {
		t.Errorf("surviving screen terms = %v, want [SpeakerGate]", screen)
	}
}

func TestContextPrompt_DedupesScreenAgainstDictionary(t *testing.T) {
	got, screen := ContextPrompt([]string{"WebRTC"}, []string{"webrtc", "SpeakerGate", "WEBRTC"})
	want := "WebRTC, SpeakerGate"
	if got != want {
		t.Errorf("ContextPrompt() = %q, want %q", got, want)
	}
	if len(screen) != 1 || screen[0] != "SpeakerGate" {
		t.Errorf("surviving screen terms = %v, want [SpeakerGate]", screen)
	}
}

func TestContextPrompt_DedupesWithinScreenTerms(t *testing.T) {
	got, _ := ContextPrompt(nil, []string{"Howl", "howl", "HOWL"})
	if got != "Howl" {
		t.Errorf("ContextPrompt() = %q, want %q", got, "Howl")
	}
}

func TestContextPrompt_SkipsEmptyAndWhitespaceTerms(t *testing.T) {
	got, _ := ContextPrompt([]string{"  MCP  ", "", "   "}, []string{"\tSpeakerGate\n", ""})
	if got != "MCP, SpeakerGate" {
		t.Errorf("ContextPrompt() = %q, want %q", got, "MCP, SpeakerGate")
	}
}

func TestContextPrompt_ScreenTermsBoundedByScreenSubCap(t *testing.T) {
	// 30 x 20-byte terms = 22*30-2 = 658 bytes joined, well over the 384 cap.
	// Largest k with 22k-2 <= 384 is 17 (372 bytes).
	screenIn := make([]string, 30)
	for i := range screenIn {
		screenIn[i] = fmt.Sprintf("term%016d", i) // exactly 20 bytes, unique
	}
	_, screen := ContextPrompt(nil, screenIn)
	if len(screen) != 17 {
		t.Errorf("surviving screen terms = %d, want 17 (screen sub-cap)", len(screen))
	}
}

func TestContextPrompt_TotalBoundEvictsScreenTermsNotDictionary(t *testing.T) {
	// Dictionary alone fills nearly the whole 896-byte budget.
	dict := []string{strings.Repeat("d", MaxInitialPromptLen-10)}
	got, screen := ContextPrompt(dict, []string{"SpeakerGate", "DeepFilterNet"})
	if len(got) > MaxInitialPromptLen {
		t.Fatalf("prompt len %d exceeds %d", len(got), MaxInitialPromptLen)
	}
	if !strings.HasPrefix(got, dict[0]) {
		t.Error("dictionary term was truncated; screen terms must be evicted first")
	}
	if len(screen) != 0 {
		t.Errorf("surviving screen terms = %v, want none", screen)
	}
}

func TestContextPrompt_EmptyInputsYieldEmptyPrompt(t *testing.T) {
	got, screen := ContextPrompt(nil, nil)
	if got != "" {
		t.Errorf("ContextPrompt(nil, nil) = %q, want empty", got)
	}
	if len(screen) != 0 {
		t.Errorf("surviving screen terms = %v, want none", screen)
	}
}

func TestContextPrompt_ScreenOnlyIsAllowed(t *testing.T) {
	got, screen := ContextPrompt(nil, []string{"SpeakerGate"})
	if got != "SpeakerGate" {
		t.Errorf("ContextPrompt() = %q, want %q", got, "SpeakerGate")
	}
	if len(screen) != 1 {
		t.Errorf("surviving screen terms = %v, want 1", screen)
	}
}

// TestScreenPreFilterDrops_ClassifiesEachRejection checks that the
// pre-filter drop classifier agrees with what ContextPrompt actually
// did — it classifies ContextPrompt's own output rather than
// re-deciding, so a wrong label here means a diagnostic that
// misattributes why a keyword vanished.
func TestScreenPreFilterDrops_ClassifiesEachRejection(t *testing.T) {
	dict := []string{"MCP"}
	// "mcp" duplicates the dictionary case-insensitively; "webrtc"
	// duplicates the earlier "WebRTC"; "  " is blank; the long tail
	// overflows MaxScreenPromptLen.
	screen := []string{"WebRTC", "mcp", "webrtc", "  ", "SpeakerGate"}
	filler := strings.Repeat("Q", 60)
	for i := 0; i < 10; i++ {
		screen = append(screen, fmt.Sprintf("%s%02d", filler, i))
	}

	_, kept := ContextPrompt(dict, screen)
	drops := screenPreFilterDrops(dict, screen, kept)

	byTerm := make(map[string]string, len(drops))
	for _, d := range drops {
		if d.Source != SourceScreen {
			t.Errorf("drop %+v has source %q, want %q", d, d.Source, SourceScreen)
		}
		byTerm[d.Term] = d.Stage
	}

	want := map[string]string{
		"mcp":    DropDuplicateOfDictionary,
		"webrtc": DropDuplicate,
		"  ":     DropEmptyTerm,
	}
	for term, stage := range want {
		if got := byTerm[term]; got != stage {
			t.Errorf("drop for %q = %q, want %q", term, got, stage)
		}
	}
	// The filler tail must have been cut by a byte cap, not mislabelled.
	var byteDrops int
	for _, d := range drops {
		if d.Stage == DropBytePreFilter {
			byteDrops++
		}
	}
	if byteDrops == 0 {
		t.Fatalf("no %s drops; fixture no longer overflows the byte pre-filter", DropBytePreFilter)
	}

	// Every screen term is accounted for exactly once: kept or dropped.
	if len(kept)+len(drops) != len(screen) {
		t.Errorf("%d kept + %d dropped != %d offered — some term is unaccounted for", len(kept), len(drops), len(screen))
	}
}

// TestBlankTermDrops_ReportsOnlyBlanks pins the dictionary-side
// counterpart: cleanTerms silently discards blank entries, and the
// diagnostic must say so.
func TestBlankTermDrops_ReportsOnlyBlanks(t *testing.T) {
	drops := blankTermDrops([]string{"MCP", "", "  \t", "WebRTC"}, SourceDictionary)
	if len(drops) != 2 {
		t.Fatalf("drops = %+v, want 2", drops)
	}
	for _, d := range drops {
		if d.Stage != DropEmptyTerm || d.Source != SourceDictionary {
			t.Errorf("drop %+v, want stage %q source %q", d, DropEmptyTerm, SourceDictionary)
		}
	}
}
