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
)

// howl_extract_keywords derives whisper biasing keywords from the text
// of the user's focused window, using the configured LLM provider.
//
// Input:  {"text": "..."}
// Output: {"keywords": ["...", ...]} or {"error": "..."}
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

	kws, err := screenctx.Extract(ctx, cleaner, req.Text, cfg.CustomDict)
	if err != nil {
		return errorJSON(err.Error())
	}
	if kws == nil {
		kws = []string{}
	}
	out, err := json.Marshal(map[string][]string{"keywords": kws})
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
	key := extractorCacheKeyFor(cfg)

	e.extractorMu.Lock()
	if e.screenExtractor != nil && e.screenExtractorKey == key {
		cleaner := e.screenExtractor
		e.extractorMu.Unlock()
		return cleaner, nil
	}
	e.extractorMu.Unlock()

	cleaner, err := screenctx.NewExtractor(cfg)
	if err != nil {
		return nil, err
	}

	e.extractorMu.Lock()
	e.screenExtractor = cleaner
	e.screenExtractorKey = key
	e.extractorMu.Unlock()
	return cleaner, nil
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
