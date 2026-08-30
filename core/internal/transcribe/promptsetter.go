package transcribe

// MaxPromptTokens is whisper's real initial-prompt window
// (n_text_ctx/2). Whisper silently keeps only the LAST MaxPromptTokens
// tokens of a longer prompt, so exceeding it does not error — it
// quietly discards the head of the prompt.
const MaxPromptTokens = 224

// PromptSetter is an optional Transcriber extension for backends that
// can re-bias per capture. Detected via type assertion, mirroring the
// StreamingCleaner pattern in the llm package, so Transcriber
// implementations that don't support it (test fakes, future backends)
// need no changes.
type PromptSetter interface {
	// SetContextPrompt recomposes the initial prompt from the custom
	// dictionary and screen-derived keywords, trimming to whisper's
	// real token window. Must not be called while a Transcribe is in
	// flight on the same instance.
	SetContextPrompt(dictTerms, screenTerms []string)
}
