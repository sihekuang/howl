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
	dictTerms := fs.String("dict", "", "comma-separated custom terms")
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if *live && len(fs.Args()) > 0 {
		fmt.Fprintln(os.Stderr, "usage: --live and FILE.wav are mutually exclusive")
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

	cleaner := llm.NewAnthropic(llm.AnthropicOptions{
		APIKey: apiKey,
		Model:  "claude-sonnet-4-6",
	})

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

	var cap audio.Capture
	if *live {
		cap = audio.NewMalgoCapture()
	} else {
		rest := fs.Args()
		if len(rest) != 1 {
			fmt.Fprintln(os.Stderr, "usage: vkb-cli pipe [--dict X,Y] FILE.wav  (or --live)")
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
		cap = audio.NewFakeCapture(pcm, denoise.FrameSize)
	}

	p := pipeline.New(cap, d, w, dy, cleaner)

	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt)
	defer cancel()

	stopCh := make(chan struct{})
	if *live {
		fmt.Fprintln(os.Stderr, "Speak; press Enter to stop.")
		go func() {
			bufio.NewReader(os.Stdin).ReadString('\n')
			close(stopCh)
		}()
	} else {
		// File mode: FakeCapture closes its frames channel naturally when
		// the buffer is exhausted, which terminates the pipeline. stopCh
		// only fires on ctx cancel.
		go func() {
			<-ctx.Done()
			close(stopCh)
		}()
	}

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
