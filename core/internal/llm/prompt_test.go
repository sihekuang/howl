package llm

import (
	"strings"
	"testing"
)

func TestRenderPrompt_BasicSubstitution(t *testing.T) {
	got := renderPrompt("hello world um yeah", []string{"MCP", "WebRTC"})
	if !strings.Contains(got, "hello world um yeah") {
		t.Errorf("prompt missing raw text:\n%s", got)
	}
	if !strings.Contains(got, "MCP, WebRTC") {
		t.Errorf("prompt missing preserve terms:\n%s", got)
	}
	if !strings.Contains(got, "Remove filler words") {
		t.Errorf("prompt missing instructions:\n%s", got)
	}
}

func TestRenderPrompt_NoTerms(t *testing.T) {
	got := renderPrompt("hello", nil)
	if !strings.Contains(got, "Preserve technical terms exactly as listed:") {
		t.Errorf("prompt missing terms section even when empty:\n%s", got)
	}
	// when terms list is empty, render with the literal "(none)"
	if !strings.Contains(got, "(none)") {
		t.Errorf("expected (none) when no terms:\n%s", got)
	}
}
