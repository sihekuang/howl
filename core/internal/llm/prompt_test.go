package llm

import (
	"strings"
	"testing"
)

func TestRenderPrompt_BasicSubstitution(t *testing.T) {
	got := RenderPrompt(DefaultPrompt, "hello world um yeah", []string{"MCP", "WebRTC"})
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
	got := RenderPrompt(DefaultPrompt, "hello", nil)
	if !strings.Contains(got, "Preserve technical terms verbatim:") {
		t.Errorf("prompt missing terms section even when empty:\n%s", got)
	}
	if !strings.Contains(got, "(none)") {
		t.Errorf("expected (none) when no terms:\n%s", got)
	}
}

func TestRenderPrompt_CustomNoPlaceholders(t *testing.T) {
	got := RenderPrompt("Fix grammar only.", "hello world", []string{"Go"})
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

func TestRenderPrompt_CustomWithPlaceholders(t *testing.T) {
	got := RenderPrompt("Keep: {{dictionary}}\nText: {{transcription}}", "hello world", []string{"API"})
	if !strings.Contains(got, "Keep: API") {
		t.Errorf("prompt missing substituted terms:\n%s", got)
	}
	if !strings.Contains(got, "Text: hello world") {
		t.Errorf("prompt missing substituted transcription:\n%s", got)
	}
}

func TestRenderPrompt_DictionaryOnly(t *testing.T) {
	got := RenderPrompt("Preserve: {{dictionary}}", "hello world", []string{"Go"})
	if !strings.Contains(got, "Preserve: Go") {
		t.Errorf("prompt missing substituted terms:\n%s", got)
	}
	if !strings.Contains(got, "Raw transcription:\nhello world") {
		t.Errorf("prompt missing appended raw text:\n%s", got)
	}
}

func TestRenderPrompt_PlaceholdersNotInOutput(t *testing.T) {
	got := RenderPrompt(DefaultPrompt, "test input", []string{"Foo"})
	if strings.Contains(got, "{{dictionary}}") {
		t.Errorf("placeholder {{dictionary}} not replaced:\n%s", got)
	}
	if strings.Contains(got, "{{transcription}}") {
		t.Errorf("placeholder {{transcription}} not replaced:\n%s", got)
	}
}
