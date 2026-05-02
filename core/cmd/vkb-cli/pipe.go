//go:build whispercpp

package main

import (
	"bufio"
	"context"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"strings"
	"sync"
	"time"

	"github.com/voice-keyboard/core/internal/audio"
	"github.com/voice-keyboard/core/internal/denoise"
	"github.com/voice-keyboard/core/internal/dict"
	"github.com/voice-keyboard/core/internal/llm"
	"github.com/voice-keyboard/core/internal/pipeline"
	"github.com/voice-keyboard/core/internal/recorder"
	"github.com/voice-keyboard/core/internal/resample"
	"github.com/voice-keyboard/core/internal/speaker"
	"github.com/voice-keyboard/core/internal/transcribe"
)

type passthroughCleaner struct{}

func (passthroughCleaner) Clean(_ context.Context, text string, _ []string) (string, error) {
	return text, nil
}

type chunkInfo struct {
	emittedAt time.Time
	dur       int
	reason    string
	transcMs  int
	text      string
}

func runPipe(args []string) int {
	fs := flag.NewFlagSet("pipe", flag.ContinueOnError)
	live := fs.Bool("live", false, "record from mic; press Enter to stop")
	persistent := fs.Bool("persistent", false, "stay running; loop capture+transcribe+clean cycles (implies --live; incompatible with FILE.wav)")
	dictTerms := fs.String("dict", "", "comma-separated custom terms")
	latencyReport := fs.Bool("latency-report", false, "print per-chunk timing + post-stop latency summary on stderr")
	noLLM := fs.Bool("no-llm", false, "skip LLM cleanup; output raw Whisper text (no API key needed)")
	speakerMode := fs.Bool("speaker", false, "enable speaker gating; requires a prior ./enroll.sh run")
	tseBackend := fs.String("tse-backend", "", "TSE backend name (default: ecapa)")
	llmProvider := fs.String("llm-provider", "", "LLM provider name (default: anthropic; see `vkb-cli providers`)")
	llmModel := fs.String("llm-model", "", "LLM model id (overrides ANTHROPIC_MODEL env; required for ollama)")
	llmBaseURL := fs.String("llm-base-url", "", "LLM base URL override (e.g. http://localhost:11434 for Ollama on a non-default host)")
	recordDir := fs.String("record-dir", "", "directory to write per-stage WAVs and transcripts")
	recordSpec := fs.String("record", "", "comma-separated taps: audio,transcripts (e.g. --record audio,transcripts). Requires --record-dir.")
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if (*live || *persistent) && len(fs.Args()) > 0 {
		fmt.Fprintln(os.Stderr, "usage: --live/--persistent and FILE.wav are mutually exclusive")
		return 2
	}

	modelPath := os.Getenv("VKB_MODEL_PATH")
	if modelPath == "" {
		modelPath = os.ExpandEnv("$HOME/Library/Application Support/VoiceKeyboard/models/ggml-tiny.en.bin")
	}
	lang := os.Getenv("VKB_LANGUAGE")
	if lang == "" {
		lang = "en"
	}

	w, err := transcribe.NewWhisperCpp(transcribe.WhisperOptions{ModelPath: modelPath, Language: lang})
	if err != nil {
		fmt.Fprintf(os.Stderr, "load model: %v\n", err)
		return 1
	}
	defer w.Close()

	var cleaner llm.Cleaner
	if *noLLM {
		cleaner = passthroughCleaner{}
	} else {
		provider, perr := llm.ProviderByName(*llmProvider)
		if perr != nil {
			fmt.Fprintf(os.Stderr, "llm: %v\n", perr)
			return 2
		}
		// Model precedence: --llm-model flag > provider-specific legacy env >
		// provider's DefaultModel (filled in by provider.New) > provider's
		// auto-detect (e.g. Ollama queries /api/tags). The ANTHROPIC_MODEL
		// fallback is anthropic-flavoured, so only honour it when actually
		// using Anthropic — otherwise users with that var lingering in
		// their environment ship it to Ollama and get a confusing 404.
		model := *llmModel
		if model == "" && provider.Name == "anthropic" {
			model = os.Getenv("ANTHROPIC_MODEL")
		}
		opts := llm.Options{
			Model:   model,
			BaseURL: *llmBaseURL,
		}
		if provider.NeedsAPIKey {
			// Only Anthropic today; one provider-specific env var is fine.
			// When a second cloud provider lands this becomes a switch.
			opts.APIKey = os.Getenv("ANTHROPIC_API_KEY")
			if opts.APIKey == "" {
				fmt.Fprintf(os.Stderr, "ANTHROPIC_API_KEY required for provider %q\n", provider.Name)
				return 1
			}
		}
		cleaner, err = provider.New(opts)
		if err != nil {
			fmt.Fprintf(os.Stderr, "%s: %v\n", provider.Name, err)
			return 1
		}
		fmt.Fprintf(os.Stderr, "[vkb] LLM provider=%s model=%s\n", provider.Name, opts.Model)
	}

	var terms []string
	if *dictTerms != "" {
		for _, t := range strings.Split(*dictTerms, ",") {
			if t = strings.TrimSpace(t); t != "" {
				terms = append(terms, t)
			}
		}
	}
	dy := dict.NewFuzzy(terms, 1)
	d := denoise.NewPassthrough() // build with -tags=deepfilter for real denoise; passthrough is fine for the file-mode path

	var recOpts recorder.Options
	recOpts.Dir = *recordDir
	for _, t := range strings.Split(*recordSpec, ",") {
		switch strings.TrimSpace(t) {
		case "audio":
			recOpts.AudioStages = true
		case "transcripts":
			recOpts.Transcripts = true
		case "":
			// empty token from "" or trailing comma — ignore
		default:
			fmt.Fprintf(os.Stderr, "unknown --record tap: %q (want audio,transcripts)\n", t)
			return 2
		}
	}
	rec, recErr := recorder.Open(recOpts)
	if recErr != nil {
		fmt.Fprintf(os.Stderr, "recorder: %v\n", recErr)
		return 1
	}
	defer rec.Close()

	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt)
	defer cancel()

	p := pipeline.New(w, dy, cleaner)
	p.Recorder = rec
	p.FrameStages = []audio.Stage{denoise.NewStage(d), resample.NewDecimate3()}

	if *speakerMode {
		profileDir := os.Getenv("VKB_PROFILE_DIR")
		if profileDir == "" {
			profileDir = os.ExpandEnv("$HOME/.config/voice-keyboard")
		}
		modelsDir := os.Getenv("VKB_MODELS_DIR")
		if modelsDir == "" {
			modelsDir = os.ExpandEnv("$HOME/Library/Application Support/VoiceKeyboard/models")
		}
		onnxLib := os.Getenv("ONNXRUNTIME_LIB_PATH")
		if onnxLib == "" {
			onnxLib = "/opt/homebrew/lib/libonnxruntime.dylib"
		}
		backend, beErr := speaker.BackendByName(*tseBackend)
		if beErr != nil {
			fmt.Fprintf(os.Stderr, "speaker gate: %v\n", beErr)
			return 2
		}
		tseStage, err := pipeline.LoadTSE(backend, profileDir, modelsDir, onnxLib)
		if err != nil {
			fmt.Fprintf(os.Stderr, "speaker gate: %v\n", err)
			return 1
		}
		if tseStage == nil {
			fmt.Fprintln(os.Stderr, "speaker gate: no enrollment found — run ./enroll.sh first")
			return 1
		}
		p.ChunkStages = []audio.Stage{tseStage}
		fmt.Fprintf(os.Stderr, "[vkb] speaker gating active (backend=%s)\n", backend.Name)
	}

	var (
		repMu        sync.Mutex
		repChunks    []chunkInfo
		repStopAt    time.Time
		repFirstTok  time.Duration
		repFirstSeen bool
	)

	if *latencyReport {
		p.Listener = func(e pipeline.Event) {
			repMu.Lock()
			defer repMu.Unlock()
			switch e.Kind {
			case pipeline.EventChunkEmitted:
				repChunks = append(repChunks, chunkInfo{
					emittedAt: time.Now(), dur: e.DurationMs, reason: e.Reason,
				})
			case pipeline.EventChunkTranscribed:
				if e.ChunkIdx-1 < len(repChunks) {
					repChunks[e.ChunkIdx-1].transcMs = e.ElapsedMs
					repChunks[e.ChunkIdx-1].text = e.Text
				}
			case pipeline.EventLLMFirstToken:
				repFirstTok = time.Duration(e.ElapsedMs) * time.Millisecond
				repFirstSeen = true
			}
		}
	}

	notifyStop := func() {
		repMu.Lock()
		repStopAt = time.Now()
		repMu.Unlock()
	}
	reportFn := func() {
		if *latencyReport {
			repMu.Lock()
			chunks := append([]chunkInfo{}, repChunks...)
			stopAt := repStopAt
			firstTok := repFirstTok
			firstSeen := repFirstSeen
			repMu.Unlock()
			printLatencyReport(stopAt, chunks, firstTok, firstSeen)
		}
	}

	if *persistent {
		// Persistent mode: reuse the same MalgoCapture across cycles so
		// the Whisper model stays warm. MalgoCapture supports re-Start
		// after Stop (its cleanup goroutine nils all fields).
		cap := audio.NewMalgoCapture()
		return runPipeLoop(ctx, p, cap)
	}

	if *live {
		cap := audio.NewMalgoCapture()
		return runOneLive(ctx, cancel, p, cap, notifyStop, reportFn)
	}

	// File mode.
	rest := fs.Args()
	if len(rest) != 1 {
		fmt.Fprintln(os.Stderr, "usage: vkb-cli pipe [--dict X,Y] FILE.wav  (or --live / --persistent)")
		return 2
	}
	pcm, sr, err := readWavMonoFloat(rest[0])
	if err != nil {
		fmt.Fprintf(os.Stderr, "read wav: %v\n", err)
		return 1
	}
	if sr != 48000 {
		fmt.Fprintf(os.Stderr, "pipe expects 48kHz WAVs (got %d Hz)\n", sr)
		return 1
	}
	cap := audio.NewFakeCapture(pcm, denoise.FrameSize)
	frames, err := cap.Start(ctx, 48000)
	if err != nil {
		fmt.Fprintf(os.Stderr, "fake capture: %v\n", err)
		return 1
	}
	res, err := p.Run(ctx, frames)
	_ = cap.Stop()
	if err != nil {
		fmt.Fprintf(os.Stderr, "pipeline: %v\n", err)
		return 1
	}
	if res.LLMError != nil {
		fmt.Fprintf(os.Stderr, "[LLM warning: %v]\n", res.LLMError)
	}
	if res.Cleaned == "" {
		fmt.Fprintln(os.Stderr, "(empty result)")
		return 0
	}
	fmt.Println(res.Cleaned)
	return 0
}

// runOneLive starts the mic, runs one capture+transcribe+clean cycle,
// stops the mic on Enter or ctx cancel. Typing "cancel" aborts the pipeline.
func runOneLive(ctx context.Context, cancel context.CancelFunc, p *pipeline.Pipeline, cap *audio.MalgoCapture, notifyStop func(), reportFn func()) int {
	frames, err := cap.Start(ctx, 48000)
	if err != nil {
		fmt.Fprintf(os.Stderr, "capture: %v\n", err)
		return 1
	}
	fmt.Fprintln(os.Stderr, "Speak; press Enter to stop.")
	go func() {
		line, _ := bufio.NewReader(os.Stdin).ReadString('\n')
		line = strings.TrimSpace(line)
		notifyStop()
		if line == "cancel" {
			fmt.Fprintln(os.Stderr, "[vkb] --live: stdin sentinel 'cancel' — aborting pipeline")
			cancel()
		} else {
			_ = cap.Stop()
		}
	}()

	res, err := p.Run(ctx, frames)
	_ = cap.Stop() // idempotent; ensures we exit cleanly on ctx cancel too
	if ctx.Err() != nil {
		fmt.Fprintln(os.Stderr, "Cancelled. No transcript produced.")
		return 0
	}
	if err != nil {
		fmt.Fprintf(os.Stderr, "pipeline: %v\n", err)
		return 1
	}
	if res.LLMError != nil {
		fmt.Fprintf(os.Stderr, "[LLM warning: %v]\n", res.LLMError)
	}
	reportFn()
	if res.Cleaned == "" {
		fmt.Fprintln(os.Stderr, "(empty result)")
		return 0
	}
	fmt.Println(res.Cleaned)
	return 0
}

// runPipeLoop: --persistent mode. Reuses the same pipeline (and thus
// the warm Whisper model) across utterances. When recording is enabled
// (--record-dir), every utterance's audio appends to the same per-stage
// WAVs and every transcript overwrites the previous one — the session
// captures one continuous concatenated artefact, not per-utterance files.
//
//   - First Enter: start capture.
//   - Second Enter: stop capture, run inference, print result.
//   - EOF (Ctrl-D) at either prompt: exit cleanly.
//   - Ctrl-C (ctx cancel): exits after the current pipeline.Run returns.
func runPipeLoop(ctx context.Context, p *pipeline.Pipeline, cap *audio.MalgoCapture) int {
	fmt.Fprintln(os.Stderr, "Persistent mode. Press Enter to start a capture; Enter again to stop. Ctrl-C or Ctrl-D to exit.")
	reader := bufio.NewReader(os.Stdin)
	for {
		select {
		case <-ctx.Done():
			return 0
		default:
		}

		fmt.Fprint(os.Stderr, "[ready] press Enter to record... ")
		if _, err := reader.ReadString('\n'); err != nil {
			fmt.Fprintln(os.Stderr, "")
			return 0
		}

		frames, err := cap.Start(ctx, 48000)
		if err != nil {
			fmt.Fprintf(os.Stderr, "capture: %v\n", err)
			continue
		}

		fmt.Fprintln(os.Stderr, "Speak; press Enter to stop.")
		go func() {
			reader.ReadString('\n') //nolint:errcheck
			_ = cap.Stop()
		}()

		res, err := p.Run(ctx, frames)
		_ = cap.Stop()

		if err != nil {
			fmt.Fprintf(os.Stderr, "pipeline error: %v\n", err)
			if ctx.Err() != nil {
				return 0
			}
			continue
		}
		if res.LLMError != nil {
			fmt.Fprintf(os.Stderr, "[LLM warning: %v]\n", res.LLMError)
		}
		if res.Cleaned == "" {
			fmt.Fprintln(os.Stderr, "(empty)")
		} else {
			fmt.Println(res.Cleaned)
		}
	}
}

func printLatencyReport(stopAt time.Time, chunks []chunkInfo, firstTok time.Duration, sawFirst bool) {
	w := os.Stderr
	fmt.Fprintln(w, "[vkb] === latency report ===")
	var preStopTransc, postStopTransc int
	for _, c := range chunks {
		if c.emittedAt.Before(stopAt) {
			preStopTransc += c.transcMs
		} else {
			postStopTransc += c.transcMs
		}
	}
	fmt.Fprintf(w, "[vkb]   chunks emitted:        %d\n", len(chunks))
	fmt.Fprintf(w, "[vkb]   transcribe-during-rec: %dms\n", preStopTransc)
	fmt.Fprintf(w, "[vkb]   post-stop-transcribe:  %dms\n", postStopTransc)
	if sawFirst {
		fmt.Fprintf(w, "[vkb]   post-stop-llm-first:   %dms after transcribe done\n", int(firstTok.Milliseconds()))
	}
	if sawFirst {
		totalPostStop := postStopTransc + int(firstTok.Milliseconds())
		fmt.Fprintf(w, "[vkb]   total post-stop wait:  %dms\n", totalPostStop)
	} else {
		fmt.Fprintf(w, "[vkb]   total post-stop wait:  %dms (no LLM call)\n", postStopTransc)
	}
}
