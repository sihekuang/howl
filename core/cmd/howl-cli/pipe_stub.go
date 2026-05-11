//go:build !whispercpp

package main

import (
	"fmt"
	"os"
)

func runPipe(_ []string) int {
	fmt.Fprintln(os.Stderr, "howl: 'pipe' requires -tags whispercpp (whisper.cpp CGo)")
	return 1
}
