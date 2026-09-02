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
	// real token window. Returns the screen-derived terms that actually
	// survived trimming and made it into the prompt — NOT the input
	// screenTerms. Callers must record the returned slice (not the
	// input) in the session manifest, so the manifest reflects what
	// biased whisper rather than what was merely offered.
	//
	// The only guarantee callers actually get is "no audio is currently
	// being pushed for a new capture" (`howl_start_capture`'s `pushCh
	// == nil` check) — NOT "no Transcribe is in flight" on this
	// instance. The previous capture's pipeline goroutine (whisper
	// drain + LLM cleanup) can still be running when this is called
	// for the next one; implementations must guard their own mutable
	// state accordingly (see WhisperCpp.initialPrompt's `w.mu`). Note
	// too that the caller's own bookkeeping of this call's return value
	// (`pipe.ScreenKeywords`, used for the session manifest) lives on
	// an object shared across captures, so a still-running previous
	// capture can have its manifest overwritten by this one's result —
	// see the comment at the `howl_start_capture` call site.
	SetContextPrompt(dictTerms, screenTerms []string) []string

	// PreviewContextPrompt composes exactly what SetContextPrompt would
	// compose for the same inputs and returns the full plan — the
	// byte-bounded dictionary, the surviving terms, everything dropped
	// and at which stage, the resulting prompt, its real token count,
	// and the caps — WITHOUT mutating the transcriber. Purely a
	// diagnostic read path.
	//
	// Implementations MUST route both this and SetContextPrompt through
	// one composition. The point of the preview is to show what whisper
	// actually receives; a preview computed by separate code would
	// drift from reality and mislead exactly when someone is using it
	// to debug recognition.
	//
	// Not free: it repeats the same whisper_token_count work
	// SetContextPrompt does. Call it for diagnostics, not per frame.
	PreviewContextPrompt(dictTerms, screenTerms []string) ContextPromptPlan
}
