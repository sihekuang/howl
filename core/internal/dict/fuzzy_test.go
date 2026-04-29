package dict

import (
	"sort"
	"testing"
)

func TestFuzzy_ExactMatch(t *testing.T) {
	d := NewFuzzy([]string{"WebRTC", "MCP"}, 1)
	got, terms := d.Match("we use WebRTC for audio")
	if got != "we use WebRTC for audio" {
		t.Errorf("exact match should leave text unchanged, got %q", got)
	}
	wantTerms := []string{"WebRTC"}
	if !equalStringSets(terms, wantTerms) {
		t.Errorf("matchedTerms = %v, want %v", terms, wantTerms)
	}
}

func TestFuzzy_OneEditDistance(t *testing.T) {
	d := NewFuzzy([]string{"WebRTC"}, 1)
	got, terms := d.Match("we use webrt for audio")
	if got != "we use WebRTC for audio" {
		t.Errorf("close match should be corrected, got %q", got)
	}
	if len(terms) != 1 || terms[0] != "WebRTC" {
		t.Errorf("matchedTerms = %v", terms)
	}
}

func TestFuzzy_TooFar_NoMatch(t *testing.T) {
	d := NewFuzzy([]string{"WebRTC"}, 1)
	got, terms := d.Match("we use HTTP for audio")
	if got != "we use HTTP for audio" {
		t.Errorf("distant token should not match, got %q", got)
	}
	if len(terms) != 0 {
		t.Errorf("matchedTerms = %v, want []", terms)
	}
}

func TestFuzzy_EmptyInput(t *testing.T) {
	d := NewFuzzy([]string{"WebRTC"}, 1)
	got, terms := d.Match("")
	if got != "" || terms != nil {
		t.Errorf("empty input → %q, %v", got, terms)
	}
}

func TestFuzzy_DeduplicatesMatchedTerms(t *testing.T) {
	d := NewFuzzy([]string{"MCP"}, 1)
	got, terms := d.Match("MCP and MCP again")
	if got != "MCP and MCP again" {
		t.Errorf("got %q", got)
	}
	if len(terms) != 1 || terms[0] != "MCP" {
		t.Errorf("matchedTerms = %v", terms)
	}
}

func TestFuzzy_PunctuationPreserved(t *testing.T) {
	d := NewFuzzy([]string{"WebRTC"}, 1)
	got, _ := d.Match("we use webrt, for audio.")
	if got != "we use WebRTC, for audio." {
		t.Errorf("punctuation lost: got %q", got)
	}
}

func TestLevenshtein(t *testing.T) {
	cases := []struct {
		a, b string
		want int
	}{
		{"", "", 0},
		{"abc", "abc", 0},
		{"abc", "abd", 1},
		{"abc", "acb", 2},
		{"webrt", "WebRTC", 4}, // case-insensitive comparison handled by caller
		{"kitten", "sitting", 3},
	}
	for _, tc := range cases {
		got := levenshtein(tc.a, tc.b)
		if got != tc.want {
			t.Errorf("levenshtein(%q, %q) = %d, want %d", tc.a, tc.b, got, tc.want)
		}
	}
}

func equalStringSets(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	ac := append([]string(nil), a...)
	bc := append([]string(nil), b...)
	sort.Strings(ac)
	sort.Strings(bc)
	for i := range ac {
		if ac[i] != bc[i] {
			return false
		}
	}
	return true
}
