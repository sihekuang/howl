//go:build whispercpp

package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"context"
	"encoding/json"
	"errors"
	"log"
	"unsafe"

	"github.com/voice-keyboard/core/internal/llm"
	"github.com/voice-keyboard/core/internal/screenctx"
)

// howl_extract_keywords_image derives whisper biasing keywords from a
// screenshot of the user's focused window, by asking the configured LLM
// provider's VISION model to read it directly. It replaces the host's
// OCR step: the model does the reading.
//
// Input:  a pointer to the encoded image and its length in bytes. PNG,
//
//	JPEG, GIF and WebP are accepted; the media type is sniffed
//	from the bytes, so the host never has to declare it and can
//	never mislabel it.
//
//	Raw bytes rather than base64-in-JSON deliberately: base64
//	inflates the payload ~33% on something sent once per
//	debounced focus change. The string-in/string-out shape of
//	howl_extract_keywords is right for text and wrong for this.
//
// Output: the same envelope howl_extract_keywords returns, plus one
//
//	        additive key:
//
//		{"raw": "...", "keywords": [...],
//		 "dropped": [{"term": "...", "reason": "..."}, ...],
//		 "no_vision": false}
//
// or, on failure:
//
//	{"error": "...", "no_vision": true|false}
//
// `no_vision` is the empirical capability verdict. true means this
// (provider, model) pair was found to reject images — the host should
// fall back to the Accessibility text path and howl_extract_keywords
// for as long as those settings are in force. It is NEVER true for a
// timeout, a rate limit, an auth failure, or a malformed image: those
// are ordinary failures and the host should keep using this export.
//
// The verdict is cached in memory for the process lifetime, keyed on
// the configured provider and model, so a settings change re-probes and
// a restart forgets. A subsequent call with a cached verdict returns
// no_vision immediately without a network round trip.
//
// BLOCKING — this makes a network call. Callers MUST invoke it off the
// main thread. Like howl_extract_keywords it does not mutate engine
// state and does not hold e.mu across the network call. Free the result
// with howl_free_string.
//
//export howl_extract_keywords_image
func howl_extract_keywords_image(bytes *C.uchar, length C.int) *C.char {
	if bytes == nil || length <= 0 {
		return C.CString(imageErrorJSON("empty image", false))
	}
	// Copy out of C memory before any Go-side work — same rule as
	// howl_push_audio; the caller may free or reuse its buffer the
	// instant this returns, and the network call below outlives it.
	return C.CString(extractKeywordsImageJSON(C.GoBytes(unsafe.Pointer(bytes), length)))
}

// imageExtractResponse is the success envelope: screenctx.ExtractResult
// embedded so `raw`, `keywords` and `dropped` keep exactly the names,
// order and meaning howl_extract_keywords gives them, plus the additive
// capability flag.
type imageExtractResponse struct {
	screenctx.ExtractResult
	NoVision bool `json:"no_vision"`
}

// imageErrorJSON is errorJSON for this export: the same {"error": ...}
// shape, carrying the capability verdict alongside so the host can tell
// "use the text path from now on" from "that just failed, try again".
func imageErrorJSON(msg string, noVision bool) string {
	out, err := json.Marshal(struct {
		Error    string `json:"error"`
		NoVision bool   `json:"no_vision"`
	}{Error: msg, NoVision: noVision})
	if err != nil {
		return `{"error":"unknown","no_vision":false}`
	}
	return string(out)
}

// extractKeywordsImageJSON is the testable body of
// howl_extract_keywords_image.
func extractKeywordsImageJSON(data []byte) string {
	e := getEngine()
	if e == nil {
		return imageErrorJSON("engine not initialized", false)
	}
	if len(data) == 0 {
		return imageErrorJSON("empty image", false)
	}
	// Sniff before anything else: bad bytes must cost neither a
	// provider round trip nor a capability verdict.
	mediaType, err := llm.DetectImageMediaType(data)
	if err != nil {
		return imageErrorJSON(err.Error(), false)
	}

	// Snapshot the config so the network call below runs without
	// holding the engine lock — same discipline as
	// extractKeywordsJSON.
	e.mu.Lock()
	cfg := e.cfg
	e.mu.Unlock()

	key := screenctx.VisionKeyFor(cfg)
	if screenctx.IsTextOnly(key) {
		// Already probed and rejected. One wasted request per model
		// change is the price of empirical detection; one per focus
		// change is not.
		return imageErrorJSON("model does not accept image input (cached verdict)", true)
	}

	cleaner, err := e.screenImageExtractorFor(cfg)
	if err != nil {
		// A construction failure is a config or connectivity problem
		// (unknown provider, Ollama not running), never a statement
		// about the model's capabilities.
		return imageErrorJSON(err.Error(), false)
	}
	ctx, cancel := context.WithTimeout(context.Background(), screenctx.ExtractImageTimeout)
	defer cancel()

	res, err := screenctx.ExtractImage(ctx, cleaner, llm.Image{Data: data, MediaType: mediaType}, cfg.CustomDict)
	if err != nil {
		if errors.Is(err, llm.ErrNoVision) {
			screenctx.MarkTextOnly(key)
			// Worth one line: this silently changes which path the
			// host uses for the rest of the session, and the cache
			// means it fires once per (provider, model), not once per
			// focus change.
			//
			// Deliberately does NOT log err. On the provider-rejection
			// branch err embeds the provider's HTTP response body,
			// which can quote back the request — and therefore the
			// user's screen. The provider and model are the whole
			// diagnostic; the detail goes to the caller over the ABI,
			// which is not the log.
			log.Printf("[howl] screenctx: vision disabled for provider=%s model=%s; host should fall back to the text path",
				key.Provider, key.Model)
			return imageErrorJSON(err.Error(), true)
		}
		return imageErrorJSON(err.Error(), false)
	}
	// Nil slices become [] so the caller always decodes arrays —
	// identical to extractKeywordsJSON.
	if res.Keywords == nil {
		res.Keywords = []string{}
	}
	if res.Dropped == nil {
		res.Dropped = []screenctx.DroppedTerm{}
	}
	out, err := json.Marshal(imageExtractResponse{ExtractResult: res})
	if err != nil {
		return imageErrorJSON(err.Error(), false)
	}
	return string(out)
}
