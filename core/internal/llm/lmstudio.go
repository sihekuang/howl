package llm

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"strings"
	"time"
)

const (
	// LM Studio's "OpenAI-compatible" REST surface lives under /v1 by
	// default on port 1234. The base URL therefore includes /v1 — both
	// /v1/models (used for auto-detect + listing) and /v1/chat/completions
	// (used by the OpenAI-compatible Cleaner) hang off it.
	lmStudioDefaultBaseURL = "http://localhost:1234/v1"
	// First request after a fresh server start can take seconds while LM
	// Studio JIT-loads the model into memory. Mirror Ollama's generous
	// default; subsequent requests are typically sub-second.
	lmStudioDefaultTimeout = 60 * time.Second
)

// LMStudioProvider is the registry entry for LM Studio. Local-only — no
// API key. LM Studio exposes an OpenAI-compatible REST API, so the
// Cleaner is just an *OpenAI built without an API key (Authorization
// header is omitted in that case; LM Studio ignores auth by default).
//
// DefaultModel is intentionally empty. When Options.Model is also empty,
// the factory queries /v1/models and auto-selects the first listed
// model. Pass Options.Model explicitly to disable auto-detect.
var LMStudioProvider = &Provider{
	Name:         "lmstudio",
	DefaultModel: "",
	NeedsAPIKey:  false,
	factory: func(opts Options) (Cleaner, error) {
		baseURL := opts.BaseURL
		if baseURL == "" {
			baseURL = lmStudioDefaultBaseURL
		}
		if opts.Model == "" {
			models, err := lmStudioListModels(baseURL, opts.Timeout)
			if err != nil {
				return nil, fmt.Errorf("lmstudio: model not specified and auto-detect failed: %w", err)
			}
			if len(models) == 0 {
				return nil, errors.New("lmstudio: model not specified and none available (load a model in LM Studio's UI, or pass --llm-model)")
			}
			opts.Model = models[0]
			log.Printf("[vkb] lmstudio: auto-detected model %q (use --llm-model to override; %d available)", opts.Model, len(models))
		}
		timeout := opts.Timeout
		if timeout == 0 {
			timeout = lmStudioDefaultTimeout
		}
		return newOpenAICompatible(OpenAIOptions{
			APIKey:  opts.APIKey, // typically empty; LM Studio ignores auth by default
			Model:   opts.Model,
			BaseURL: baseURL,
			Timeout: timeout,
		}, false)
	},
	listLocalModels: func(opts Options) ([]string, error) {
		return lmStudioListModels(opts.BaseURL, opts.Timeout)
	},
}

func init() {
	register(LMStudioProvider)
}

// lmStudioModelsResponse is the wire format for GET /v1/models. LM
// Studio mirrors OpenAI's `{"object":"list","data":[{"id":...},...]}`
// shape; we only need the id of each row.
type lmStudioModelsResponse struct {
	Data []struct {
		ID string `json:"id"`
	} `json:"data"`
}

// lmStudioListModels queries /v1/models and returns model ids in the
// order LM Studio returned them. Used by the factory's auto-detect
// path and by Provider.LocalModels for `vkb-cli providers --models`.
func lmStudioListModels(baseURL string, timeout time.Duration) ([]string, error) {
	if baseURL == "" {
		baseURL = lmStudioDefaultBaseURL
	}
	if timeout == 0 {
		// /v1/models is a cheap local lookup; short timeout so users see
		// a connection failure quickly rather than waiting 60s.
		timeout = 5 * time.Second
	}
	baseURL = strings.TrimRight(baseURL, "/")

	client := &http.Client{Timeout: timeout}
	req, err := http.NewRequest(http.MethodGet, baseURL+"/models", nil)
	if err != nil {
		return nil, fmt.Errorf("lmstudio: build models request: %w", err)
	}
	resp, err := client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("lmstudio: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		snippet, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
		return nil, fmt.Errorf("lmstudio: models HTTP %d: %s", resp.StatusCode, strings.TrimSpace(string(snippet)))
	}
	var page lmStudioModelsResponse
	if err := json.NewDecoder(resp.Body).Decode(&page); err != nil {
		return nil, fmt.Errorf("lmstudio: decode models: %w", err)
	}
	names := make([]string, 0, len(page.Data))
	for _, m := range page.Data {
		if m.ID != "" {
			names = append(names, m.ID)
		}
	}
	return names, nil
}
