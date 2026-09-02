package screenctx

import (
	"context"
	"fmt"
	"net/http"
	"os"
	"os/exec"
	"sort"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/voice-keyboard/core/internal/config"
	"github.com/voice-keyboard/core/internal/llm"
)

// Latency measurement for the screen-context extraction step.
//
// This exists because ExtractImageTimeout cannot be chosen from first
// principles: it depends on the user's hardware and on which model
// they pointed Howl at, and those vary by more than an order of
// magnitude. It is a harness rather than a one-off script so the
// number can be re-derived on other machines instead of inherited on
// faith.
//
// Opt-in — it calls real models and takes minutes:
//
//	SCREENCTX_LATENCY=1 go test ./internal/screenctx/ \
//	    -run TestScreenContextLatency -v -timeout 60m
//
// SCREENCTX_LATENCY_RUNS overrides the warm-run count (default 5).
//
// Measured 2026-08-31, M-series laptop, 1400x900 / 116KB fixture PNG and
// an 8192-byte window text (the MaxWindowTextBytes cap):
//
//	config                              cold      warm median   warm max
//	lmstudio qwen2.5-vl-7b  [image]     18.4s     1.35s         1.44s
//	ollama   qwen3-vl:8b    [image]     1m46.9s   1m44.6s       3m48.6s
//	lmstudio qwen2.5-vl-7b  [text]      7.4s      805ms         3.74s
//	ollama   qwen2.5:7b     [text]      6.9s      477ms         766ms
//	ollama   qwen3.5:4b     [text]      1m37.7s   1m53.3s       2m19.8s
//
// The dominant variable is not modality and not parameter count — it is
// whether the model is a REASONING model. qwen3.5:4b is a 4B text model
// and is ~200x slower than a 7B vision model, because it burns thousands
// of hidden thinking tokens before answering. Ollama's `think: false`
// does not suppress it for these models (measured: 115s vs 118s).
//
// Cold start is the other real cost, and it is model residency rather
// than anything Howl controls: the same LM Studio model answers in 18.4s
// when it has just been evicted and 0.35s when resident.
//
// What it deliberately does NOT do is assert a threshold. Latency is a
// property of the machine it runs on, so a pass/fail bound here would
// fail on slow hardware and tell nobody anything. It reports a
// distribution and leaves the judgement to a human reading it.

type latencyCandidate struct {
	label string
	cfg   config.Config
	image bool // image path when true, AX-text path when false
}

type latencyRun struct {
	elapsed  time.Duration
	keywords int
	err      error
}

func latencyRuns() int {
	if v := os.Getenv("SCREENCTX_LATENCY_RUNS"); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n > 0 {
			return n
		}
	}
	return 5
}

// latencyWindowText is a stand-in for what the AX reader hands over: a
// realistic editor window's worth of text, filled to MaxWindowTextBytes
// so the text path is measured at the same cap production enforces.
func latencyWindowText() string {
	var b strings.Builder
	for i := 1; b.Len() < MaxWindowTextBytes; i++ {
		fmt.Fprintf(&b, "%3d  func (q *quillfeatherQueue) flushMorrowind(ctx context.Context) error {\n", i)
		fmt.Fprintf(&b, "%3d      if err := q.client.Send(ctx, zarneticBackoffMs, grimsbyToken); err != nil {\n", i+1)
		fmt.Fprintf(&b, "%3d          return fmt.Errorf(\"bramblewick: %%w\", err)\n", i+2)
		fmt.Fprintf(&b, "%3d      }\n", i+3)
	}
	return b.String()[:MaxWindowTextBytes]
}

func percentile(sorted []time.Duration, p float64) time.Duration {
	if len(sorted) == 0 {
		return 0
	}
	idx := int(p * float64(len(sorted)-1))
	return sorted[idx]
}

func summarize(t *testing.T, label string, cold latencyRun, warm []latencyRun) {
	t.Helper()

	var ok []time.Duration
	failures := 0
	for _, r := range warm {
		if r.err != nil {
			failures++
			continue
		}
		ok = append(ok, r.elapsed)
	}
	sort.Slice(ok, func(i, j int) bool { return ok[i] < ok[j] })

	coldNote := cold.elapsed.Round(time.Millisecond).String()
	if cold.err != nil {
		coldNote += fmt.Sprintf(" (%v)", cold.err)
	}

	if len(ok) == 0 {
		t.Logf("RESULT %-34s cold=%s  warm: 0/%d succeeded", label, coldNote, len(warm))
		return
	}
	t.Logf("RESULT %-34s cold=%s  warm n=%d ok=%d fail=%d  min=%v med=%v p90=%v max=%v",
		label, coldNote, len(warm), len(ok), failures,
		ok[0].Round(time.Millisecond),
		percentile(ok, 0.5).Round(time.Millisecond),
		percentile(ok, 0.9).Round(time.Millisecond),
		ok[len(ok)-1].Round(time.Millisecond),
	)
}

// unloadModel evicts a model so the next call pays the cold cost that
// the ExtractImageTimeout comment claims matters.
//
// This is not a detail. A loaded 7B vision model answers in ~1.3s; the
// same model cold has to page multiple GB off disk and JIT-load a
// projector first. Which of those a real user sees depends entirely on
// whether their local server still has the model resident when they
// focus a window, so measuring only the warm case would flatter the
// feature badly.
//
// Best effort: a failure just means the "cold" number is really a warm
// one, which the log says out loud rather than hiding.
func unloadModel(t *testing.T, cfg config.Config) {
	t.Helper()
	switch cfg.LLMProvider {
	case "ollama":
		unloadOllama(t, cfg)
	case "lmstudio":
		unloadLMStudio(t, cfg)
	}
	time.Sleep(2 * time.Second)
}

// unloadLMStudio shells out to the `lms` CLI, which is the only
// supported way to evict a model — the OpenAI-compatible endpoint has
// no unload verb.
func unloadLMStudio(t *testing.T, cfg config.Config) {
	t.Helper()
	out, err := exec.Command("lms", "unload", cfg.LLMModel).CombinedOutput()
	if err != nil {
		t.Logf("  (lms unload failed, cold number is really warm: %v: %s)", err, strings.TrimSpace(string(out)))
	}
}

func unloadOllama(t *testing.T, cfg config.Config) {
	t.Helper()
	base := cfg.LLMBaseURL
	if base == "" {
		base = "http://localhost:11434"
	}
	body := strings.NewReader(fmt.Sprintf(`{"model":%q,"keep_alive":0}`, cfg.LLMModel))
	client := &http.Client{Timeout: 15 * time.Second}
	resp, err := client.Post(base+"/api/generate", "application/json", body)
	if err != nil {
		t.Logf("  (unload failed, cold number is really warm: %v)", err)
		return
	}
	resp.Body.Close()
}

func measureOne(t *testing.T, c latencyCandidate, img llm.Image, text string) latencyRun {
	t.Helper()
	// The capability verdict is cached per (provider, model) for the
	// process. Without this reset, every run after the first would be
	// answered from memory and would measure a map lookup.
	resetVisionCacheForTest(t)

	prompt := ExtractPrompt
	if c.image {
		prompt = ExtractImagePrompt
	}
	cleaner, err := newExtractor(c.cfg, prompt, liveExtractTimeout)
	if err != nil {
		return latencyRun{err: err}
	}

	ctx, cancel := context.WithTimeout(context.Background(), liveExtractTimeout)
	defer cancel()

	start := time.Now()
	var res ExtractResult
	if c.image {
		res, err = ExtractImage(ctx, cleaner, img, []string{"Howl"})
	} else {
		res, err = Extract(ctx, cleaner, text, []string{"Howl"})
	}
	return latencyRun{elapsed: time.Since(start), keywords: len(res.Keywords), err: err}
}

func TestScreenContextLatency_Distribution(t *testing.T) {
	if os.Getenv("SCREENCTX_LATENCY") == "" {
		t.Skip("set SCREENCTX_LATENCY=1 to measure extraction latency against live models")
	}

	candidates := []latencyCandidate{
		{label: "lmstudio/qwen2.5-vl-7b [image]", image: true,
			cfg: config.Config{LLMProvider: "lmstudio", LLMModel: "qwen/qwen2.5-vl-7b"}},
		{label: "ollama/qwen3-vl:8b [image]", image: true,
			cfg: config.Config{LLMProvider: "ollama", LLMModel: "qwen3-vl:8b"}},
		{label: "lmstudio/qwen2.5-vl-7b [text]", image: false,
			cfg: config.Config{LLMProvider: "lmstudio", LLMModel: "qwen/qwen2.5-vl-7b"}},
		{label: "ollama/qwen2.5:7b [text]", image: false,
			cfg: config.Config{LLMProvider: "ollama", LLMModel: "qwen2.5:7b"}},
		{label: "ollama/qwen3.5:4b [text]", image: false,
			cfg: config.Config{LLMProvider: "ollama", LLMModel: "qwen3.5:4b"}},
	}

	img := liveFixtureImage(t)
	text := latencyWindowText()
	n := latencyRuns()
	t.Logf("fixture PNG %d bytes; window text %d bytes; %d warm runs per candidate",
		len(img.Data), len(text), n)

	for _, c := range candidates {
		c := c
		t.Run(c.label, func(t *testing.T) {
			requireServedModel(t, c.cfg)

			unloadModel(t, c.cfg)
			cold := measureOne(t, c, img, text)
			t.Logf("  cold %v keywords=%d err=%v", cold.elapsed.Round(time.Millisecond), cold.keywords, cold.err)

			warm := make([]latencyRun, 0, n)
			for i := 0; i < n; i++ {
				r := measureOne(t, c, img, text)
				t.Logf("  warm[%d] %v keywords=%d err=%v", i, r.elapsed.Round(time.Millisecond), r.keywords, r.err)
				warm = append(warm, r)
			}
			summarize(t, c.label, cold, warm)
		})
	}
}
