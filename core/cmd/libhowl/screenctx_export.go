//go:build whispercpp

package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"context"
	"encoding/json"

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

	cleaner, err := screenctx.NewExtractor(cfg)
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
