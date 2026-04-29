// Package llm provides the LLM cleanup step that removes filler words and
// fixes grammar in raw transcriptions. The Cleaner interface is the
// extension point: v1 ships an Anthropic impl; OpenAI/Ollama in Phase 2.
package llm

import "context"

type Cleaner interface {
	// Clean takes a raw transcription and a list of custom terms that
	// must be preserved verbatim, returns the cleaned text. On any
	// error (network, auth, rate limit) the caller should fall back
	// to the original raw text — never lose the user's words.
	Clean(ctx context.Context, raw string, preserveTerms []string) (string, error)
}
