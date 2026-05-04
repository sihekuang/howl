//go:build !whispercpp

package main

import (
	"fmt"
	"os"
)

func runCompare(_ []string) int {
	fmt.Fprintln(os.Stderr, "vkb-cli: 'compare' requires -tags whispercpp (whisper.cpp CGo)")
	return 1
}
