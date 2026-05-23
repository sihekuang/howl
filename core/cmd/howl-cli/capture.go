package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"time"

	"github.com/voice-keyboard/core/internal/audio"
)

func runCapture(args []string) int {
	fs := flag.NewFlagSet("capture", flag.ContinueOnError)
	out := fs.String("out", "capture.wav", "output WAV file path")
	secs := fs.Int("secs", 3, "seconds to record")
	if err := fs.Parse(args); err != nil {
		return 2
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt)
	defer stop()

	cap := audio.NewMalgoCapture()
	frames, err := cap.Start(ctx, 48000)
	if err != nil {
		fmt.Fprintf(os.Stderr, "capture: %v\n", err)
		return 1
	}
	fmt.Fprintf(os.Stderr, "Recording %d seconds (Ctrl-C to stop early)...\n", *secs)

	deadline := time.After(time.Duration(*secs) * time.Second)
	var pcm []float32
loop:
	for {
		select {
		case f, ok := <-frames:
			if !ok {
				break loop
			}
			pcm = append(pcm, f...)
		case <-deadline:
			_ = cap.Stop()
		case <-ctx.Done():
			_ = cap.Stop()
		}
	}
	if err := writeWavMonoFloat(*out, pcm, 48000); err != nil {
		fmt.Fprintf(os.Stderr, "write wav: %v\n", err)
		return 1
	}
	fmt.Fprintf(os.Stderr, "Wrote %d samples (%.1fs) to %s\n", len(pcm), float64(len(pcm))/48000.0, *out)
	return 0
}
