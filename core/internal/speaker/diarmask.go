package speaker

import (
	"context"
	"fmt"
	"math"

	"github.com/voice-keyboard/core/internal/audio"
)

const (
	diarSampleRate  = 16000
	diarWindowLen   = diarSampleRate * 10 // 160000 samples = 10 s
	diarNumClasses  = 7
	diarMaxSpeakers = 3
)

// powersetClasses maps each of the 7 output classes to the set of local
// speakers (0-based) active in that class, per pyannote/segmentation-3.0.
var powersetClasses = [diarNumClasses][]int{
	{},     // 0: non-speech
	{0},    // 1
	{1},    // 2
	{2},    // 3
	{0, 1}, // 4
	{0, 2}, // 5
	{1, 2}, // 6
}

// SpeakerActivity is per-frame local-speaker activity for one window.
type SpeakerActivity struct {
	Frames          [][]bool // [frame][localSpeaker] active? (len diarMaxSpeakers)
	FrameHopSamples int      // samples per frame at 16 kHz
}

// powersetToActivity decodes a pyannote powerset segmentation tensor into
// per-frame speaker activity. data is the flat output; shape is its ONNX
// shape (leading size-1 dims allowed); the final dim must be 7.
func powersetToActivity(data []float32, shape []int64, hopSamples int) (SpeakerActivity, error) {
	if len(shape) == 0 || shape[len(shape)-1] != diarNumClasses {
		return SpeakerActivity{}, fmt.Errorf("diarmask: expected last dim %d, got shape %v", diarNumClasses, shape)
	}
	numFrames := 1
	for _, d := range shape[:len(shape)-1] {
		numFrames *= int(d)
	}
	if numFrames*diarNumClasses != len(data) {
		return SpeakerActivity{}, fmt.Errorf("diarmask: shape %v implies %d values, got %d", shape, numFrames*diarNumClasses, len(data))
	}
	frames := make([][]bool, numFrames)
	for f := 0; f < numFrames; f++ {
		row := data[f*diarNumClasses : (f+1)*diarNumClasses]
		best := 0
		for c := 1; c < diarNumClasses; c++ {
			if row[c] > row[best] {
				best = c
			}
		}
		active := make([]bool, diarMaxSpeakers)
		for _, spk := range powersetClasses[best] {
			active[spk] = true
		}
		frames[f] = active
	}
	return SpeakerActivity{Frames: frames, FrameHopSamples: hopSamples}, nil
}

// buildFrameMask returns per-frame keep/drop for the target track. A frame is
// kept whenever the target is active (including overlap with other speakers).
func buildFrameMask(act SpeakerActivity, targetIdx int) []bool {
	m := make([]bool, len(act.Frames))
	for f, active := range act.Frames {
		if targetIdx >= 0 && targetIdx < len(active) {
			m[f] = active[targetIdx]
		}
	}
	return m
}

// frameMaskToSamples upsamples a frame-level boolean mask to an n-sample gain
// curve in [0,1], applying a raised-cosine fade of rampSamples at the start and
// end of every active run (including the signal boundaries) to avoid clicks.
// At the center of a long run the gain is exactly 1; at a run edge it is 0.
func frameMaskToSamples(frameMask []bool, hopSamples, n, rampSamples int) []float32 {
	gain := make([]float32, n)
	if hopSamples <= 0 {
		return gain
	}
	on := func(i int) bool {
		if i < 0 || i >= n {
			return false // off the ends of the signal → treat as inactive
		}
		f := i / hopSamples
		return f < len(frameMask) && frameMask[f]
	}
	for i := 0; i < n; i++ {
		if !on(i) {
			continue
		}
		if rampSamples <= 0 {
			gain[i] = 1
			continue
		}
		// d = distance to the nearer edge of this active run, capped at
		// rampSamples (symmetric expansion stops when either side turns off).
		d := 0
		for d < rampSamples && on(i-d-1) && on(i+d+1) {
			d++
		}
		t := float64(d) / float64(rampSamples)
		gain[i] = float32(0.5 * (1 - math.Cos(math.Pi*t)))
	}
	return gain
}

// applyMask multiplies mixed by gain element-wise. Returns a fresh slice.
func applyMask(mixed, gain []float32) []float32 {
	out := make([]float32, len(mixed))
	for i := range mixed {
		if i < len(gain) {
			out[i] = mixed[i] * gain[i]
		}
	}
	return out
}

// Segmenter produces per-frame local-speaker activity for ONE ≤10 s window of
// 16 kHz mono audio (implementations zero-pad short input to the model length).
// DiarMask owns windowing across longer buffers.
type Segmenter interface {
	Segment(ctx context.Context, window []float32) (SpeakerActivity, error)
	Close() error
}

// DiarMaskOptions configures NewDiarMask. See the design spec for semantics.
type DiarMaskOptions struct {
	Segmenter           Segmenter
	Embed               func([]float32) ([]float32, error) // embeds 16 kHz mono → L2-normalised vector
	Reference           []float32                          // enrolled L2-normalised embedding
	MinSelectCosine     float32                            // below → low-confidence passthrough (default 0.40)
	MinExclusiveSeconds float32                            // min exclusive speech to embed a track (default 0.75)
	FallbackPassthrough bool                               // default true; false → mask even when low-confidence
	BoundaryRampMs      int                                // raised-cosine ramp at mask edges (default 15)
}

// DiarMask is a Cleanup + audio.Stage that isolates the enrolled speaker by
// time-masking the original audio (no separation, no threshold gate).
type DiarMask struct {
	opts           DiarMaskOptions
	rampSamples    int
	minExclusive   int
	lastSimilarity float32
}

// NewDiarMask validates options and applies defaults.
func NewDiarMask(opts DiarMaskOptions) (*DiarMask, error) {
	if opts.Segmenter == nil {
		return nil, fmt.Errorf("diarmask: nil Segmenter")
	}
	if opts.Embed == nil {
		return nil, fmt.Errorf("diarmask: nil Embed")
	}
	if len(opts.Reference) == 0 {
		return nil, fmt.Errorf("diarmask: empty Reference")
	}
	if opts.MinSelectCosine == 0 {
		opts.MinSelectCosine = 0.40
	}
	if opts.BoundaryRampMs == 0 {
		opts.BoundaryRampMs = 15
	}
	return &DiarMask{
		opts:           opts,
		rampSamples:    opts.BoundaryRampMs * diarSampleRate / 1000,
		minExclusive:   int(opts.MinExclusiveSeconds * float32(diarSampleRate)),
		lastSimilarity: 1.0,
	}, nil
}

func (d *DiarMask) Name() string    { return "audio_filter" }
func (d *DiarMask) OutputRate() int { return 0 }

// LastSimilarity returns the best target-track cosine observed in the last
// Process call (1.0 when every window passed through).
func (d *DiarMask) LastSimilarity() float32 {
	if d == nil {
		return 0
	}
	return d.lastSimilarity
}

// Close releases the segmenter.
func (d *DiarMask) Close() error {
	if d == nil || d.opts.Segmenter == nil {
		return nil
	}
	return d.opts.Segmenter.Close()
}

// Process masks the enrolled speaker's audio out of mixed. Returns same-length
// 16 kHz mono. Windows of diarWindowLen are processed independently; per-window
// masks are concatenated.
func (d *DiarMask) Process(ctx context.Context, mixed []float32) ([]float32, error) {
	gain := make([]float32, len(mixed))
	bestCos := float32(-2)
	sawSelection := false
	for start := 0; start < len(mixed); start += diarWindowLen {
		end := start + diarWindowLen
		if end > len(mixed) {
			end = len(mixed)
		}
		window := mixed[start:end]
		winGain, cos, selected, err := d.processWindow(ctx, window)
		if err != nil {
			return nil, err
		}
		copy(gain[start:end], winGain)
		if selected {
			sawSelection = true
			if cos > bestCos {
				bestCos = cos
			}
		}
	}
	if sawSelection {
		d.lastSimilarity = bestCos
	} else {
		d.lastSimilarity = 1.0
	}
	return applyMask(mixed, gain), nil
}

// processWindow returns the gain curve for one window plus the selection cosine
// (selected=false → all-ones passthrough gain).
func (d *DiarMask) processWindow(ctx context.Context, window []float32) ([]float32, float32, bool, error) {
	passthrough := func() []float32 {
		g := make([]float32, len(window))
		for i := range g {
			g[i] = 1
		}
		return g
	}
	act, err := d.opts.Segmenter.Segment(ctx, window)
	if err != nil {
		return nil, 0, false, fmt.Errorf("diarmask: segment: %w", err)
	}
	idx, cos, ok, err := selectTarget(act, window, d.opts.Embed, d.opts.Reference, d.minExclusive)
	if err != nil {
		return nil, 0, false, err
	}
	// Single-track (or nothing qualifies) → keep everything.
	if !ok || idx < 0 {
		return passthrough(), 0, false, nil
	}
	// Low-confidence → keep everything when fallback is on.
	if cos < d.opts.MinSelectCosine && d.opts.FallbackPassthrough {
		return passthrough(), cos, false, nil
	}
	frameMask := buildFrameMask(act, idx)
	g := frameMaskToSamples(frameMask, act.FrameHopSamples, len(window), d.rampSamples)
	return g, cos, true, nil
}

// Compile-time interface checks.
var _ Cleanup = (*DiarMask)(nil)
var _ audio.Stage = (*DiarMask)(nil)

// selectTarget embeds each local speaker's exclusive-frame audio and returns
// the track whose embedding has the highest cosine to ref. ok is false when
// fewer than two tracks have enough exclusive audio to embed (nothing to
// separate → caller should pass through).
func selectTarget(act SpeakerActivity, window []float32, embed func([]float32) ([]float32, error), ref []float32, minExclusiveSamples int) (int, float32, bool, error) {
	hop := act.FrameHopSamples
	// Gather exclusive samples per speaker.
	exclusive := make([][]float32, diarMaxSpeakers)
	for f, active := range act.Frames {
		count := 0
		only := -1
		for spk, on := range active {
			if on {
				count++
				only = spk
			}
		}
		if count != 1 {
			continue // non-speech or overlap → not exclusive
		}
		start := f * hop
		end := start + hop
		if start >= len(window) {
			break
		}
		if end > len(window) {
			end = len(window)
		}
		exclusive[only] = append(exclusive[only], window[start:end]...)
	}
	bestIdx, bestCos, qualifying := -1, float32(-2), 0
	for spk := 0; spk < diarMaxSpeakers; spk++ {
		if len(exclusive[spk]) == 0 || len(exclusive[spk]) < minExclusiveSamples {
			continue // never embed an empty track (ComputeEmbedding rejects empty input)
		}
		qualifying++
		emb, err := embed(exclusive[spk])
		if err != nil {
			return 0, 0, false, fmt.Errorf("diarmask: embed track %d: %w", spk, err)
		}
		c := cosineSimilarity(ref, emb)
		if c > bestCos {
			bestCos, bestIdx = c, spk
		}
	}
	if qualifying < 2 {
		return bestIdx, bestCos, false, nil
	}
	return bestIdx, bestCos, true, nil
}
