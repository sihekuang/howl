//go:build whispercpp

package main

import (
	"context"
	"flag"
	"fmt"
	"os"

	"github.com/voice-keyboard/core/internal/resample"
	"github.com/voice-keyboard/core/internal/transcribe"
)

func runTranscribe(args []string) int {
	fs := flag.NewFlagSet("transcribe", flag.ContinueOnError)
	if err := fs.Parse(args); err != nil {
		return 2
	}
	rest := fs.Args()
	if len(rest) != 1 {
		fmt.Fprintln(os.Stderr, "usage: howl transcribe FILE.wav")
		return 2
	}
	path := rest[0]

	pcm, sr, err := readWavMonoFloat(path)
	if err != nil {
		fmt.Fprintf(os.Stderr, "read wav: %v\n", err)
		return 1
	}

	pcm16k := pcm
	if sr == 48000 {
		dec := resample.NewDecimate3()
		pcm16k, _ = dec.Process(context.Background(), pcm)
	} else if sr != 16000 {
		fmt.Fprintf(os.Stderr, "unsupported sample rate %d (need 16000 or 48000)\n", sr)
		return 1
	}

	modelPath := os.Getenv("HOWL_MODEL_PATH")
	if modelPath == "" {
		modelPath = os.ExpandEnv("$HOME/Library/Application Support/VoiceKeyboard/models/ggml-tiny.en.bin")
	}
	lang := os.Getenv("HOWL_LANGUAGE")
	if lang == "" {
		lang = "en"
	}

	w, err := transcribe.NewWhisperCpp(transcribe.WhisperOptions{
		ModelPath: modelPath,
		Language:  lang,
	})
	if err != nil {
		fmt.Fprintf(os.Stderr, "load model: %v\n", err)
		return 1
	}
	defer w.Close()

	text, err := w.Transcribe(context.Background(), pcm16k)
	if err != nil {
		fmt.Fprintf(os.Stderr, "transcribe: %v\n", err)
		return 1
	}
	fmt.Println(text)
	return 0
}
