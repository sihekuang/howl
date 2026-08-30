package screenctx

import (
	"context"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/voice-keyboard/core/internal/config"
	"github.com/voice-keyboard/core/internal/llm"
)

const (
	// MaxWindowTextBytes bounds what leaves the process. Window text can
	// be arbitrarily large; this caps both cost and latency.
	MaxWindowTextBytes = 8192

	// ExtractTimeout bounds the provider call. Extraction is a
	// best-effort background enhancement — it must never outlive the
	// user's interest in the window it describes.
	ExtractTimeout = 5 * time.Second
)

// ExtractPrompt is the template handed to llm.Options.Prompt. It MUST
// contain both {{transcription}} and {{dictionary}}: llm.RenderPrompt
// appends its own cleanup-flavoured trailer for any placeholder it
// doesn't find, which would corrupt this instruction.
const ExtractPrompt = `You extract vocabulary hints for a speech-recognition system. Below is the text currently visible in the user's focused window. The user is about to dictate while looking at it.

List the words and phrases a speech recogniser is most likely to get wrong: proper nouns, people's names, product and project names, code identifiers, acronyms, filenames, and domain jargon.

Hard rules:
- Return ONLY a comma-separated list. No preamble, no numbering, no explanation.
- At most 20 items, most useful first.
- Every item must appear verbatim in the window text. Do not invent, translate, or correct.
- Skip ordinary English words a recogniser already handles.
- Skip anything resembling a secret, password, API key, or token.
- These terms are already covered — do NOT repeat them: {{dictionary}}
- If nothing qualifies, return an empty string.

Window text:
{{transcription}}`

// Extract asks the provider for keywords describing windowText and
// returns the sanitized result. dictTerms are passed as the "already
// covered" list so the model doesn't spend the budget on duplicates.
//
// Returns (nil, nil) for empty input without calling the provider.
func Extract(ctx context.Context, cleaner llm.Cleaner, windowText string, dictTerms []string) ([]string, error) {
	text := truncateUTF8(strings.TrimSpace(windowText), MaxWindowTextBytes)
	if text == "" {
		return nil, nil
	}
	// Tagged so the provider's Clean implementation can tell this apart
	// from an ordinary dictation-cleanup call and adjust its own
	// logging — see llm.WithScreenContextSource's doc comment.
	raw, err := cleaner.Clean(llm.WithScreenContextSource(ctx), text, dictTerms)
	if err != nil {
		return nil, err
	}
	return Sanitize(raw), nil
}

// NewExtractor builds a keyword-extraction Cleaner from the configured
// provider. It reuses the cleanup provider's model and credentials but
// overrides the prompt template, so no new provider plumbing, HTTP
// client, or key handling is needed. The LLM cleanup stage is entirely
// unaffected — this is a separate Cleaner instance.
func NewExtractor(cfg config.Config) (llm.Cleaner, error) {
	provider, err := llm.ProviderByName(cfg.LLMProvider)
	if err != nil {
		return nil, err
	}
	opts := llm.Options{
		Model:   cfg.LLMModel,
		BaseURL: cfg.LLMBaseURL,
		Prompt:  ExtractPrompt,
		Timeout: ExtractTimeout,
	}
	if provider.NeedsAPIKey {
		opts.APIKey = cfg.LLMAPIKey
	}
	return provider.New(opts)
}

// truncateUTF8 cuts s to at most max bytes on a rune boundary.
func truncateUTF8(s string, max int) string {
	if len(s) <= max {
		return s
	}
	cut := max
	for cut > 0 && !utf8.RuneStart(s[cut]) {
		cut--
	}
	return strings.TrimSpace(s[:cut])
}
