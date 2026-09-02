//go:build whispercpp

package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"context"
	"encoding/json"

	"github.com/voice-keyboard/core/internal/config"
	"github.com/voice-keyboard/core/internal/llm"
	"github.com/voice-keyboard/core/internal/screenctx"
	"github.com/voice-keyboard/core/internal/transcribe"
)

// howl_extract_keywords derives whisper biasing keywords from the text
// of the user's focused window, using the configured LLM provider.
//
// Input:  {"text": "..."}
// Output: {"raw": "...", "keywords": [...], "dropped": [{"term": "...", "reason": "..."}, ...]}
// or:     {"error": "..."}
//
// `raw` is the provider's response verbatim and `dropped` explains
// every candidate the sanitizer rejected — together they are the only
// way to tell "the model found nothing" apart from "the model found
// plenty and the sanitizer threw it all away". Diagnostic payload
// returned across the ABI for live display; neither is logged or
// written to a session file.
//
// BLOCKING — this makes a network call. Callers MUST invoke it off the
// main thread. It deliberately does not mutate engine state and does
// not hold e.mu across the network call. Free the result with
// howl_free_string.
//
//export howl_extract_keywords
func howl_extract_keywords(jsonC *C.char) *C.char {
	return C.CString(extractKeywordsJSON(C.GoString(jsonC)))
}

// howl_set_screen_keywords stores the keyword list for the next
// capture. Instant; no network. Returns 0 on success, 1 if the engine
// is not initialized, 2 on malformed JSON.
//
//export howl_set_screen_keywords
func howl_set_screen_keywords(jsonC *C.char) C.int {
	return C.int(setScreenKeywordsJSON(C.GoString(jsonC)))
}

// extractKeywordsJSON is the testable body of howl_extract_keywords.
func extractKeywordsJSON(in string) string {
	e := getEngine()
	if e == nil {
		return `{"error":"engine not initialized"}`
	}
	var req struct {
		Text string `json:"text"`
	}
	if err := json.Unmarshal([]byte(in), &req); err != nil {
		return errorJSON("invalid request json: " + err.Error())
	}

	// Snapshot the config so the network call below runs without
	// holding the engine lock.
	e.mu.Lock()
	cfg := e.cfg
	e.mu.Unlock()

	cleaner, err := e.screenExtractorFor(cfg)
	if err != nil {
		return errorJSON(err.Error())
	}
	ctx, cancel := context.WithTimeout(context.Background(), screenctx.ExtractTimeout)
	defer cancel()

	res, err := screenctx.Extract(ctx, cleaner, req.Text, cfg.CustomDict)
	if err != nil {
		return errorJSON(err.Error())
	}
	// Nil slices become [] so the caller always decodes arrays. `raw`
	// and `dropped` are additive: `keywords` keeps the shape and
	// meaning it has always had.
	if res.Keywords == nil {
		res.Keywords = []string{}
	}
	if res.Dropped == nil {
		res.Dropped = []screenctx.DroppedTerm{}
	}
	out, err := json.Marshal(res)
	if err != nil {
		return errorJSON(err.Error())
	}
	return string(out)
}

// extractorCacheKey identifies which config fields
// screenctx.NewExtractor actually depends on — the smallest comparable
// subset of config.Config, which itself isn't comparable (it holds a
// slice and a pointer, e.g. CustomDict and TSEThreshold).
type extractorCacheKey struct {
	provider string
	model    string
	baseURL  string
	apiKey   string
}

func extractorCacheKeyFor(cfg config.Config) extractorCacheKey {
	return extractorCacheKey{
		provider: cfg.LLMProvider,
		model:    cfg.LLMModel,
		baseURL:  cfg.LLMBaseURL,
		apiKey:   cfg.LLMAPIKey,
	}
}

// screenExtractorFor returns the cached screen-context Cleaner for cfg,
// building (and caching) a new one only when the relevant config fields
// have changed since the last call — so a settings change (provider,
// model, base URL, or API key) still rebuilds it.
//
// Deliberately does NOT hold extractorMu across screenctx.NewExtractor:
// that call can itself make a network round trip (Ollama/LM Studio's
// auto-detect hits /api/tags when no model is configured), and holding
// a lock across a network call is exactly the pattern the caller's own
// e.mu/cfg snapshot above already avoids. Two concurrent calls racing
// on a cold cache can each build once and the second write wins — a
// harmless, rare, self-correcting duplication, not a correctness issue.
func (e *engine) screenExtractorFor(cfg config.Config) (llm.Cleaner, error) {
	return e.extractorFor(cfg, &e.screenExtractor, &e.screenExtractorKey, screenctx.NewExtractor)
}

// screenImageExtractorFor is screenExtractorFor for the vision path.
// Same cache discipline, its own slot — see the engine field comment.
func (e *engine) screenImageExtractorFor(cfg config.Config) (llm.Cleaner, error) {
	return e.extractorFor(cfg, &e.screenImageExtractor, &e.screenImageExtractorKey, screenctx.NewImageExtractor)
}

// extractorFor is the shared cache body. cached and cachedKey address
// one slot on the engine; both are read and written only under
// extractorMu, which build is deliberately NOT called under.
func (e *engine) extractorFor(
	cfg config.Config,
	cached *llm.Cleaner,
	cachedKey *extractorCacheKey,
	build func(config.Config) (llm.Cleaner, error),
) (llm.Cleaner, error) {
	key := extractorCacheKeyFor(cfg)

	e.extractorMu.Lock()
	if *cached != nil && *cachedKey == key {
		cleaner := *cached
		e.extractorMu.Unlock()
		return cleaner, nil
	}
	e.extractorMu.Unlock()

	cleaner, err := build(cfg)
	if err != nil {
		return nil, err
	}

	e.extractorMu.Lock()
	*cached = cleaner
	*cachedKey = key
	e.extractorMu.Unlock()
	return cleaner, nil
}

// howl_screen_context_preview reports exactly how the next capture's
// whisper initial_prompt would be composed from the engine's current
// custom dictionary and stored screen keywords — the before/after of
// the whole biasing chain, up to and including the string whisper
// actually receives.
//
// Takes no argument: the inputs are engine state, not caller state.
// Mirrors howl_list_presets' no-arg/JSON-out shape rather than the
// JSON-in/JSON-out shape of the exports above, which need a request
// body.
//
// Output (all arrays always present, never null):
//
//	{"dictionary": [...],           // custom dictionary as configured
//	 "screen_keywords": [...],      // keywords as offered by the host
//	 "dictionary_bounded": [...],   // dictionary after the byte pre-filter
//	 "dictionary_applied": [...],   // dictionary terms in the prompt
//	 "screen_applied": [...],       // screen terms in the prompt
//	 "dropped": [{"term": "...", "source": "...", "stage": "..."}, ...],
//	 "prompt": "...",               // the exact initial_prompt
//	 "token_count": 0,              // whisper_token_count of that prompt
//	 "max_screen_prompt_tokens": 96,
//	 "max_prompt_tokens": 224}
//
// or {"error": "..."}.
//
// Instant; no network. Read-only — it composes through the same code
// SetContextPrompt uses but never assigns the prompt, so calling it
// cannot change what the next capture sees. Free the result with
// howl_free_string.
//
//export howl_screen_context_preview
func howl_screen_context_preview() *C.char {
	return C.CString(screenContextPreviewJSON())
}

// screenContextPreviewJSON is the testable body of
// howl_screen_context_preview.
func screenContextPreviewJSON() string {
	e := getEngine()
	if e == nil {
		return errorJSON("engine not initialized")
	}
	// Snapshot under e.mu and copy the slices: the composition below
	// walks them, and howl_configure / howl_set_screen_keywords can
	// replace either one concurrently.
	e.mu.Lock()
	pipe := e.pipeline
	dict := append([]string(nil), e.cfg.CustomDict...)
	screen := append([]string(nil), e.screenKeywords...)
	e.mu.Unlock()

	if pipe == nil {
		return errorJSON("pipeline not configured")
	}
	ps, ok := pipe.Transcriber.(transcribe.PromptSetter)
	if !ok {
		return errorJSON("transcriber does not support context prompts")
	}

	// NonNil so every array is an array on the wire; the plan's Go-side
	// nils are meaningful (SetContextPrompt returns nil for "no screen
	// term survived") but make for a fiddlier decode.
	out, err := json.Marshal(ps.PreviewContextPrompt(dict, screen).NonNil())
	if err != nil {
		return errorJSON(err.Error())
	}
	return string(out)
}

// setScreenKeywordsJSON is the testable body of howl_set_screen_keywords.
func setScreenKeywordsJSON(in string) int {
	e := getEngine()
	if e == nil {
		return 1
	}
	var req struct {
		Keywords []string `json:"keywords"`
	}
	if err := json.Unmarshal([]byte(in), &req); err != nil {
		e.setLastError("howl_set_screen_keywords: " + err.Error())
		return 2
	}
	e.mu.Lock()
	e.screenKeywords = req.Keywords
	e.mu.Unlock()
	return 0
}

// errorJSON renders an error response, never logging the window text
// that produced it.
func errorJSON(msg string) string {
	out, err := json.Marshal(map[string]string{"error": msg})
	if err != nil {
		return `{"error":"unknown"}`
	}
	return string(out)
}
