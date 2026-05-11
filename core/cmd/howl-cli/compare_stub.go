//go:build !whispercpp

package main

import (
	"fmt"
	"os"
)

func runCompare(_ []string) int {
	fmt.Fprintln(os.Stderr, "howl: 'compare' requires -tags whispercpp (whisper.cpp CGo)")
	return 1
}
