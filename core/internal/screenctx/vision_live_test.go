package screenctx

import (
	"context"
	"errors"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/voice-keyboard/core/internal/config"
	"github.com/voice-keyboard/core/internal/llm"
)

// End-to-end coverage of the image path against REAL models: a rendered
// screenshot (screenshot_fixture_test.go) through the real
// ExtractImage, the real prompt, and a real local provider. Everything
// else in this package stubs the model out, so this is the only place
// that can catch the failures that only appear against a live one — a
// backend that accepts an `images` field and ignores it, a model that
// answers from the prompt wording alone, a response format the
// sanitizer mangles.
//
// Opt-in the same way core/internal/speaker's fixtures are: they skip
// silently without their inputs (an API key there, a local model
// server here) rather than failing, because CI has neither. A skip here
// means "no local model to ask", never "the pipeline is fine".
//
// These call local models, so they cost nothing but they are not
// instant — budget ~30s when both servers are up.

const (
	// liveExtractTimeout replaces ExtractImageTimeout for these tests,
	// and ONLY the timeout differs from production: the prompt, the
	// provider construction, the credentials and the response handling
	// are all the shipped ones (newExtractor is what NewImageExtractor
	// calls).
	//
	// It stays longer than production deliberately. Measured on an
	// M-series laptop against this fixture: lmstudio/qwen2.5-vl-7b
	// answered in 9–24s, ollama/qwen3-vl:8b in 45–162s (it is a
	// thinking model and burns thousands of hidden reasoning tokens
	// before answering). These measurements are what raised the shipped
	// ExtractImageTimeout from 12s to 90s. This clock is looser still
	// so that a slow-but-working model measures the pipeline rather
	// than the clock — a live test that fails because a local model was
	// swapping would be noise, not a finding.
	liveExtractTimeout = 5 * time.Minute

	// liveProbeTimeout bounds the "is anything serving?" check. Short:
	// the whole point is to skip quickly when nothing is running.
	liveProbeTimeout = 5 * time.Second

	// How many of the fixture's six invented identifiers must come
	// back: liveMinRawHits from the model's own response, and
	// liveMinKeywordHits from the sanitized list that would actually
	// reach whisper.
	//
	// Thresholds rather than all six, and the reason is measured, not
	// defensive: across runs these models pick a different subset each
	// time (one summarises `QuillfeatherSyncQueue` as `quillfeather` +
	// `sync_queue.go`, another lists both), and prose-formatted answers
	// lose a term or two to the sanitizer's length cap. Worst observed
	// was 5/6 in the response. Four is comfortably inside that and
	// still overwhelming proof: these strings exist nowhere but in the
	// pixels, so a model that did not read them scores zero, not three.
	liveMinRawHits     = 4
	liveMinKeywordHits = 3
)

// The models these tests ask, overridable so a maintainer with a
// different local zoo can point them somewhere else.
//
// The vision default is LM Studio's qwen2.5-vl-7b rather than Ollama's
// qwen3-vl:8b for one measured reason: qwen3-vl:8b emitted the
// VisionCanary in only 2 of 5 runs against this fixture. It read the
// screen perfectly every time — every invented identifier came back —
// but it kept paraphrasing the marker instruction ("The exact marker",
// "Begin your reply with the exact marker") instead of emitting the
// marker, which the pipeline correctly reads as "this response cannot
// be trusted to describe pixels". That is the deliberate failure
// direction documented on VisionCanary, and it is not something to
// assert on a coin flip. qwen2.5-vl-7b returned the marker in every
// run.
func liveVisionCfg() config.Config {
	return config.Config{
		LLMProvider: envOr("SCREENCTX_LIVE_VISION_PROVIDER", "lmstudio"),
		LLMModel:    envOr("SCREENCTX_LIVE_VISION_MODEL", "qwen/qwen2.5-vl-7b"),
		LLMBaseURL:  os.Getenv("SCREENCTX_LIVE_VISION_BASE_URL"),
	}
}

func liveTextOnlyCfg() config.Config {
	return config.Config{
		LLMProvider: envOr("SCREENCTX_LIVE_TEXTONLY_PROVIDER", "ollama"),
		LLMModel:    envOr("SCREENCTX_LIVE_TEXTONLY_MODEL", "qwen2.5:7b"),
		LLMBaseURL:  os.Getenv("SCREENCTX_LIVE_TEXTONLY_BASE_URL"),
	}
}

func envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

// requireServedModel skips unless cfg's provider is reachable AND is
// actually serving cfg's model. Enumeration goes through the shipped
// Provider.LocalModels, so "is it up" is answered the same way the
// app's own model picker answers it.
func requireServedModel(t *testing.T, cfg config.Config) {
	t.Helper()
	provider, err := llm.ProviderByName(cfg.LLMProvider)
	if err != nil {
		t.Skipf("no provider %q: %v", cfg.LLMProvider, err)
	}
	served, err := provider.LocalModels(llm.Options{
		BaseURL: cfg.LLMBaseURL, Timeout: liveProbeTimeout,
	})
	if err != nil {
		t.Skipf("%s is not reachable (%v) — start it to run this test", cfg.LLMProvider, err)
	}
	for _, m := range served {
		if m == cfg.LLMModel {
			return
		}
	}
	t.Skipf("%s is not serving %q (it has %v) — pull/load it to run this test",
		cfg.LLMProvider, cfg.LLMModel, served)
}

// liveExtractor builds the shipped image extractor with the relaxed
// clock. Returns the llm.Cleaner ExtractImage expects, so the
// VisionCleaner discovery happens where production does it.
func liveExtractor(t *testing.T, cfg config.Config) llm.Cleaner {
	t.Helper()
	cleaner, err := newExtractor(cfg, ExtractImagePrompt, liveExtractTimeout)
	if err != nil {
		t.Fatalf("build image extractor for %s/%s: %v", cfg.LLMProvider, cfg.LLMModel, err)
	}
	return cleaner
}

// identifierHits counts how many fixture identifiers appear in s
// (case-insensitively) and names the ones that do not.
func identifierHits(s string) (hits int, missing []string) {
	hay := strings.ToLower(s)
	for _, id := range fixtureIdentifiers {
		if strings.Contains(hay, strings.ToLower(id)) {
			hits++
		} else {
			missing = append(missing, id)
		}
	}
	return hits, missing
}

func liveFixtureImage(t *testing.T) llm.Image {
	t.Helper()
	data := renderSyntheticScreenshot(t)
	mediaType, err := llm.DetectImageMediaType(data)
	if err != nil {
		t.Fatalf("sniff fixture media type: %v", err)
	}
	return llm.Image{Data: data, MediaType: mediaType}
}

// A real vision model, a real screenshot, the real extractor: the
// keywords that come back must be things that were only ever on the
// screen.
//
// The fixture's identifiers are invented compounds — QuillfeatherSyncQueue,
// zarneticBackoffMs — that appear nowhere in the prompt and nowhere in
// any training set. A model that never saw the pixels cannot produce
// them, so their presence is the proof this test exists for.
func TestExtractImage_LiveVisionModelReadsTheRenderedScreenshot(t *testing.T) {
	cfg := liveVisionCfg()
	requireServedModel(t, cfg)
	resetVisionCacheForTest(t)

	// The capability verdict is cached per (provider, model) for the
	// process. Asserting it is clear FIRST is what makes the rest of
	// this test mean anything: a stale verdict would otherwise let
	// ExtractImage answer from memory and never call the model at all.
	key := VisionKeyFor(cfg)
	if IsTextOnly(key) {
		t.Fatalf("%+v is already cached text-only before any call — this test would not reach the model", key)
	}

	img := liveFixtureImage(t)
	ctx, cancel := context.WithTimeout(context.Background(), liveExtractTimeout)
	defer cancel()

	start := time.Now()
	res, err := ExtractImage(ctx, liveExtractor(t, cfg), img, []string{"Howl"})
	elapsed := time.Since(start)
	if err != nil {
		// ErrNoVision here means the model answered without the canary
		// (or the provider rejected the image). Either way nothing
		// downstream can be checked, so this is fatal.
		t.Fatalf("ExtractImage against %s/%s after %v: %v", cfg.LLMProvider, cfg.LLMModel, elapsed, err)
	}
	// The evidence, logged rather than asserted on verbatim — model
	// wording is not a contract.
	t.Logf("%s/%s answered in %v", cfg.LLMProvider, cfg.LLMModel, elapsed)
	t.Logf("raw response (canary stripped): %q", res.Raw)
	t.Logf("keywords (%d): %q", len(res.Keywords), res.Keywords)
	t.Logf("dropped (%d): %+v", len(res.Dropped), res.Dropped)

	// 1. Reaching here at all IS the canary assertion: ExtractImage
	//    reports a response without the marker as ErrNoVision rather
	//    than trusting it, so err == nil means the marker came back.

	// 2. The invented identifiers must be in what the model said. This
	//    is the pixel proof: they are in no training set and in no part
	//    of the prompt.
	rawHits, rawMissing := identifierHits(res.Raw)
	if rawHits < liveMinRawHits {
		t.Errorf("only %d/%d on-screen identifiers came back (want >= %d); missing %q — did the model see the image?",
			rawHits, len(fixtureIdentifiers), liveMinRawHits, rawMissing)
	}

	// 3. ...and enough of them must survive sanitizing to actually
	//    reach whisper. A response the sanitizer rejects wholesale is a
	//    feature that does nothing.
	kwHits, kwMissing := identifierHits(strings.Join(res.Keywords, "\n"))
	if kwHits < liveMinKeywordHits {
		t.Errorf("only %d/%d on-screen identifiers survived into the keyword list (want >= %d); missing %q: %q",
			kwHits, len(fixtureIdentifiers), liveMinKeywordHits, kwMissing, res.Keywords)
	}

	// 4. The marker is protocol, not vocabulary. It is drawn INTO the
	//    fixture as well as being asked for in the prompt, so a model
	//    can echo it more than once and in the middle of its list —
	//    exactly the case stripVisionCanary must handle. None of it may
	//    reach whisper, or the user's dictation gets biased toward a
	//    string Howl invented.
	if strings.Contains(res.Raw, VisionCanary) {
		t.Errorf("canary survived into Raw: %q", res.Raw)
	}
	for _, k := range res.Keywords {
		if strings.Contains(k, VisionCanary) {
			t.Errorf("canary survived into a keyword: %q", k)
		}
	}
	for _, d := range res.Dropped {
		if strings.Contains(d.Term, VisionCanary) {
			t.Errorf("canary reached the sanitizer as a candidate term: %+v", d)
		}
	}

	// 5. A working vision model must not be marked text-only.
	if IsTextOnly(key) {
		t.Errorf("%+v was cached text-only despite a successful vision call", key)
	}
}

// The load-bearing case: a text-only model must be DETECTED, not
// believed.
//
// The failure this guards is silent. Asked to describe a screenshot it
// cannot see, a text-only model does not error — it answers from the
// prompt wording, returning plausible filler like
// ["screenshot","window","dictation"]. Those invented terms would go
// straight into whisper's initial_prompt and quietly make dictation
// worse, with no_vision false so the AX text path that would have
// worked is never tried. Erring toward the text path is the whole
// point of VisionCanary.
func TestExtractImage_LiveTextOnlyModelIsCaughtBeforeItPoisonsWhisper(t *testing.T) {
	cfg := liveTextOnlyCfg()
	requireServedModel(t, cfg)
	resetVisionCacheForTest(t)

	key := VisionKeyFor(cfg)
	if IsTextOnly(key) {
		t.Fatalf("%+v is already cached text-only before any call — the verdict below would be the cache, not the model", key)
	}

	cleaner := liveExtractor(t, cfg)
	img := liveFixtureImage(t)
	ctx, cancel := context.WithTimeout(context.Background(), liveExtractTimeout)
	defer cancel()

	// First, what the model actually says when handed an image. Two
	// shapes are legitimate and both are in the wild: the provider
	// rejects the request outright (current Ollama answers HTTP 400
	// "model does not support multimodal requests"), or it accepts it,
	// silently drops the image, and answers anyway. The second is the
	// dangerous one, and the canary must be absent from whatever comes
	// back.
	vc, ok := cleaner.(llm.VisionCleaner)
	if !ok {
		t.Fatalf("provider %q (%T) has no image path at all — pick one that does", cfg.LLMProvider, cleaner)
	}
	raw, rawErr := vc.CleanImage(ctx, img, []string{"Howl"})
	switch {
	case rawErr == nil:
		t.Logf("text-only model answered anyway: %q", raw)
		t.Logf("...which would have become these keywords: %q", Sanitize(raw))
		if strings.Contains(raw, VisionCanary) {
			t.Errorf("a model that cannot see emitted the canary — the marker no longer proves anything: %q", raw)
		}
	case errors.Is(rawErr, llm.ErrNoVision):
		t.Logf("provider rejected the image outright: %v", rawErr)
	default:
		t.Fatalf("unexpected failure from %s/%s (not a capability verdict): %v",
			cfg.LLMProvider, cfg.LLMModel, rawErr)
	}

	// Then the pipeline's verdict on the same input.
	res, err := ExtractImage(ctx, cleaner, img, []string{"Howl"})
	if !errors.Is(err, llm.ErrNoVision) {
		t.Fatalf("ExtractImage err = %v, want ErrNoVision — a text-only model was believed", err)
	}
	if len(res.Keywords) != 0 || len(res.Dropped) != 0 || res.Raw != "" {
		t.Errorf("no-vision result leaked content: %+v", res)
	}
	t.Logf("pipeline verdict: %v", err)

	// And the session cache the C ABI keeps, recorded exactly where
	// libhowl records it (screenctx_image_export.go: ErrNoVision ->
	// MarkTextOnly). After this, the host stops paying for a round trip
	// it knows will fail, until the user changes provider or model.
	MarkTextOnly(key)
	if !IsTextOnly(key) {
		t.Errorf("verdict for %+v did not stick", key)
	}
	if other := VisionKeyFor(liveVisionCfg()); IsTextOnly(other) {
		t.Errorf("the text-only verdict leaked onto %+v", other)
	}
}
