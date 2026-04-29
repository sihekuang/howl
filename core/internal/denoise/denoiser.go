// Package denoise provides single-frame audio denoising. The Denoiser
// interface accepts and produces 480-sample float32 mono frames at 48kHz
// (10ms frames). Both the passthrough impl and the DeepFilterNet CGo
// impl satisfy this contract.
package denoise

const FrameSize = 480 // samples per frame at 48kHz, 10ms

type Denoiser interface {
	// Process accepts a single 480-sample frame and returns a denoised
	// 480-sample frame. It is the caller's responsibility to chunk
	// streaming audio into 480-sample frames before calling.
	Process(frame []float32) []float32

	// Close releases any underlying resources. Safe to call multiple times.
	Close() error
}
