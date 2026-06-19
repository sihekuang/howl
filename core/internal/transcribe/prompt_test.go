package transcribe

import (
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
