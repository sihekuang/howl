//go:build !deepfilter

package main

import "github.com/voice-keyboard/core/internal/denoise"

// modelPath ignored in the CGo-free build.
func newDeepFilterOrPassthrough(modelPath string) denoise.Denoiser {
	return denoise.NewPassthrough()
}
