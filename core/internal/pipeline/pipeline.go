// Package pipeline orchestrates one PTT cycle:
//
//	frames (pushed) → FrameStages → chunk → ChunkStages → transcribe (per chunk) → dict → clean → Result
//
// Capture is no longer the pipeline's concern: callers push 48 kHz mono
// Float32 frames in over a channel and close it when done. FrameStages
// (e.g. denoise, decimate) run on every frame; the Chunker emits
// utterance-aligned 16kHz chunks to the ChunkStages (e.g. TSE) and then
// Whisper. Chunk texts are joined before the dict + LLM stages. Lifecycle
// (where audio comes from) belongs to the composition root.
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
	"github.com/voice-keyboard/core/internal/dict"
	"github.com/voice-keyboard/core/internal/llm"
	"github.com/voice-keyboard/core/internal/recorder"
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

// Pipeline runs the audio → transcribe → dict → LLM cycle.
// FrameStages run on continuous input; ChunkStages run per chunk emitted by the
// fixed Chunker between them. The composer is responsible for sample-rate
// alignment between adjacent stages (no graph-time validation).
type Pipeline struct {
	FrameStages []audio.Stage
	ChunkStages []audio.Stage

	Transcriber transcribe.Transcriber
	Dict        dict.Dictionary
	Cleaner     llm.Cleaner

	// Listener observes pipeline events. Fires from multiple goroutines —
	// implementation must be safe under concurrent invocation. Optional.
	Listener Listener

	// Recorder taps audio after each stage and the three transcript
	// stages. Optional; nil means no recording.
	Recorder *recorder.Session

	ChunkerOpts ChunkerOpts
}

// New builds a Pipeline with no stages. Composer assigns FrameStages /
// ChunkStages explicitly.
func New(t transcribe.Transcriber, dy dict.Dictionary, cl llm.Cleaner) *Pipeline {
	return &Pipeline{Transcriber: t, Dict: dy, Cleaner: cl}
}

// Run drains `frames` (Float32 mono, sample rate = whatever the first
// FrameStage expects, typically 48 kHz) until the channel closes or ctx
// is cancelled.
func (p *Pipeline) Run(ctx context.Context, frames <-chan []float32) (Result, error) {
	if p == nil {
		return Result{}, errors.New("pipeline: nil receiver")
	}
	log.Printf("[vkb] pipeline.Run: starting; awaiting frames")
	tStart := time.Now()
	defer func() {
		log.Printf("[vkb] pipeline.Run: total elapsed %v", time.Since(tStart))
	}()

	frameRate, chunkRate := p.registerRecorderStages()
	_ = frameRate // useful for future per-frame rate-aware logic
	_ = chunkRate // useful for future per-chunk rate-aware logic

	opts := p.ChunkerOpts
	if opts.VoiceThreshold == 0 && opts.SilenceHangMs == 0 && opts.MaxChunkMs == 0 {
		opts = DefaultChunkerOpts()
	}
	chunkCh := make(chan ChunkEmission, 4)
	var chunkIdx int
	chunker := NewChunker(opts, func(e ChunkEmission) {
		chunkIdx++
		dur := len(e.Samples) * 1000 / chunkerSampleRate
		log.Printf("[vkb] chunk emitted #%d: %dms (%s)", chunkIdx, dur, e.Reason)
		p.emit(Event{
			Kind:       EventChunkEmitted,
			ChunkIdx:   chunkIdx,
			DurationMs: dur,
			Reason:     string(e.Reason),
		})
		select {
		case chunkCh <- e:
		case <-ctx.Done():
		}
	})

	// Chunk worker — single goroutine.
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
				mu.Lock()
				workerErr = ctx.Err()
				mu.Unlock()
				for range chunkCh {
				}
				return
			case e, ok := <-chunkCh:
				if !ok {
					return
				}
				samples := e.Samples
				for _, st := range p.ChunkStages {
					rmsIn := audio.RMS(samples)
					out, err := st.Process(ctx, samples)
					if err != nil {
						mu.Lock()
						workerErr = fmt.Errorf("%s: %w", st.Name(), err)
						mu.Unlock()
						for range chunkCh {
						}
						return
					}
					p.emit(Event{
						Kind:   EventStageProcessed,
						Stage:  st.Name(),
						RMSIn:  rmsIn,
						RMSOut: audio.RMS(out),
					})
					p.Recorder.AppendStage(st.Name(), out)
					samples = out
				}

				t0 := time.Now()
				text, terr := p.Transcriber.Transcribe(ctx, samples)
				if terr != nil {
					mu.Lock()
					workerErr = terr
					mu.Unlock()
					for range chunkCh {
					}
					return
				}
				transcribed++
				ms := int(time.Since(t0).Milliseconds())
				log.Printf("[vkb] chunk #%d transcribe: %dms → %q", transcribed, ms, text)
				p.emit(Event{
					Kind:      EventChunkTranscribed,
					ChunkIdx:  transcribed,
					ElapsedMs: ms,
					Text:      text,
				})
				mu.Lock()
				chunkTexts = append(chunkTexts, text)
				mu.Unlock()
			}
		}
	}()

	// Foreground frame loop — closures over `chunker` and `ctx`.
	runFrameStages := func(in []float32) error {
		samples := in
		for _, st := range p.FrameStages {
			rmsIn := audio.RMS(samples)
			out, err := st.Process(ctx, samples)
			if err != nil {
				return fmt.Errorf("%s: %w", st.Name(), err)
			}
			p.emit(Event{Kind: EventStageProcessed, Stage: st.Name(), RMSIn: rmsIn, RMSOut: audio.RMS(out)})
			p.Recorder.AppendStage(st.Name(), out)
			samples = out
		}
		chunker.Push(samples)
		return nil
	}
	flushFrameStages := func() error {
		// TODO: only the LAST FrameStage's residual is currently flushed
		// to the chunker. Earlier-stage residuals would need to re-enter
		// the chain at their stage; not implemented for now.
		if len(p.FrameStages) == 0 {
			return nil
		}
		last := p.FrameStages[len(p.FrameStages)-1]
		f, ok := last.(audio.Flusher)
		if !ok {
			return nil
		}
		residual, err := f.Flush(ctx)
		if err != nil {
			return fmt.Errorf("%s flush: %w", last.Name(), err)
		}
		if len(residual) == 0 {
			return nil
		}
		p.emit(Event{Kind: EventStageProcessed, Stage: last.Name(), RMSOut: audio.RMS(residual)})
		p.Recorder.AppendStage(last.Name(), residual)
		chunker.Push(residual)
		return nil
	}

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
		if err := runFrameStages(f); err != nil {
			// Drain chunkCh so the worker can exit; signal it.
			close(chunkCh)
			<-workerDone
			return Result{}, err
		}
	}
	if err := flushFrameStages(); err != nil {
		close(chunkCh)
		<-workerDone
		return Result{}, err
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
	_ = p.Recorder.WriteTranscript("raw.txt", raw)
	if raw == "" {
		return Result{}, nil
	}
	corrected, terms := p.Dict.Match(raw)
	log.Printf("[vkb] pipeline.Run: dict matched %d terms", len(terms))
	_ = p.Recorder.WriteTranscript("dict.txt", corrected)

	tLLM := time.Now()
	var cleaned string
	var llmErr error
	firstTokenSeen := false
	wrappedDelta := func(s string) {
		if !firstTokenSeen {
			firstTokenSeen = true
			elapsed := int(time.Since(tLLM).Milliseconds())
			log.Printf("[vkb] LLM stream first token: %dms after stop", elapsed)
			p.emit(Event{Kind: EventLLMFirstToken, ElapsedMs: elapsed})
		}
		p.emit(Event{Kind: EventLLMDelta, Text: s})
	}
	if streamer, ok := p.Cleaner.(llm.StreamingCleaner); ok && p.Listener != nil {
		log.Printf("[vkb] pipeline.Run: cleaning via LLM (streaming)…")
		cleaned, llmErr = streamer.CleanStream(ctx, corrected, terms, wrappedDelta)
	} else {
		log.Printf("[vkb] pipeline.Run: cleaning via LLM…")
		cleaned, llmErr = p.Cleaner.Clean(ctx, corrected, terms)
	}
	if llmErr != nil {
		log.Printf("[vkb] pipeline.Run: LLM FAILED after %v: %v (using dict-corrected fallback)", time.Since(tLLM), llmErr)
		_ = p.Recorder.WriteTranscript("cleaned.txt", corrected)
		return Result{Raw: raw, Cleaned: corrected, Terms: terms, LLMError: llmErr}, nil
	}
	log.Printf("[vkb] pipeline.Run: LLM done in %v cleanedLen=%d", time.Since(tLLM), len(cleaned))
	_ = p.Recorder.WriteTranscript("cleaned.txt", cleaned)
	return Result{Raw: raw, Cleaned: cleaned, Terms: terms}, nil
}

// registerRecorderStages walks both stage slices, computing each stage's
// output sample rate and registering it with the Recorder. Returns the
// running rate at the start of FrameStages and at the start of ChunkStages
// (the latter is just informational for now).
func (p *Pipeline) registerRecorderStages() (frameRate, chunkRate int) {
	frameRate, chunkRate = inputSampleRate, chunkerSampleRate
	if p.Recorder == nil {
		return
	}
	rate := frameRate
	for _, st := range p.FrameStages {
		_ = p.Recorder.AddStage(st.Name(), rateOf(st, rate))
		if r := st.OutputRate(); r != 0 {
			rate = r
		}
	}
	chunkRate = rate
	for _, st := range p.ChunkStages {
		_ = p.Recorder.AddStage(st.Name(), rateOf(st, rate))
		if r := st.OutputRate(); r != 0 {
			rate = r
		}
	}
	return
}

func rateOf(st audio.Stage, prev int) int {
	if r := st.OutputRate(); r != 0 {
		return r
	}
	return prev
}

func (p *Pipeline) emit(e Event) {
	if p.Listener == nil {
		return
	}
	p.Listener(e)
}

// LoadTSE initialises a TSE extractor for the given backend and loads the
// enrollment embedding from profileDir. Returns nil extractor + nil error
// when speaker.json is absent (TSE off). Returns error only on partial
// state (json present but embedding missing/corrupt).
//
// modelsDir holds the backend's ONNX files (resolved via backend.TSEPath).
func LoadTSE(backend *speaker.Backend, profileDir, modelsDir, onnxLibPath string) (audio.Stage, error) {
	if backend == nil {
		backend = speaker.Default
	}
	_, err := speaker.LoadProfile(profileDir)
	if os.IsNotExist(err) {
		return nil, nil // no enrollment — TSE off
	}
	if err != nil {
		return nil, fmt.Errorf("load tse: profile: %w", err)
	}
	embPath := profileDir + "/enrollment.emb"
	ref, err := speaker.LoadEmbedding(embPath, backend.EmbeddingDim)
	if os.IsNotExist(err) {
		return nil, fmt.Errorf("load tse: enrollment.emb missing — re-run enroll.sh")
	}
	if err != nil {
		return nil, fmt.Errorf("load tse: embedding: %w", err)
	}
	if err := speaker.InitONNXRuntime(onnxLibPath); err != nil {
		return nil, fmt.Errorf("load tse: onnx runtime: %w", err)
	}
	tse, err := speaker.NewSpeakerGate(backend.TSEPath(modelsDir), ref)
	if err != nil {
		return nil, fmt.Errorf("load tse: model: %w", err)
	}
	return tse, nil
}

// Close releases resources owned by stages and the transcriber.
func (p *Pipeline) Close() error {
	if p == nil {
		return nil
	}
	var firstErr error
	for _, st := range append(append([]audio.Stage(nil), p.FrameStages...), p.ChunkStages...) {
		if c, ok := st.(audio.Closer); ok {
			if err := c.Close(); err != nil && firstErr == nil {
				firstErr = err
			}
		}
	}
	if p.Transcriber != nil {
		if err := p.Transcriber.Close(); err != nil && firstErr == nil {
			firstErr = err
		}
	}
	return firstErr
}
