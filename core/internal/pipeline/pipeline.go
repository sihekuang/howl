// Package pipeline orchestrates one PTT cycle:
//
//	frames (pushed) → denoise → decimate → chunk → transcribe (per chunk) → dict → clean → Result
//
// Capture is no longer the pipeline's concern: callers push 48 kHz mono
// Float32 frames in over a channel and close it when done. Pipeline.Run
// drains, denoises in 480-sample frames, feeds the Chunker which emits
// utterance-aligned 16kHz chunks, and a single worker goroutine transcribes
// each chunk in arrival order. Chunk texts are joined before the dict + LLM
// stages. Lifecycle (where audio comes from) belongs to the composition root.
package pipeline

import (
	"context"
	"errors"
	"fmt"
	"log"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/voice-keyboard/core/internal/audio"
	"github.com/voice-keyboard/core/internal/denoise"
	"github.com/voice-keyboard/core/internal/dict"
	"github.com/voice-keyboard/core/internal/llm"
	"github.com/voice-keyboard/core/internal/resample"
	"github.com/voice-keyboard/core/internal/speaker"
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
	// (in [0, 1]) of each 480-sample frame.
	LevelCallback func(float32)

	// LLMDeltaCallback, if non-nil AND the configured cleaner satisfies
	// llm.StreamingCleaner, is invoked with each cleaned-text delta as
	// the LLM streams. Lets the host (Swift) type tokens at the cursor
	// before the full response lands. Safe to omit — pipeline falls
	// back to non-streaming Clean.
	LLMDeltaCallback func(string)

	// ChunkerOpts overrides the default chunker thresholds. Zero-value
	// fields fall back to DefaultChunkerOpts. Unset for production; the
	// CLI/tests set this to drive specific scenarios.
	ChunkerOpts ChunkerOpts

	// ChunkEmittedCallback fires when the chunker emits a chunk
	// (idx, durationMs, reason). Optional — used by --latency-report.
	ChunkEmittedCallback func(idx int, durationMs int, reason string)

	// ChunkTranscribedCallback fires after each chunk's Transcribe call
	// returns (idx, transcribeMs, text). Optional.
	ChunkTranscribedCallback func(idx int, transcribeMs int, text string)

	// LLMFirstTokenCallback fires when the first LLM delta arrives,
	// measured from when transcribe joined the final raw text. Optional.
	LLMFirstTokenCallback func(elapsedMs int)

	// TSE, when non-nil, extracts the enrolled user's voice from each chunk
	// before it reaches Whisper. Nil means TSE is off — pipeline behaves as today.
	TSE speaker.TSEExtractor

	// TSERef is the enrolled reference audio (loaded from enrollment.wav).
	// Required when TSE is non-nil; read-only during Run.
	TSERef []float32
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

	opts := p.ChunkerOpts
	if opts.VoiceThreshold == 0 && opts.SilenceHangMs == 0 && opts.MaxChunkMs == 0 {
		opts = DefaultChunkerOpts()
	}

	// Chunk channel — bounded at 4 (≈48s in flight at MaxChunkMs=12s).
	chunkCh := make(chan ChunkEmission, 4)

	dec := resample.NewDecimate3()
	var chunkIdx int
	chunker := NewChunker(opts, func(e ChunkEmission) {
		chunkIdx++
		dur := len(e.Samples) * 1000 / chunkerSampleRate
		log.Printf("[vkb] chunk emitted #%d: %dms (%s)", chunkIdx, dur, e.Reason)
		if p.ChunkEmittedCallback != nil {
			p.ChunkEmittedCallback(chunkIdx, dur, string(e.Reason))
		}
		select {
		case chunkCh <- e:
		case <-ctx.Done():
		}
	})

	// Transcribe worker — single goroutine, processes chunks in arrival order.
	var (
		mu          sync.Mutex
		chunkTexts  []string
		workerErr   error
		workerDone  = make(chan struct{})
		transcribed int
	)
	go func() {
		defer close(workerDone)
		for {
			select {
			case <-ctx.Done():
				workerErr = ctx.Err()
				for range chunkCh {
				}
				return
			case e, ok := <-chunkCh:
				if !ok {
					return
				}
				if p.TSE != nil {
					cleaned, tseErr := p.TSE.Extract(ctx, e.Samples, p.TSERef)
					if tseErr != nil {
						mu.Lock()
						workerErr = fmt.Errorf("tse: %w", tseErr)
						mu.Unlock()
						for range chunkCh {
						}
						return
					}
					e.Samples = cleaned
				}
				t0 := time.Now()
				text, err := p.transcriber.Transcribe(ctx, e.Samples)
				if err != nil {
					mu.Lock()
					workerErr = err
					mu.Unlock()
					for range chunkCh {
					}
					return
				}
				transcribed++
				ms := int(time.Since(t0).Milliseconds())
				log.Printf("[vkb] chunk #%d transcribe: %dms → %q", transcribed, ms, text)
				if p.ChunkTranscribedCallback != nil {
					p.ChunkTranscribedCallback(transcribed, ms, text)
				}
				mu.Lock()
				chunkTexts = append(chunkTexts, text)
				mu.Unlock()
			}
		}
	}()

	// Denoise + decimate + chunk in the foreground.
	for {
		var f []float32
		var ok bool
		select {
		case f, ok = <-frames:
		case <-ctx.Done():
			ok = false
		}
		if !ok {
			break
		}
		denoised := drainAndDenoiseStreaming(f, p.denoiser, p.LevelCallback)
		decimated := dec.Process(denoised)
		chunker.Push(decimated)
	}
	chunker.Flush()
	close(chunkCh)
	<-workerDone

	if workerErr != nil {
		log.Printf("[vkb] pipeline.Run: worker error: %v", workerErr)
		return Result{}, workerErr
	}

	mu.Lock()
	raw := strings.TrimSpace(strings.Join(chunkTexts, " "))
	mu.Unlock()
	log.Printf("[vkb] pipeline.Run: joined raw len=%d raw=%q", len(raw), raw)
	if raw == "" {
		log.Printf("[vkb] pipeline.Run: empty transcription; skipping LLM")
		return Result{}, nil
	}

	corrected, terms := p.dict.Match(raw)
	log.Printf("[vkb] pipeline.Run: dict matched %d terms", len(terms))

	tLLM := time.Now()
	var cleaned string
	var llmErr error
	firstTokenSeen := false
	deltaCb := p.LLMDeltaCallback
	wrappedDelta := func(s string) {
		if !firstTokenSeen {
			firstTokenSeen = true
			elapsed := int(time.Since(tLLM).Milliseconds())
			log.Printf("[vkb] LLM stream first token: %dms after stop", elapsed)
			if p.LLMFirstTokenCallback != nil {
				p.LLMFirstTokenCallback(elapsed)
			}
		}
		if deltaCb != nil {
			deltaCb(s)
		}
	}

	if streamer, ok := p.cleaner.(llm.StreamingCleaner); ok && deltaCb != nil {
		log.Printf("[vkb] pipeline.Run: cleaning via LLM (streaming)…")
		cleaned, llmErr = streamer.CleanStream(ctx, corrected, terms, wrappedDelta)
	} else {
		log.Printf("[vkb] pipeline.Run: cleaning via LLM…")
		cleaned, llmErr = p.cleaner.Clean(ctx, corrected, terms)
	}
	if llmErr != nil {
		log.Printf("[vkb] pipeline.Run: LLM FAILED after %v: %v (using dict-corrected fallback)", time.Since(tLLM), llmErr)
		return Result{Raw: raw, Cleaned: corrected, Terms: terms, LLMError: llmErr}, nil
	}
	log.Printf("[vkb] pipeline.Run: LLM done in %v cleanedLen=%d", time.Since(tLLM), len(cleaned))
	return Result{Raw: raw, Cleaned: cleaned, Terms: terms}, nil
}

// LoadTSE initialises a SpeakerGate and loads the enrollment embedding from profileDir.
// Returns nil extractor + nil error when speaker.json is absent (TSE off).
// Returns error only on partial state (json present but embedding missing/corrupt).
func LoadTSE(profileDir, modelPath, onnxLibPath string) (speaker.TSEExtractor, []float32, error) {
	_, err := speaker.LoadProfile(profileDir)
	if os.IsNotExist(err) {
		return nil, nil, nil // no enrollment — TSE off
	}
	if err != nil {
		return nil, nil, fmt.Errorf("load tse: profile: %w", err)
	}
	embPath := profileDir + "/enrollment.emb"
	ref, err := speaker.LoadEmbedding(embPath)
	if os.IsNotExist(err) {
		return nil, nil, fmt.Errorf("load tse: enrollment.emb missing — re-run enroll.sh")
	}
	if err != nil {
		return nil, nil, fmt.Errorf("load tse: embedding: %w", err)
	}
	if err := speaker.InitONNXRuntime(onnxLibPath); err != nil {
		return nil, nil, fmt.Errorf("load tse: onnx runtime: %w", err)
	}
	tse, err := speaker.NewSpeakerGate(modelPath)
	if err != nil {
		return nil, nil, fmt.Errorf("load tse: model: %w", err)
	}
	return tse, ref, nil
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

// drainAndDenoiseStreaming denoises one batch of input frames in
// 480-sample chunks, returning the concatenated denoised output.
// Sub-frame trailing samples are zero-padded so the tail isn't dropped.
func drainAndDenoiseStreaming(
	f []float32,
	d denoise.Denoiser,
	levelCb func(float32),
) []float32 {
	out := make([]float32, 0, len(f))
	i := 0
	for ; i+denoise.FrameSize <= len(f); i += denoise.FrameSize {
		frame := f[i : i+denoise.FrameSize]
		dn := d.Process(frame)
		out = append(out, dn...)
		if levelCb != nil {
			levelCb(audio.RMS(dn))
		}
	}
	if i < len(f) {
		last := make([]float32, denoise.FrameSize)
		copy(last, f[i:])
		dn := d.Process(last)
		out = append(out, dn...)
		if levelCb != nil {
			levelCb(audio.RMS(dn))
		}
	}
	return out
}
