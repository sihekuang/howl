package main

import (
	"bufio"
	"context"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"strings"

	"github.com/voice-keyboard/core/internal/audio"
	"github.com/voice-keyboard/core/internal/denoise"
	"github.com/voice-keyboard/core/internal/dict"
	"github.com/voice-keyboard/core/internal/llm"
	"github.com/voice-keyboard/core/internal/pipeline"
	"github.com/voice-keyboard/core/internal/transcribe"
)

func runPipe(args []string) int {
	fs := flag.NewFlagSet("pipe", flag.ContinueOnError)
	live := fs.Bool("live", false, "record from mic; press Enter to stop")
	persistent := fs.Bool("persistent", false, "stay running; loop capture+transcribe+clean cycles (implies --live; incompatible with FILE.wav)")
	dictTerms := fs.String("dict", "", "comma-separated custom terms")
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

	if *persistent {
		// Persistent mode: MalgoCapture supports re-Start after Stop
		// (the cleanup goroutine nils all fields, so the "already started"
		// guard in Start passes cleanly on subsequent iterations). We reuse
		// the same *MalgoCapture, *WhisperCpp, and *Anthropic across
		// iterations so the Whisper model stays warm — eliminating the
		// ~1-2 s cold-load cost from every utterance.
		cap := audio.NewMalgoCapture()
		p := pipeline.New(cap, d, w, dy, cleaner)
		return runPipeLoop(ctx, p)
	}

	if *live {
		cap := audio.NewMalgoCapture()
		p := pipeline.New(cap, d, w, dy, cleaner)

		stopCh := make(chan struct{})
		fmt.Fprintln(os.Stderr, "Speak; press Enter to stop.")
		go func() {
			bufio.NewReader(os.Stdin).ReadString('\n')
			close(stopCh)
		}()

		res, err := p.Run(ctx, stopCh)
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
	p := pipeline.New(cap, d, w, dy, cleaner)

	stopCh := make(chan struct{})
	// File mode: FakeCapture closes its frames channel naturally when
	// the buffer is exhausted, which terminates the pipeline. stopCh
	// only fires on ctx cancel.
	go func() {
		<-ctx.Done()
		close(stopCh)
	}()

	res, err := p.Run(ctx, stopCh)
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

// runPipeLoop implements --persistent mode: loops capture+transcribe+clean
// cycles in a single process so the Whisper model (held by the pipeline's
// transcriber) stays warm across utterances. Per-utterance latency drops
// from ~2 s (cold model load) to ~200 ms (inference only).
//
// The loop reads from stdin:
//   - First Enter: start capture.
//   - Second Enter: stop capture, run inference, print result.
//   - EOF (Ctrl-D) at either prompt: exit cleanly with code 0.
//   - Ctrl-C (ctx cancel): exits after the current pipeline.Run returns.
func runPipeLoop(ctx context.Context, p *pipeline.Pipeline) int {
	fmt.Fprintln(os.Stderr, "Persistent mode. Press Enter to start a capture; Enter again to stop. Ctrl-C or Ctrl-D to exit.")
	reader := bufio.NewReader(os.Stdin)
	for {
		// Check for context cancellation before prompting.
		select {
		case <-ctx.Done():
			return 0
		default:
		}

		// Wait for "start" Enter.
		fmt.Fprint(os.Stderr, "[ready] press Enter to record... ")
		if _, err := reader.ReadString('\n'); err != nil {
			// EOF (Ctrl-D) or read error — exit cleanly.
			fmt.Fprintln(os.Stderr, "")
			return 0
		}

		fmt.Fprintln(os.Stderr, "Speak; press Enter to stop.")
		stopCh := make(chan struct{})
		go func() {
			reader.ReadString('\n') //nolint:errcheck // EOF also closes stopCh correctly
			select {
			case <-stopCh:
			default:
				close(stopCh)
			}
		}()

		res, err := p.Run(ctx, stopCh)
		// Drain stopCh if the goroutine hasn't closed it yet (e.g. pipeline
		// ended due to ctx cancel before the user pressed Enter).
		select {
		case <-stopCh:
		default:
			close(stopCh)
		}

		if err != nil {
			fmt.Fprintf(os.Stderr, "pipeline error: %v\n", err)
			if ctx.Err() != nil {
				return 0 // context cancelled (Ctrl-C) — exit
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
