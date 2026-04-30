//go:build !whispercpp

package main

import (
	"fmt"
	"os"
)

func runTranscribe(_ []string) int {
	fmt.Fprintln(os.Stderr, "vkb-cli: 'transcribe' requires -tags whispercpp (whisper.cpp CGo)")
	return 1
}
