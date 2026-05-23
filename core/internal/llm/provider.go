package llm

import (
	"errors"
	"fmt"
	"sort"
	"time"
)

// ErrNotSupported is returned by capability methods (e.g. Provider.LocalModels)
// for providers that don't implement the capability. Callers should check
// errors.Is(err, ErrNotSupported) to differentiate from real failures.
var ErrNotSupported = errors.New("not supported by this provider")

// Options is the union of fields any provider's constructor might want.
// Each provider's factory uses the subset it needs and ignores the rest.
// Default Timeout (when zero) is provider-specific.
type Options struct {
	Model   string        // model identifier — required for most providers
	APIKey  string        // required for cloud providers (Anthropic, OpenAI, ...)
	BaseURL string        // optional override (testing; non-default Ollama host)
	Timeout time.Duration // optional; provider's default if zero
}

// Provider describes an LLM cleaner backend: identity, default model, and
// the config it needs. The factory function (private) constructs a Cleaner
// from Options.
//
// Adding a provider is: (1) write the Cleaner impl; (2) instantiate a
// Provider value with the constructor wired into factory; (3) register it
// in providers below. Call sites (libhowl, howl) don't change.
type Provider struct {
	// Name is the identifier surfaced in flags, logs, and config
	// (config.LLMProvider value).
	Name string
	// DefaultModel is used when Options.Model is empty.
	DefaultModel string
	// NeedsAPIKey advertises whether Options.APIKey is required for
	// successful construction. Used by frontends to skip the API-key
	// prompt for providers that don't need one (Ollama).
	NeedsAPIKey bool
	// factory builds the actual Cleaner. Set internally; not part of
	// the public API surface.
	factory func(opts Options) (Cleaner, error)

	// listLocalModels enumerates models the provider can serve right now
	// (e.g. Ollama queries /api/tags for installed models). nil means the
	// provider doesn't support enumeration — Provider.LocalModels then
	// returns ErrNotSupported.
	listLocalModels func(opts Options) ([]string, error)
}

// New constructs a Cleaner for this provider using opts. Falls back to
// p.DefaultModel when opts.Model is empty. Provider factories can apply
// further fallbacks (e.g. Ollama auto-detects from /api/tags when the
// model is still unset).
func (p *Provider) New(opts Options) (Cleaner, error) {
	if p == nil {
		return nil, fmt.Errorf("llm: nil provider")
	}
	if opts.Model == "" {
		opts.Model = p.DefaultModel
	}
	if p.factory == nil {
		return nil, fmt.Errorf("llm: provider %q has no factory", p.Name)
	}
	return p.factory(opts)
}

// LocalModels enumerates models the provider can serve right now.
// Returns ErrNotSupported for providers that don't support enumeration
// (cloud providers whose model lists require auth or aren't queryable).
// Real failures (e.g. Ollama not running) are returned as-is so callers
// can distinguish "didn't ask" (ErrNotSupported) from "asked and failed".
func (p *Provider) LocalModels(opts Options) ([]string, error) {
	if p == nil {
		return nil, fmt.Errorf("llm: nil provider")
	}
	if p.listLocalModels == nil {
		return nil, ErrNotSupported
	}
	return p.listLocalModels(opts)
}

// providers is the registry, keyed by Name. Add new providers here.
// Each Provider value lives in its own implementation file (anthropic.go
// declares AnthropicProvider, etc.) to keep the registry list short.
var providers = map[string]*Provider{}

// register adds a provider to the registry. Providers call this from an
// init() in their implementation file. Panics on duplicate name — name
// collisions are programming errors, not runtime config mistakes.
func register(p *Provider) {
	if _, dup := providers[p.Name]; dup {
		panic(fmt.Sprintf("llm: duplicate provider name %q", p.Name))
	}
	providers[p.Name] = p
}

// Default is the provider used when LLMProvider is unset. Set by the
// implementation file of whichever provider should be the default
// (currently Anthropic).
var Default *Provider

// ProviderByName returns the registered provider with the given name. If
// name is empty, returns Default. Returns an error for unknown names.
func ProviderByName(name string) (*Provider, error) {
	if name == "" {
		if Default == nil {
			return nil, fmt.Errorf("llm: no default provider registered")
		}
		return Default, nil
	}
	p, ok := providers[name]
	if !ok {
		return nil, fmt.Errorf("llm: unknown provider %q", name)
	}
	return p, nil
}

// ProviderNames returns all registered provider names in sorted order.
func ProviderNames() []string {
	names := make([]string, 0, len(providers))
	for n := range providers {
		names = append(names, n)
	}
	sort.Strings(names)
	return names
}
