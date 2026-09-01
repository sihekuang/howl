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

	// ExtractTimeout bounds the provider call on the TEXT path.
	//
	// This is now the PRIMARY path, not a rare fallback: screen context
	// reads the window by screenshotting it and OCRing it locally, and
	// the OCR output goes here. So this timeout has to cover a realistic
	// payload -- up to MaxWindowTextBytes of recognised text -- and not
	// merely the short AX snippets it was originally sized for.
	//
	// Measured against ollama/qwen2.5:14b with an 8442-byte prompt (the
	// shipped prompt plus a full-cap OCR payload): 10.3s on the first
	// call, 1.6s once the prompt cache is warm. The old 5s therefore
	// timed out every first extraction and produced nothing, silently and
	// indistinguishably from "nothing on screen was worth extracting".
	//
	// 60s is deliberately generous for the same reason ExtractImageTimeout
	// is: the cost is lopsided. Too short kills the feature invisibly on
	// exactly the first impression a user gets. Too long costs at most one
	// queued call -- extraction runs off the dictation path, and the
	// coordinator cancels the previous in-flight task on every refresh.
	ExtractTimeout = 60 * time.Second
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

// ExtractResult is everything one extraction round trip produced: the
// model's response verbatim, the keywords that survived sanitizing,
// and every candidate that didn't (with the reason).
//
// Raw is kept deliberately. It is the only way to tell "the model
// returned nothing useful" apart from "the model returned plenty and
// the sanitizer rejected all of it" — the single most common question
// when screen-context biasing appears to do nothing. It is returned
// across the ABI for live display only; nothing writes it to disk or
// to the log.
type ExtractResult struct {
	// Raw is the provider's response exactly as received. The one
	// exception is the image path, which removes the VisionCanary
	// marker first — that marker is protocol between us and the model,
	// not something the model read on screen.
	Raw string `json:"raw"`
	// Keywords are the sanitized terms, in order. nil when none
	// survived — same contract as Sanitize.
	Keywords []string `json:"keywords"`
	// Dropped lists every rejected candidate and why. nil when none
	// were rejected.
	Dropped []DroppedTerm `json:"dropped"`
}

// Extract asks the provider for keywords describing windowText and
// returns the sanitized result alongside the raw response and the
// sanitizer's rejects. dictTerms are passed as the "already covered"
// list so the model doesn't spend the budget on duplicates.
//
// Returns a zero ExtractResult for empty input without calling the
// provider, and a zero ExtractResult with the error on provider
// failure.
func Extract(ctx context.Context, cleaner llm.Cleaner, windowText string, dictTerms []string) (ExtractResult, error) {
	text := truncateUTF8(strings.TrimSpace(windowText), MaxWindowTextBytes)
	if text == "" {
		return ExtractResult{}, nil
	}
	// Tagged so the provider's Clean implementation can tell this apart
	// from an ordinary dictation-cleanup call and adjust its own
	// logging — see llm.WithScreenContextSource's doc comment.
	raw, err := cleaner.Clean(llm.WithScreenContextSource(ctx), text, dictTerms)
	if err != nil {
		return ExtractResult{}, err
	}
	return extractResult(raw), nil
}

// extractResult turns a provider response into an ExtractResult. It is
// the convergence point of the text path and the image path (see
// ExtractImage): both call it immediately after the model responds, so
// there is exactly one implementation of "what happens to the model's
// answer" and the two paths cannot drift.
func extractResult(raw string) ExtractResult {
	kept, dropped := SanitizeWithDrops(raw)
	return ExtractResult{Raw: raw, Keywords: kept, Dropped: dropped}
}

// NewExtractor builds a keyword-extraction Cleaner from the configured
// provider. It reuses the cleanup provider's model and credentials but
// overrides the prompt template, so no new provider plumbing, HTTP
// client, or key handling is needed. The LLM cleanup stage is entirely
// unaffected — this is a separate Cleaner instance.
func NewExtractor(cfg config.Config) (llm.Cleaner, error) {
	return newExtractor(cfg, ExtractPrompt, ExtractTimeout)
}

// newExtractor is the shared body of NewExtractor and
// NewImageExtractor. The two differ only in prompt template and
// timeout; everything about how the provider is selected and
// credentialed is identical, and stays that way by construction.
func newExtractor(cfg config.Config, prompt string, timeout time.Duration) (llm.Cleaner, error) {
	provider, err := llm.ProviderByName(cfg.LLMProvider)
	if err != nil {
		return nil, err
	}
	opts := llm.Options{
		Model:   cfg.LLMModel,
		BaseURL: cfg.LLMBaseURL,
		Prompt:  prompt,
		Timeout: timeout,
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
