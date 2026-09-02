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

// StreamingCleaner is an optional extension: an LLM that can stream
// partial cleaned text back as it generates. Each onDelta call carries
// the next chunk of text (typically a few characters to a few words).
// The pipeline accumulates the deltas to build the final cleaned text;
// the host (Swift app) types them at the cursor as they arrive,
// turning end-to-end latency from "wait for the whole response" into
// "wait for the first token".
//
// Implementations that don't support streaming should NOT implement
// this interface — pipeline detects via type assertion and falls back
// to the synchronous Clean path.
type StreamingCleaner interface {
	Cleaner
	CleanStream(
		ctx context.Context,
		raw string,
		preserveTerms []string,
		onDelta func(string),
	) (string, error)
}

// callSource is a private context-key type for tagging *why* Clean is
// being called, so provider implementations can adjust their own
// logging without the Cleaner interface (and therefore every call
// site and test that constructs one) needing to change. Kept
// unexported per the standard context-key pattern to avoid collisions
// with keys other packages might set on the same context.
type callSource int

const screenContextSourceKey callSource = iota

// WithScreenContextSource marks ctx as belonging to a screen-context
// keyword extraction call rather than an ordinary dictation-cleanup
// call. screenctx.Extract reuses the configured provider's Cleaner
// (see screenctx.NewExtractor's doc comment) — same Clean method, same
// log lines — so without this tag, every window focus change would be
// indistinguishable in the log from an actual dictation cleanup,
// including logging the byte length of the focused window's text.
func WithScreenContextSource(ctx context.Context) context.Context {
	return context.WithValue(ctx, screenContextSourceKey, true)
}

// IsScreenContextSource reports whether ctx was tagged by
// WithScreenContextSource.
func IsScreenContextSource(ctx context.Context) bool {
	v, _ := ctx.Value(screenContextSourceKey).(bool)
	return v
}
