package denoise

// Passthrough is a no-op Denoiser used when the user disables noise
// suppression. It returns the input frame unchanged.
type Passthrough struct{}

func NewPassthrough() *Passthrough { return &Passthrough{} }

func (p *Passthrough) Process(frame []float32) []float32 {
	out := make([]float32, len(frame))
	copy(out, frame)
	return out
}

func (p *Passthrough) Close() error { return nil }
