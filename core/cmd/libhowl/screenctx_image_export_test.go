//go:build whispercpp

package main

import (
	"bytes"
	"encoding/json"
	"image"
	"image/color"
	"image/png"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/voice-keyboard/core/internal/config"
	"github.com/voice-keyboard/core/internal/screenctx"
)

// imageResponse is the wire contract Part 2 (Swift) decodes: the
// existing envelope plus the additive no_vision flag.
type imageResponse struct {
	Raw      string   `json:"raw"`
	Keywords []string `json:"keywords"`
	Dropped  []struct {
		Term   string `json:"term"`
		Reason string `json:"reason"`
	} `json:"dropped"`
	Error    string `json:"error"`
	NoVision bool   `json:"no_vision"`
}

func decodeImageResponse(t *testing.T, out string) imageResponse {
	t.Helper()
	if !json.Valid([]byte(out)) {
		t.Fatalf("response is not valid JSON: %s", out)
	}
	var resp imageResponse
	if err := json.Unmarshal([]byte(out), &resp); err != nil {
		t.Fatalf("decode: %v (%s)", err, out)
	}
	return resp
}

func TestExtractKeywordsImage_EmptyImageReturnsErrorJSON(t *testing.T) {
	resetEngineForTest(t)
	resp := decodeImageResponse(t, extractKeywordsImageJSON(nil))
	if resp.Error == "" {
		t.Errorf("expected an error field for empty image bytes")
	}
	if resp.NoVision {
		t.Errorf("empty input is not a model capability verdict")
	}
}

// Bytes that aren't an image at all must fail before any network call
// and must NOT be recorded as a no-vision model.
func TestExtractKeywordsImage_NonImageBytesRejected(t *testing.T) {
	resetEngineForTest(t)
	resp := decodeImageResponse(t, extractKeywordsImageJSON([]byte("definitely not an image")))
	if resp.Error == "" {
		t.Errorf("expected an error field for non-image bytes")
	}
	if resp.NoVision {
		t.Errorf("undecodable bytes must not be reported as no_vision")
	}
}

func TestExtractKeywordsImage_UnknownProviderReturnsErrorJSON(t *testing.T) {
	resetEngineForTest(t)
	e := getEngine()
	e.mu.Lock()
	e.cfg.LLMProvider = "nope"
	e.cfg.LLMModel = "unknown-provider-model"
	e.mu.Unlock()

	resp := decodeImageResponse(t, extractKeywordsImageJSON(tinyPNG(t)))
	if resp.Error == "" {
		t.Errorf("expected an error field, got no_vision=%v", resp.NoVision)
	}
	if resp.NoVision {
		t.Errorf("an unknown provider is a config error, not a no-vision verdict")
	}
}

// A (provider, model) already known to be text-only must short-circuit
// — the whole point of caching the verdict is one wasted round trip,
// not one per focus change.
func TestExtractKeywordsImage_CachedTextOnlyShortCircuits(t *testing.T) {
	resetEngineForTest(t)
	e := getEngine()
	cfg := config.Config{LLMProvider: "ollama", LLMModel: "text-only-fixture"}
	e.mu.Lock()
	e.cfg = cfg
	e.mu.Unlock()
	screenctx.MarkTextOnly(screenctx.VisionKeyFor(cfg))

	resp := decodeImageResponse(t, extractKeywordsImageJSON(tinyPNG(t)))
	if !resp.NoVision {
		t.Errorf("no_vision = false for a model already recorded as text-only (%s)", resp.Error)
	}
	if resp.Error == "" {
		t.Errorf("a no-vision verdict is still a failure for this call; expected an error field")
	}
}

// tinyPNG is a genuinely valid PNG so the export's media-type sniff
// succeeds and the test exercises the path past it.
func tinyPNG(t *testing.T) []byte {
	t.Helper()
	img := image.NewRGBA(image.Rect(0, 0, 2, 2))
	img.Set(0, 0, color.RGBA{R: 255, A: 255})
	var buf bytes.Buffer
	if err := png.Encode(&buf, img); err != nil {
		t.Fatalf("png.Encode: %v", err)
	}
	return buf.Bytes()
}

// fakeVisionOllama serves /api/chat with a canned keyword list, so the
// export can be driven end-to-end without a real model.
func fakeVisionOllama(t *testing.T, reply string) *httptest.Server {
	t.Helper()
	mux := http.NewServeMux()
	mux.HandleFunc("/api/chat", func(w http.ResponseWriter, r *http.Request) {
		var body map[string]any
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			t.Errorf("decode req: %v", err)
		}
		msgs, _ := body["messages"].([]any)
		if len(msgs) != 1 {
			t.Errorf("messages = %v", body["messages"])
		} else if msg, _ := msgs[0].(map[string]any); len(msg["images"].([]any)) != 1 {
			t.Errorf("expected exactly one image on the message, got %v", msg["images"])
		}
		_, _ = w.Write([]byte(`{"message":{"role":"assistant","content":` +
			string(mustJSON(t, reply)) + `},"done":true}`))
	})
	return httptest.NewServer(mux)
}

func mustJSON(t *testing.T, v any) []byte {
	t.Helper()
	b, err := json.Marshal(v)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	return b
}

// The success envelope is the contract Part 2 decodes. It must carry
// raw / keywords / dropped with exactly the names and meanings
// howl_extract_keywords gives them, arrays never null, plus the
// additive no_vision flag.
func TestExtractKeywordsImage_SuccessEnvelopeMatchesTextExport(t *testing.T) {
	resetEngineForTest(t)
	// The marker proves the model saw the image; it is stripped before
	// anything downstream, so the assertions below — Raw included —
	// are written as if it were never there.
	srv := fakeVisionOllama(t, screenctx.VisionCanary+", SpeakerGate, DeepFilterNet, speakergate, 1234")
	defer srv.Close()

	e := getEngine()
	e.mu.Lock()
	e.cfg = config.Config{
		LLMProvider: "ollama",
		LLMModel:    "llava-envelope-fixture",
		LLMBaseURL:  srv.URL,
		CustomDict:  []string{"MCP"},
	}
	e.mu.Unlock()

	out := extractKeywordsImageJSON(tinyPNG(t))
	resp := decodeImageResponse(t, out)
	if resp.Error != "" {
		t.Fatalf("unexpected error: %s", resp.Error)
	}
	if resp.NoVision {
		t.Errorf("no_vision must be false on success")
	}
	if resp.Raw != "SpeakerGate, DeepFilterNet, speakergate, 1234" {
		t.Errorf("raw = %q, want the provider response verbatim", resp.Raw)
	}
	if len(resp.Keywords) != 2 || resp.Keywords[0] != "SpeakerGate" || resp.Keywords[1] != "DeepFilterNet" {
		t.Errorf("keywords = %v", resp.Keywords)
	}
	if len(resp.Dropped) != 2 {
		t.Fatalf("dropped = %v, want the duplicate and the numeric term", resp.Dropped)
	}
	if resp.Dropped[0].Reason != "duplicate" || resp.Dropped[1].Reason != "numeric" {
		t.Errorf("dropped = %v", resp.Dropped)
	}

	// Every key the text export emits must be present and an array,
	// never null — the Swift inspector decodes them unconditionally.
	var keys map[string]json.RawMessage
	if err := json.Unmarshal([]byte(out), &keys); err != nil {
		t.Fatalf("decode: %v", err)
	}
	for _, k := range []string{"raw", "keywords", "dropped", "no_vision"} {
		if _, ok := keys[k]; !ok {
			t.Errorf("response is missing key %q: %s", k, out)
		}
	}
	if string(keys["keywords"]) == "null" || string(keys["dropped"]) == "null" {
		t.Errorf("arrays must never be null: %s", out)
	}
}

// An empty keyword list still has to decode as arrays, not nulls.
func TestExtractKeywordsImage_EmptyResultStillEmitsArrays(t *testing.T) {
	resetEngineForTest(t)
	srv := fakeVisionOllama(t, "   ")
	defer srv.Close()

	e := getEngine()
	e.mu.Lock()
	e.cfg = config.Config{LLMProvider: "ollama", LLMModel: "llava-empty-fixture", LLMBaseURL: srv.URL}
	e.mu.Unlock()

	// An all-whitespace response is an error from the provider layer
	// ("ollama: empty response"), so this asserts the failure envelope
	// rather than a success one — and, crucially, that it is not
	// mistaken for a capability verdict.
	resp := decodeImageResponse(t, extractKeywordsImageJSON(tinyPNG(t)))
	if resp.NoVision {
		t.Errorf("an empty model response is not a no-vision verdict")
	}
}

// The verdict must be recorded on the FIRST rejection, so the second
// call short-circuits instead of paying another round trip.
func TestExtractKeywordsImage_RejectionIsCachedAfterOneProbe(t *testing.T) {
	resetEngineForTest(t)
	var hits int
	mux := http.NewServeMux()
	mux.HandleFunc("/api/chat", func(w http.ResponseWriter, _ *http.Request) {
		hits++
		w.WriteHeader(http.StatusBadRequest)
		_, _ = w.Write([]byte(`{"error":"model 'llama3.2' does not support images"}`))
	})
	srv := httptest.NewServer(mux)
	defer srv.Close()

	e := getEngine()
	e.mu.Lock()
	e.cfg = config.Config{LLMProvider: "ollama", LLMModel: "llava-rejection-fixture", LLMBaseURL: srv.URL}
	e.mu.Unlock()

	first := decodeImageResponse(t, extractKeywordsImageJSON(tinyPNG(t)))
	if !first.NoVision {
		t.Fatalf("first call: no_vision = false (%s)", first.Error)
	}
	second := decodeImageResponse(t, extractKeywordsImageJSON(tinyPNG(t)))
	if !second.NoVision {
		t.Errorf("second call: no_vision = false (%s)", second.Error)
	}
	if hits != 1 {
		t.Errorf("provider was hit %d times, want 1 — the verdict was not cached", hits)
	}
}

// ...and a transient failure must NOT be cached, or one flaky moment
// permanently downgrades the user.
func TestExtractKeywordsImage_TransientFailureIsNotCached(t *testing.T) {
	resetEngineForTest(t)
	var hits int
	mux := http.NewServeMux()
	mux.HandleFunc("/api/chat", func(w http.ResponseWriter, _ *http.Request) {
		hits++
		w.WriteHeader(http.StatusInternalServerError)
		_, _ = w.Write([]byte(`{"error":"failed to load model for images"}`))
	})
	srv := httptest.NewServer(mux)
	defer srv.Close()

	e := getEngine()
	e.mu.Lock()
	e.cfg = config.Config{LLMProvider: "ollama", LLMModel: "llava-transient-fixture", LLMBaseURL: srv.URL}
	e.mu.Unlock()

	for i := 0; i < 2; i++ {
		resp := decodeImageResponse(t, extractKeywordsImageJSON(tinyPNG(t)))
		if resp.Error == "" {
			t.Fatalf("call %d: expected an error", i)
		}
		if resp.NoVision {
			t.Fatalf("call %d: a 500 was cached as a no-vision verdict", i)
		}
	}
	if hits != 2 {
		t.Errorf("provider was hit %d times, want 2 — a transient failure was cached", hits)
	}
}

// A backend that accepts `images` and silently ignores them answers
// from the prompt alone — plausible, term-shaped, and completely wrong.
// That must reach the host as a no-vision verdict (so it falls back to
// the AX text path) and must be cached like any other rejection, not
// re-probed on every focus change.
func TestExtractKeywordsImage_SilentImageDropIsReportedAndCached(t *testing.T) {
	resetEngineForTest(t)
	var hits int
	mux := http.NewServeMux()
	mux.HandleFunc("/api/chat", func(w http.ResponseWriter, _ *http.Request) {
		hits++
		// No vision marker: the model never saw the screenshot, so it
		// invented something from the instructions.
		_, _ = w.Write([]byte(`{"message":{"role":"assistant","content":"screenshot, window, dictation, recogniser"},"done":true}`))
	})
	srv := httptest.NewServer(mux)
	defer srv.Close()

	e := getEngine()
	e.mu.Lock()
	e.cfg = config.Config{LLMProvider: "ollama", LLMModel: "llava-silent-drop-fixture", LLMBaseURL: srv.URL}
	e.mu.Unlock()

	first := decodeImageResponse(t, extractKeywordsImageJSON(tinyPNG(t)))
	if !first.NoVision {
		t.Fatalf("a silently-dropped image was reported as success: %+v", first)
	}
	if len(first.Keywords) != 0 {
		t.Errorf("invented keywords escaped to the host: %v", first.Keywords)
	}
	_ = decodeImageResponse(t, extractKeywordsImageJSON(tinyPNG(t)))
	if hits != 1 {
		t.Errorf("provider was hit %d times, want 1 — the verdict was not cached", hits)
	}
}

// ...and the marker never reaches the keyword list that biases whisper.
func TestExtractKeywordsImage_MarkerNeverReachesKeywords(t *testing.T) {
	resetEngineForTest(t)
	srv := fakeVisionOllama(t, screenctx.VisionCanary+", SpeakerGate, DeepFilterNet")
	defer srv.Close()

	e := getEngine()
	e.mu.Lock()
	e.cfg = config.Config{LLMProvider: "ollama", LLMModel: "llava-marker-fixture", LLMBaseURL: srv.URL}
	e.mu.Unlock()

	resp := decodeImageResponse(t, extractKeywordsImageJSON(tinyPNG(t)))
	if resp.Error != "" {
		t.Fatalf("unexpected error: %s", resp.Error)
	}
	if resp.NoVision {
		t.Errorf("no_vision must be false when the marker is present")
	}
	for _, k := range resp.Keywords {
		if strings.Contains(strings.ToLower(k), strings.ToLower(screenctx.VisionCanary)) {
			t.Errorf("marker leaked into keywords: %q", k)
		}
	}
	if strings.Contains(strings.ToLower(resp.Raw), strings.ToLower(screenctx.VisionCanary)) {
		t.Errorf("marker leaked into raw: %q", resp.Raw)
	}
	if len(resp.Keywords) != 2 || resp.Keywords[0] != "SpeakerGate" {
		t.Errorf("keywords = %v, want [SpeakerGate DeepFilterNet]", resp.Keywords)
	}
}
