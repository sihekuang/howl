package screenctx

import (
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
