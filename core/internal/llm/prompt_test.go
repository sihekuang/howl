package llm

import (
	"strings"
	"testing"
)

func TestRenderPrompt_BasicSubstitution(t *testing.T) {
	got := renderPrompt(DefaultPrompt, "hello world um yeah", []string{"MCP", "WebRTC"})
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
	got := renderPrompt(DefaultPrompt, "hello", nil)
	if !strings.Contains(got, "Preserve technical terms verbatim:") {
		t.Errorf("prompt missing terms section even when empty:\n%s", got)
	}
	if !strings.Contains(got, "(none)") {
		t.Errorf("expected (none) when no terms:\n%s", got)
	}
}

func TestRenderPrompt_CustomNoVerbs(t *testing.T) {
	got := renderPrompt("Fix grammar only.", "hello world", []string{"Go"})
	if !strings.Contains(got, "Fix grammar only.") {
		t.Errorf("prompt missing custom text:\n%s", got)
	}
	if !strings.Contains(got, "Preserve these terms verbatim: Go") {
		t.Errorf("prompt missing appended terms:\n%s", got)
	}
	if !strings.Contains(got, "Raw transcription:\nhello world") {
		t.Errorf("prompt missing appended raw text:\n%s", got)
	}
}

func TestRenderPrompt_CustomOneVerb(t *testing.T) {
	got := renderPrompt("Keep these words: %s\nClean it up.", "hello world", []string{"API"})
	if !strings.Contains(got, "Keep these words: API") {
		t.Errorf("prompt missing substituted terms:\n%s", got)
	}
	if !strings.Contains(got, "Raw transcription:\nhello world") {
		t.Errorf("prompt missing appended raw text:\n%s", got)
	}
}
