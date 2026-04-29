// Package transcribe provides ASR via whisper.cpp. The Transcriber
// interface accepts 16kHz mono float32 PCM and returns a UTF-8 string.
package transcribe

import "context"

type Transcriber interface {
	// Transcribe accepts mono 16kHz float32 PCM and returns the
	// recognized text. Empty audio (or audio detected as silence)
	// yields ("", nil) — silence is not an error.
	//
	// Implementations may or may not honor ctx cancellation; the v1
	// WhisperCpp impl does not (whisper_full is a blocking C call).
	// Callers should size audio buffers to bounded utterances rather
	// than rely on context-driven timeouts.
	Transcribe(ctx context.Context, pcm16k []float32) (string, error)

	// Close releases the underlying model. Safe to call multiple times.
	Close() error
}
