// Package pipeline orchestrates one PTT cycle:
//
//	frames (pushed) → denoise → decimate → transcribe → dict → clean → Result
//
// Capture is no longer the pipeline's concern: callers push 48 kHz mono
// Float32 frames in over a channel and close it when done. Pipeline.Run
// drains, denoises in 480-sample frames, then runs the rest of the
// stages and returns Result. Lifecycle (where audio comes from) belongs
// to the composition root.
package pipeline

import (
	"context"
	"errors"
	"log"
	"time"

	"github.com/voice-keyboard/core/internal/audio"
	"github.com/voice-keyboard/core/internal/denoise"
	"github.com/voice-keyboard/core/internal/dict"
	"github.com/voice-keyboard/core/internal/llm"
	"github.com/voice-keyboard/core/internal/resample"
	"github.com/voice-keyboard/core/internal/transcribe"
)

const inputSampleRate = 48000

// Result of a single PTT cycle.
type Result struct {
	Raw      string // raw transcription, pre-dictionary
	Cleaned  string // final text to paste; equals dict-corrected raw if LLM failed
	Terms    []string
	LLMError error
}

type Pipeline struct {
	denoiser    denoise.Denoiser
	transcriber transcribe.Transcriber
	dict        dict.Dictionary
	cleaner     llm.Cleaner

	// LevelCallback, if non-nil, is invoked with the post-denoise RMS
	// (in [0, 1]) of each 480-sample frame. Set this on the Pipeline
	// before calling Run. Safe to omit; nil means no level publication.
	LevelCallback func(float32)
}

func New(d denoise.Denoiser, t transcribe.Transcriber,
	dy dict.Dictionary, cl llm.Cleaner) *Pipeline {
	return &Pipeline{
		denoiser: d, transcriber: t, dict: dy, cleaner: cl,
	}
}

// Run drains `frames` (Float32 mono @ 48 kHz) until the channel closes
// or ctx is cancelled, denoising as we go, then runs the remaining
// stages and returns Result. The caller owns the lifetime of `frames`
// — close the channel to signal end-of-input.
func (p *Pipeline) Run(ctx context.Context, frames <-chan []float32) (Result, error) {
	if p == nil {
		return Result{}, errors.New("pipeline: nil receiver")
	}

	log.Printf("[vkb] pipeline.Run: starting; awaiting frames")
	tStart := time.Now()
	defer func() {
		log.Printf("[vkb] pipeline.Run: total elapsed %v", time.Since(tStart))
	}()

	denoised := drainAndDenoise(ctx, frames, p.denoiser, p.LevelCallback)
	log.Printf("[vkb] pipeline.Run: capture+denoise done samples=%d (%.2fs of audio)", len(denoised), float64(len(denoised))/float64(inputSampleRate))

	dec := resample.NewDecimate3()
	pcm16k := dec.Process(denoised)
	log.Printf("[vkb] pipeline.Run: decimated to 16k samples=%d", len(pcm16k))

	tTrans := time.Now()
	log.Printf("[vkb] pipeline.Run: transcribing…")
	raw, err := p.transcriber.Transcribe(ctx, pcm16k)
	if err != nil {
		log.Printf("[vkb] pipeline.Run: transcribe FAILED after %v: %v", time.Since(tTrans), err)
		return Result{}, err
	}
	log.Printf("[vkb] pipeline.Run: transcribe done in %v rawLen=%d raw=%q", time.Since(tTrans), len(raw), raw)
	if raw == "" {
		log.Printf("[vkb] pipeline.Run: empty transcription; skipping LLM")
		return Result{}, nil
	}

	corrected, terms := p.dict.Match(raw)
	log.Printf("[vkb] pipeline.Run: dict matched %d terms", len(terms))

	tLLM := time.Now()
	log.Printf("[vkb] pipeline.Run: cleaning via LLM…")
	cleaned, llmErr := p.cleaner.Clean(ctx, corrected, terms)
	if llmErr != nil {
		log.Printf("[vkb] pipeline.Run: LLM FAILED after %v: %v (using dict-corrected fallback)", time.Since(tLLM), llmErr)
		return Result{Raw: raw, Cleaned: corrected, Terms: terms, LLMError: llmErr}, nil
	}
	log.Printf("[vkb] pipeline.Run: LLM done in %v cleanedLen=%d", time.Since(tLLM), len(cleaned))
	return Result{Raw: raw, Cleaned: cleaned, Terms: terms}, nil
}

// Close releases resources held by the transcriber and denoiser.
func (p *Pipeline) Close() error {
	if p == nil {
		return nil
	}
	var firstErr error
	if p.transcriber != nil {
		if err := p.transcriber.Close(); err != nil && firstErr == nil {
			firstErr = err
		}
	}
	if p.denoiser != nil {
		if err := p.denoiser.Close(); err != nil && firstErr == nil {
			firstErr = err
		}
	}
	return firstErr
}

// drainAndDenoise reads frames from `frames` until the channel closes
// or ctx is cancelled, denoising in 480-sample (10 ms) chunks. Any
// trailing partial frame is zero-padded so we don't drop the tail.
func drainAndDenoise(
	ctx context.Context,
	frames <-chan []float32,
	d denoise.Denoiser,
	levelCb func(float32),
) []float32 {
	var pending []float32
	var out []float32

	flush := func() {
		for len(pending) >= denoise.FrameSize {
			frame := pending[:denoise.FrameSize]
			out = append(out, d.Process(frame)...)
			denoisedTail := out[len(out)-denoise.FrameSize:]
			if levelCb != nil {
				levelCb(audio.RMS(denoisedTail))
			}
			pending = pending[denoise.FrameSize:]
		}
	}

	for {
		select {
		case f, ok := <-frames:
			if !ok {
				goto finalize
			}
			pending = append(pending, f...)
			flush()
		case <-ctx.Done():
			goto finalize
		}
	}
finalize:
	if len(pending) > 0 {
		last := make([]float32, denoise.FrameSize)
		copy(last, pending)
		out = append(out, d.Process(last)...)
		if levelCb != nil {
			denoisedTail := out[len(out)-denoise.FrameSize:]
			levelCb(audio.RMS(denoisedTail))
		}
	}
	return out
}
