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
	"github.com/voice-keyboard/core/internal/transcribe"
)

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
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if (*live || *persistent) && len(fs.Args()) > 0 {
		fmt.Fprintln(os.Stderr, "usage: --live/--persistent and FILE.wav are mutually exclusive")
		return 2
	}

	apiKey := os.Getenv("ANTHROPIC_API_KEY")
	if apiKey == "" {
		fmt.Fprintln(os.Stderr, "ANTHROPIC_API_KEY required")
		return 1
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

	cleaner, err := llm.NewAnthropic(llm.AnthropicOptions{
		APIKey: apiKey,
		Model:  "claude-sonnet-4-6",
	})
	if err != nil {
		fmt.Fprintf(os.Stderr, "anthropic: %v\n", err)
		return 1
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

	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt)
	defer cancel()

	p := pipeline.New(d, w, dy, cleaner)

	var (
		repMu        sync.Mutex
		repChunks    []chunkInfo
		repStopAt    time.Time
		repFirstTok  time.Duration
		repFirstSeen bool
	)

	if *latencyReport {
		p.ChunkEmittedCallback = func(idx int, durationMs int, reason string) {
			repMu.Lock()
			repChunks = append(repChunks, chunkInfo{
				emittedAt: time.Now(), dur: durationMs, reason: reason,
			})
			repMu.Unlock()
		}
		p.ChunkTranscribedCallback = func(idx int, transcribeMs int, text string) {
			repMu.Lock()
			if idx-1 < len(repChunks) {
				repChunks[idx-1].transcMs = transcribeMs
				repChunks[idx-1].text = text
			}
			repMu.Unlock()
		}
		p.LLMFirstTokenCallback = func(elapsedMs int) {
			repMu.Lock()
			repFirstTok = time.Duration(elapsedMs) * time.Millisecond
			repFirstSeen = true
			repMu.Unlock()
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
// the warm Whisper model) across utterances.
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
