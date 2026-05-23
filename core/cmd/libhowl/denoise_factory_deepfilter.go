//go:build deepfilter

package main

import "github.com/voice-keyboard/core/internal/denoise"

const dfDefaultAttenLimDB = 100.0

func newDeepFilterOrPassthrough(modelPath string) denoise.Denoiser {
	if modelPath == "" {
		return denoise.NewPassthrough()
	}
	d, err := denoise.NewDeepFilter(modelPath, dfDefaultAttenLimDB)
	if err != nil {
		return denoise.NewPassthrough()
	}
	return d
}
