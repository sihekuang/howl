package screenctx

import (
	"fmt"
	"strings"
	"testing"
)

func TestSanitize(t *testing.T) {
	tests := []struct {
		name string
		in   string
		want []string
	}{
		{"empty", "", nil},
		{"whitespace only", "   \n\t ", nil},
		{"plain comma list", "MCP, WebRTC, SpeakerGate", []string{"MCP", "WebRTC", "SpeakerGate"}},
		{"newline separated", "MCP\nWebRTC\nSpeakerGate", []string{"MCP", "WebRTC", "SpeakerGate"}},
		{"semicolon separated", "MCP; WebRTC", []string{"MCP", "WebRTC"}},
		{"strips dash bullets", "- MCP\n- WebRTC", []string{"MCP", "WebRTC"}},
		{"strips asterisk bullets", "* MCP\n* WebRTC", []string{"MCP", "WebRTC"}},
		{"strips unicode bullets", "• MCP\n• WebRTC", []string{"MCP", "WebRTC"}},
		{"strips numbering", "1. MCP\n2) WebRTC", []string{"MCP", "WebRTC"}},
		{"strips double quotes", `"MCP", "WebRTC"`, []string{"MCP", "WebRTC"}},
		{"strips single quotes", "'MCP', 'WebRTC'", []string{"MCP", "WebRTC"}},
		{"strips backticks", "`MCP`, `WebRTC`", []string{"MCP", "WebRTC"}},
		{"dedupes case-insensitively keeping first", "MCP, mcp, MCp", []string{"MCP"}},
		{"drops numeric-only tokens", "MCP, 12345, 3.14, WebRTC", []string{"MCP", "WebRTC"}},
		{"keeps alphanumeric mixes", "MCP, ggml-tiny, v0.10.2rc", []string{"MCP", "ggml-tiny", "v0.10.2rc"}},
		{"strips quote-wrapped bullet", `"- MCP"`, []string{"MCP"}},
		{"strips quote-wrapped numbering", `"1. MCP"`, []string{"MCP"}},
		{"realistic LLM response with quoted bullets", `"- MCP", "- WebRTC"`, []string{"MCP", "WebRTC"}},
		{"strips doubled bullet markers", "- - MCP", []string{"MCP"}},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got := Sanitize(tc.in)
			if len(got) != len(tc.want) {
				t.Fatalf("Sanitize(%q) = %v, want %v", tc.in, got, tc.want)
			}
			for i := range got {
				if got[i] != tc.want[i] {
					t.Errorf("Sanitize(%q)[%d] = %q, want %q", tc.in, i, got[i], tc.want[i])
				}
			}
		})
	}
}

func TestSanitize_DropsOverLongTokens(t *testing.T) {
	long := strings.Repeat("a", MaxKeywordBytes+1)
	got := Sanitize("MCP, " + long + ", WebRTC")
	if len(got) != 2 || got[0] != "MCP" || got[1] != "WebRTC" {
		t.Errorf("Sanitize() = %v, want [MCP WebRTC]", got)
	}
}

func TestSanitize_KeepsTokenExactlyAtMaxLength(t *testing.T) {
	exact := strings.Repeat("a", MaxKeywordBytes)
	got := Sanitize(exact)
	if len(got) != 1 || got[0] != exact {
		t.Errorf("Sanitize() dropped a token of exactly MaxKeywordBytes")
	}
}

func TestSanitize_CapsAtMaxKeywords(t *testing.T) {
	parts := make([]string, MaxKeywords+10)
	for i := range parts {
		parts[i] = "Term" + string(rune('A'+i%26)) + string(rune('a'+i/26))
	}
	got := Sanitize(strings.Join(parts, ", "))
	if len(got) != MaxKeywords {
		t.Errorf("Sanitize() returned %d terms, want cap of %d", len(got), MaxKeywords)
	}
}

// TestSanitizeWithDrops_ReportsEachRejectionReason covers every reason
// the sanitizer can actually reject a candidate term. The list is
// derived from Sanitize's own control flow, not from a spec: the
// cleaned term being empty, exceeding MaxKeywordBytes, being
// numeric-only, being a case-insensitive duplicate of one already
// kept, and arriving after MaxKeywords have already been kept.
func TestSanitizeWithDrops_ReportsEachRejectionReason(t *testing.T) {
	t.Run("empty after stripping bullets and quotes", func(t *testing.T) {
		kept, dropped := SanitizeWithDrops(`MCP, "- ", WebRTC`)
		if len(kept) != 2 {
			t.Fatalf("kept = %v, want [MCP WebRTC]", kept)
		}
		if len(dropped) != 1 || dropped[0].Reason != DropEmpty {
			t.Fatalf("dropped = %+v, want one %q drop", dropped, DropEmpty)
		}
	})

	t.Run("over MaxKeywordBytes", func(t *testing.T) {
		long := strings.Repeat("a", MaxKeywordBytes+1)
		kept, dropped := SanitizeWithDrops("MCP, " + long + ", WebRTC")
		if len(kept) != 2 {
			t.Fatalf("kept = %v, want [MCP WebRTC]", kept)
		}
		if len(dropped) != 1 || dropped[0].Reason != DropTooLong || dropped[0].Term != long {
			t.Fatalf("dropped = %+v, want one %q drop carrying the term", dropped, DropTooLong)
		}
	})

	t.Run("numeric only", func(t *testing.T) {
		kept, dropped := SanitizeWithDrops("MCP, 12345, 3.14, WebRTC")
		if len(kept) != 2 {
			t.Fatalf("kept = %v, want [MCP WebRTC]", kept)
		}
		if len(dropped) != 2 {
			t.Fatalf("dropped = %+v, want two drops", dropped)
		}
		for _, d := range dropped {
			if d.Reason != DropNumeric {
				t.Errorf("drop %+v reason = %q, want %q", d, d.Reason, DropNumeric)
			}
		}
	})

	t.Run("case-insensitive duplicate", func(t *testing.T) {
		kept, dropped := SanitizeWithDrops("MCP, mcp, MCp")
		if len(kept) != 1 || kept[0] != "MCP" {
			t.Fatalf("kept = %v, want [MCP]", kept)
		}
		if len(dropped) != 2 {
			t.Fatalf("dropped = %+v, want two drops", dropped)
		}
		for _, d := range dropped {
			if d.Reason != DropDuplicate {
				t.Errorf("drop %+v reason = %q, want %q", d, d.Reason, DropDuplicate)
			}
		}
	})

	t.Run("past MaxKeywords cap", func(t *testing.T) {
		parts := make([]string, MaxKeywords+3)
		for i := range parts {
			parts[i] = fmt.Sprintf("Term%03d", i)
		}
		kept, dropped := SanitizeWithDrops(strings.Join(parts, ", "))
		if len(kept) != MaxKeywords {
			t.Fatalf("kept %d terms, want %d", len(kept), MaxKeywords)
		}
		if len(dropped) != 3 {
			t.Fatalf("dropped = %+v, want the 3 terms past the cap", dropped)
		}
		for i, d := range dropped {
			if d.Reason != DropKeywordCap {
				t.Errorf("drop %+v reason = %q, want %q", d, d.Reason, DropKeywordCap)
			}
			if want := parts[MaxKeywords+i]; d.Term != want {
				t.Errorf("drop[%d].Term = %q, want %q", i, d.Term, want)
			}
		}
	})
}

// TestSanitize_MatchesSanitizeWithDrops pins Sanitize to the new
// implementation: it must stay exactly the kept half of
// SanitizeWithDrops, including the nil-for-empty contract.
func TestSanitize_MatchesSanitizeWithDrops(t *testing.T) {
	inputs := []string{
		"",
		"   \n\t ",
		"MCP, WebRTC, SpeakerGate",
		"- MCP\n- mcp\n- 42\n- " + strings.Repeat("z", MaxKeywordBytes+1),
	}
	for _, in := range inputs {
		kept, _ := SanitizeWithDrops(in)
		got := Sanitize(in)
		if len(got) != len(kept) {
			t.Fatalf("Sanitize(%q) = %v, SanitizeWithDrops kept = %v", in, got, kept)
		}
		if got == nil && kept != nil {
			t.Errorf("Sanitize(%q) = nil but SanitizeWithDrops kept = %v", in, kept)
		}
		for i := range got {
			if got[i] != kept[i] {
				t.Errorf("Sanitize(%q)[%d] = %q, want %q", in, i, got[i], kept[i])
			}
		}
	}
}
