package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"time"

	"github.com/voice-keyboard/core/internal/speaker"
)

func main() {
	duration := flag.Duration("duration", 10*time.Second, "recording duration")
	outDir := flag.String("out", filepath.Join(os.Getenv("HOME"), ".config", "voice-keyboard"), "output directory for speaker.json and enrollment.wav")
	flag.Parse()

	if err := os.MkdirAll(*outDir, 0755); err != nil {
		log.Fatalf("create output dir: %v", err)
	}

	fmt.Fprintf(os.Stderr, "🎙  Recording for %v — speak naturally, then wait...\n", *duration)

	e := speaker.NewEnroller(16000)
	if err := e.Record(context.Background(), *outDir, *duration); err != nil {
		log.Fatalf("enrollment failed: %v", err)
	}

	fmt.Fprintf(os.Stderr, "✓ Enrolled. Profile saved to %s\n", *outDir)
}
