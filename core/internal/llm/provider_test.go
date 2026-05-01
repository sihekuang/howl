package llm

import (
	"context"
	"strings"
	"testing"
)

func TestProviderByName_EmptyReturnsDefault(t *testing.T) {
	p, err := ProviderByName("")
	if err != nil {
		t.Fatalf("ProviderByName(\"\"): %v", err)
	}
	if p != Default {
		t.Errorf("got %v, want Default", p)
	}
}

func TestProviderByName_KnownName(t *testing.T) {
	p, err := ProviderByName("anthropic")
	if err != nil {
		t.Fatalf("ProviderByName(anthropic): %v", err)
	}
	if p.Name != "anthropic" {
		t.Errorf("Name = %q, want anthropic", p.Name)
	}
	if !p.NeedsAPIKey {
		t.Errorf("anthropic should require API key")
	}
	if p.DefaultModel == "" {
		t.Errorf("anthropic should have a non-empty DefaultModel")
	}
}

func TestProviderByName_UnknownReturnsError(t *testing.T) {
	_, err := ProviderByName("nonexistent")
	if err == nil {
		t.Fatalf("expected error for unknown provider, got nil")
	}
	if !strings.Contains(err.Error(), "unknown provider") {
		t.Errorf("error %q does not mention 'unknown provider'", err)
	}
}

func TestProviderNames_IncludesAnthropicSorted(t *testing.T) {
	names := ProviderNames()
	if len(names) == 0 {
		t.Fatalf("ProviderNames returned empty")
	}
	found := false
	for _, n := range names {
		if n == "anthropic" {
			found = true
			break
		}
	}
	if !found {
		t.Errorf("ProviderNames %v missing 'anthropic'", names)
	}
	for i := 1; i < len(names); i++ {
		if names[i-1] > names[i] {
			t.Errorf("ProviderNames not sorted: %v", names)
			break
		}
	}
}

func TestProvider_NewMissingAPIKey(t *testing.T) {
	// Anthropic requires API key; calling New with empty Options should fail.
	_, err := AnthropicProvider.New(Options{})
	if err == nil {
		t.Fatalf("expected error for missing API key, got nil")
	}
}

func TestProvider_NewFillsDefaultModel(t *testing.T) {
	// Provider.New should fill in DefaultModel when Options.Model is empty.
	// We can't easily inspect what model Anthropic uses without making the
	// network call, so use a synthetic provider with a tracking factory.
	tracked := ""
	p := &Provider{
		Name:         "tracker",
		DefaultModel: "tracker-model-v1",
		factory: func(opts Options) (Cleaner, error) {
			tracked = opts.Model
			return passthroughForTest{}, nil
		},
	}
	_, _ = p.New(Options{Model: ""})
	if tracked != "tracker-model-v1" {
		t.Errorf("default model not applied: tracked=%q", tracked)
	}
	tracked = ""
	_, _ = p.New(Options{Model: "user-override"})
	if tracked != "user-override" {
		t.Errorf("user model overridden: tracked=%q", tracked)
	}
}

// passthroughForTest is a minimal Cleaner used only by the test above.
type passthroughForTest struct{}

func (passthroughForTest) Clean(_ context.Context, raw string, _ []string) (string, error) {
	return raw, nil
}
