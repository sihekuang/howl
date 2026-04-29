// Package pipeline orchestrates one PTT cycle:
//
//	capture → denoise → decimate → transcribe → dict → clean → Result
//
// Pipeline.Run is single-shot: each PTT press calls Run once. Lifecycle
// (start/stop) is owned by the composition root, not the pipeline.
package pipeline

import (
	"context"
	"errors"

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
	capture     audio.Capture
	denoiser    denoise.Denoiser
	transcriber transcribe.Transcriber
	dict        dict.Dictionary
	cleaner     llm.Cleaner

	// LevelCallback, if non-nil, is invoked with the post-denoise RMS
	// (in [0, 1]) of each 480-sample frame. Set this on the Pipeline
	// before calling Run. Safe to omit; nil means no level publication.
	LevelCallback func(float32)
}

func New(c audio.Capture, d denoise.Denoiser, t transcribe.Transcriber,
	dy dict.Dictionary, cl llm.Cleaner) *Pipeline {
	return &Pipeline{
		capture: c, denoiser: d, transcriber: t, dict: dy, cleaner: cl,
	}
}

// Run starts capture, accumulates audio until stopCh is closed (or ctx
// is cancelled), then runs the full processing pipeline and returns the
// Result. Capture is stopped on the way out.
func (p *Pipeline) Run(ctx context.Context, stopCh <-chan struct{}) (Result, error) {
	if p == nil {
		return Result{}, errors.New("pipeline: nil receiver")
	}

	frames, err := p.capture.Start(ctx, inputSampleRate)
	if err != nil {
		return Result{}, err
	}
	defer p.capture.Stop()

	denoised := captureAndDenoise(ctx, frames, stopCh, p.denoiser, p.LevelCallback)

	dec := resample.NewDecimate3()
	pcm16k := dec.Process(denoised)

	raw, err := p.transcriber.Transcribe(ctx, pcm16k)
	if err != nil {
		return Result{}, err
	}
	if raw == "" {
		return Result{}, nil
	}

	corrected, terms := p.dict.Match(raw)

	cleaned, llmErr := p.cleaner.Clean(ctx, corrected, terms)
	if llmErr != nil {
		// graceful degradation: ship the dict-corrected text
		return Result{Raw: raw, Cleaned: corrected, Terms: terms, LLMError: llmErr}, nil
	}
	return Result{Raw: raw, Cleaned: cleaned, Terms: terms}, nil
}

// Close releases resources held by the transcriber and denoiser. It is
// safe to call multiple times. Capture is started/stopped per Run, so
// it is not closed here.
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

// captureAndDenoise drains the capture channel, denoising in 480-sample
// (10ms) frames. Stops draining when stopCh fires, ctx is cancelled, or
// frames closes. Any partial trailing samples are zero-padded into a
// final frame so we don't lose the tail of an utterance.
func captureAndDenoise(
	ctx context.Context,
	frames <-chan []float32,
	stopCh <-chan struct{},
	d denoise.Denoiser,
	levelCb func(float32),
) []float32 {
	var pending []float32
	var out []float32

	flush := func() {
		for len(pending) >= denoise.FrameSize {
			frame := pending[:denoise.FrameSize]
			out = append(out, d.Process(frame)...)
			// Compute RMS over the post-denoise frame
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
		case <-stopCh:
			goto finalize
		case <-ctx.Done():
			goto finalize
		}
	}
finalize:
	if len(pending) > 0 {
		last := make([]float32, denoise.FrameSize)
		copy(last, pending)
		out = append(out, d.Process(last)...)
	}
	return out
}
