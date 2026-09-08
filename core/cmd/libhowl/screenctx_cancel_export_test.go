//go:build whispercpp

package main

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

// The Swift coordinator cancels a superseded refresh cooperatively,
// which the blocking C call cannot observe — so the Go request kept
// running to its 60s timeout while a fresh one started behind it
// (three in flight at once was measured on 2026-09-08). This export is
// how the host aborts the request for real.
func TestCancelExtractKeywords_AbortsTheInFlightRequest(t *testing.T) {
	resetEngineForTest(t)

	// An Ollama whose /api/chat never answers until the client goes
	// away. /api/tags must still answer: the provider probes it on
	// construction, before any extraction exists to cancel.
	reached := make(chan struct{}, 1)
	mux := http.NewServeMux()
	mux.HandleFunc("/api/tags", func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`{"models":[]}`))
	})
	mux.HandleFunc("/api/chat", func(w http.ResponseWriter, r *http.Request) {
		// Drain the body first, as a real server would: net/http only
		// watches for the client going away once the body is consumed,
		// so without this the context would never be cancelled.
		_, _ = io.Copy(io.Discard, r.Body)
		reached <- struct{}{}
		<-r.Context().Done()
	})
	srv := httptest.NewServer(mux)
	defer srv.Close()

	e := getEngine()
	e.mu.Lock()
	e.cfg.LLMProvider = "ollama"
	e.cfg.LLMModel = "any"
	e.cfg.LLMBaseURL = srv.URL
	e.mu.Unlock()

	done := make(chan string, 1)
	go func() { done <- extractKeywordsJSON(`{"text":"hello world"}`) }()

	select {
	case <-reached:
	case <-time.After(5 * time.Second):
		t.Fatal("the extraction never reached the provider")
	}
	cancelExtractKeywords()

	select {
	case out := <-done:
		var resp struct {
			Error string `json:"error"`
		}
		if err := json.Unmarshal([]byte(out), &resp); err != nil {
			t.Fatalf("response is not JSON: %v (%s)", err, out)
		}
		if resp.Error == "" {
			t.Errorf("a cancelled extraction must report an error, got %s", out)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("extraction did not return after cancel — the request is still running")
	}
}

func TestCancelExtractKeywords_IsHarmlessWhenNothingIsInFlight(t *testing.T) {
	resetEngineForTest(t)
	cancelExtractKeywords() // must not panic or block
}
