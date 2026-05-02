package pipeline

import (
	"context"
	"errors"
	"math"
	"sync"
	"testing"
	"time"

	"github.com/voice-keyboard/core/internal/audio"
	"github.com/voice-keyboard/core/internal/denoise"
	"github.com/voice-keyboard/core/internal/dict"
	"github.com/voice-keyboard/core/internal/llm"
	"github.com/voice-keyboard/core/internal/resample"
	"github.com/voice-keyboard/core/internal/transcribe"
)

// fakeTSEExtractor records calls and returns zeros (simulates TSE suppressing all audio).
// The speaker reference is captured at construction time (matching TSEExtractor's design
// of encoding the ref in the implementation rather than passing it per-call).
type fakeTSEExtractor struct {
	calls int
	out   []float32 // if nil, returns zeros of mixed length
}

func (f *fakeTSEExtractor) Name() string    { return "fake-tse" }
func (f *fakeTSEExtractor) OutputRate() int { return 0 }
func (f *fakeTSEExtractor) Process(ctx context.Context, in []float32) ([]float32, error) {
	return f.Extract(ctx, in)
}
func (f *fakeTSEExtractor) Extract(_ context.Context, mixed []float32) ([]float32, error) {
	f.calls++
	if f.out != nil {
		return f.out, nil
	}
	return make([]float32, len(mixed)), nil
}

func newTestPipeline(tr transcribe.Transcriber, dy dict.Dictionary, cl llm.Cleaner) *Pipeline {
	p := New(tr, dy, cl)
	p.FrameStages = []audio.Stage{denoise.NewStage(denoise.NewPassthrough()), resample.NewDecimate3()}
	return p
}

func TestPipeline_TSENilSkipsExtract(t *testing.T) {
	src := make([]float32, 24000)
	for i := range src {
		src[i] = 0.1
	}
	tse := &fakeTSEExtractor{}
	p := newTestPipeline(&fakeTranscriber{out: "hello"}, dict.NewFuzzy(nil, 1), &fakeCleaner{out: "hello"})
	// TSE is nil — not set on pipeline

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_, err := p.Run(ctx, pushChan(src, denoise.FrameSize))
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if tse.calls != 0 {
		t.Errorf("Extract called %d times, want 0 when TSE is nil", tse.calls)
	}
}

func TestPipeline_TSEActiveCallsExtractPerChunk(t *testing.T) {
	tr := &fakeMultiTranscriber{outputs: []string{"hello", "world"}}
	cl := &fakeCleaner{out: "Hello world."}
	tse := &fakeTSEExtractor{}

	p := newTestPipeline(tr, dict.NewFuzzy(nil, 0), cl)
	p.ChunkStages = []audio.Stage{tse}
	p.ChunkerOpts = ChunkerOpts{
		VoiceThreshold: 0.005,
		SilenceHangMs:  100,
		MaxChunkMs:     12_000,
		ForceCutScanMs: 100,
	}

	frames := make(chan []float32, 4)
	frames <- toneFrames48k(500, 0.3)
	frames <- silence48k(200)
	frames <- toneFrames48k(500, 0.3)
	close(frames)

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_, err := p.Run(ctx, frames)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if tse.calls != 2 {
		t.Errorf("Extract calls = %d, want 2 (one per chunk)", tse.calls)
	}
}

func TestPipeline_TSEOutputZeroYieldsEmptyResult(t *testing.T) {
	// TSE returns zeros → Whisper gets silence → empty transcription → empty Result
	src := make([]float32, 24000)
	for i := range src {
		src[i] = 0.1
	}
	tse := &fakeTSEExtractor{} // returns zeros by default
	tr := &fakeTranscriber{out: ""}
	cl := &fakeCleaner{out: "should not be called"}

	p := newTestPipeline(tr, dict.NewFuzzy(nil, 1), cl)
	p.ChunkStages = []audio.Stage{tse}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	res, err := p.Run(ctx, pushChan(src, denoise.FrameSize))
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if res.Cleaned != "" {
		t.Errorf("expected empty Cleaned when TSE zeroes audio, got %q", res.Cleaned)
	}
}

type fakeTranscriber struct {
	out string
	err error
}

func (f *fakeTranscriber) Transcribe(ctx context.Context, _ []float32) (string, error) {
	return f.out, f.err
}
func (f *fakeTranscriber) Close() error { return nil }

type fakeCleaner struct {
	out string
	err error
}

func (f *fakeCleaner) Clean(ctx context.Context, _ string, _ []string) (string, error) {
	return f.out, f.err
}

// fakeStreamingCleaner exposes both Clean and CleanStream so tests can
// assert pipeline picks the streaming path when Listener is set
// and the cleaner satisfies StreamingCleaner.
type fakeStreamingCleaner struct {
	out         string
	err         error
	chunks      []string // pre-recorded deltas to emit through onDelta
	cleanCalls  int
	streamCalls int
}

func (f *fakeStreamingCleaner) Clean(ctx context.Context, _ string, _ []string) (string, error) {
	f.cleanCalls++
	return f.out, f.err
}

func (f *fakeStreamingCleaner) CleanStream(
	ctx context.Context, _ string, _ []string, onDelta func(string),
) (string, error) {
	f.streamCalls++
	for _, c := range f.chunks {
		onDelta(c)
	}
	return f.out, f.err
}

// pushChan returns a closed channel pre-loaded with `samples` chunked
// into `chunkSize`-sample frames, simulating Swift pushing frames in.
func pushChan(samples []float32, chunkSize int) <-chan []float32 {
	ch := make(chan []float32, len(samples)/chunkSize+2)
	for i := 0; i < len(samples); i += chunkSize {
		end := i + chunkSize
		if end > len(samples) {
			end = len(samples)
		}
		ch <- samples[i:end]
	}
	close(ch)
	return ch
}

func TestPipeline_HappyPath(t *testing.T) {
	src := make([]float32, 24000)
	for i := range src {
		src[i] = 0.1 // voiced — above VoiceThreshold so the chunker emits
	}
	dy := dict.NewFuzzy([]string{"WebRTC"}, 1)
	tr := &fakeTranscriber{out: "hello webrt world"}
	cl := &fakeCleaner{out: "Hello, WebRTC world."}

	p := newTestPipeline(tr, dy, cl)

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	res, err := p.Run(ctx, pushChan(src, denoise.FrameSize))
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if res.Cleaned != "Hello, WebRTC world." {
		t.Errorf("Cleaned = %q", res.Cleaned)
	}
	if res.Raw != "hello webrt world" {
		t.Errorf("Raw = %q", res.Raw)
	}
}

func TestPipeline_LLMErrorFallsBackToDictText(t *testing.T) {
	src := make([]float32, 24000)
	for i := range src {
		src[i] = 0.1
	}
	dy := dict.NewFuzzy([]string{"WebRTC"}, 1)
	tr := &fakeTranscriber{out: "use webrt please"}
	cl := &fakeCleaner{err: errors.New("network down")}

	p := newTestPipeline(tr, dy, cl)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	res, err := p.Run(ctx, pushChan(src, denoise.FrameSize))
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if res.Cleaned != "use WebRTC please" {
		t.Errorf("Cleaned should fall back to dict-corrected raw; got %q", res.Cleaned)
	}
	if res.LLMError == nil {
		t.Errorf("LLMError should be set when LLM fails")
	}
}

func TestPipeline_StageProcessedEventFires(t *testing.T) {
	src := make([]float32, 24000) // 0.5s @ 48kHz
	for i := range src {
		src[i] = 0.5
	}
	dy := dict.NewFuzzy(nil, 1)
	tr := &fakeTranscriber{out: "hi"}
	cl := &fakeCleaner{out: "hi"}

	p := newTestPipeline(tr, dy, cl)
	var levels []float32
	var levelMu sync.Mutex
	p.Listener = func(e Event) {
		if e.Kind == EventStageProcessed && e.Stage == "denoise" {
			levelMu.Lock()
			levels = append(levels, e.RMSOut)
			levelMu.Unlock()
		}
	}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	_, err := p.Run(ctx, pushChan(src, denoise.FrameSize))
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	levelMu.Lock()
	defer levelMu.Unlock()
	if len(levels) == 0 {
		t.Fatalf("expected at least one level event")
	}
	for i, l := range levels {
		if l < 0.4 || l > 0.6 {
			t.Errorf("level[%d] = %f, expected ~0.5", i, l)
		}
	}
}

func TestPipeline_StreamingCleanerEmitsDeltas(t *testing.T) {
	src := make([]float32, 24000)
	for i := range src {
		src[i] = 0.1
	}
	dy := dict.NewFuzzy(nil, 1)
	tr := &fakeTranscriber{out: "hello world"}
	cl := &fakeStreamingCleaner{
		out:    "Hello world.",
		chunks: []string{"Hello", " world", "."},
	}

	p := newTestPipeline(tr, dy, cl)
	var got []string
	var mu sync.Mutex
	p.Listener = func(e Event) {
		if e.Kind == EventLLMDelta {
			mu.Lock()
			got = append(got, e.Text)
			mu.Unlock()
		}
	}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	res, err := p.Run(ctx, pushChan(src, denoise.FrameSize))
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if cl.streamCalls != 1 {
		t.Errorf("expected CleanStream invoked once, got %d (clean=%d)", cl.streamCalls, cl.cleanCalls)
	}
	if cl.cleanCalls != 0 {
		t.Errorf("non-streaming Clean should not be called when streaming path is active, got %d", cl.cleanCalls)
	}
	mu.Lock()
	defer mu.Unlock()
	if len(got) != 3 || got[0] != "Hello" || got[1] != " world" || got[2] != "." {
		t.Errorf("delta sequence wrong: %v", got)
	}
	if res.Cleaned != "Hello world." {
		t.Errorf("Cleaned = %q", res.Cleaned)
	}
}

func TestPipeline_StreamingCleanerNoCallbackFallsBackToClean(t *testing.T) {
	src := make([]float32, 24000)
	for i := range src {
		src[i] = 0.1
	}
	dy := dict.NewFuzzy(nil, 1)
	tr := &fakeTranscriber{out: "hello"}
	cl := &fakeStreamingCleaner{
		out:    "Hello.",
		chunks: []string{"should", "not", "fire"},
	}

	p := newTestPipeline(tr, dy, cl)
	// Listener intentionally nil — pipeline should pick the
	// non-streaming Clean path even though cleaner can stream.

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if _, err := p.Run(ctx, pushChan(src, denoise.FrameSize)); err != nil {
		t.Fatalf("Run: %v", err)
	}
	if cl.streamCalls != 0 {
		t.Errorf("CleanStream should NOT be called when Listener is nil; got %d", cl.streamCalls)
	}
	if cl.cleanCalls != 1 {
		t.Errorf("expected one Clean call, got %d", cl.cleanCalls)
	}
}

func TestPipeline_NonStreamingCleanerWithCallbackStillUsesClean(t *testing.T) {
	src := make([]float32, 24000)
	dy := dict.NewFuzzy(nil, 1)
	tr := &fakeTranscriber{out: "hello"}
	cl := &fakeCleaner{out: "Hello."} // does NOT implement StreamingCleaner

	p := newTestPipeline(tr, dy, cl)
	deltaCalls := 0
	p.Listener = func(e Event) {
		if e.Kind == EventLLMDelta {
			deltaCalls++
		}
	}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if _, err := p.Run(ctx, pushChan(src, denoise.FrameSize)); err != nil {
		t.Fatalf("Run: %v", err)
	}
	if deltaCalls != 0 {
		t.Errorf("non-streaming cleaner should never invoke delta events; got %d", deltaCalls)
	}
}

// toneFrames48k generates ms milliseconds of 440Hz sine at 48kHz with given peak amplitude.
func toneFrames48k(ms int, peak float32) []float32 {
	n := 48 * ms
	out := make([]float32, n)
	for i := 0; i < n; i++ {
		out[i] = peak * float32(math.Sin(2*math.Pi*440*float64(i)/48000))
	}
	return out
}

func silence48k(ms int) []float32 {
	return make([]float32, 48*ms)
}

func TestPipeline_EmptyTranscriptionYieldsEmptyResult(t *testing.T) {
	src := make([]float32, 240) // half a frame
	dy := dict.NewFuzzy(nil, 1)
	tr := &fakeTranscriber{out: ""}
	cl := &fakeCleaner{out: "should not be called"}

	p := newTestPipeline(tr, dy, cl)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	res, err := p.Run(ctx, pushChan(src, denoise.FrameSize))
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if res.Cleaned != "" {
		t.Errorf("expected empty cleaned for empty raw, got %q", res.Cleaned)
	}
}

// fakeMultiTranscriber returns a different string per call.
type fakeMultiTranscriber struct {
	calls   int
	outputs []string
}

func (f *fakeMultiTranscriber) Transcribe(ctx context.Context, _ []float32) (string, error) {
	if f.calls >= len(f.outputs) {
		return "", nil
	}
	out := f.outputs[f.calls]
	f.calls++
	return out, nil
}
func (f *fakeMultiTranscriber) Close() error { return nil }

func TestPipeline_MultiChunkJoinedAndCleanedOnce(t *testing.T) {
	tr := &fakeMultiTranscriber{outputs: []string{"hello", "world"}}
	cl := &fakeStreamingCleaner{out: "Hello world.", chunks: []string{"Hello ", "world."}}
	p := newTestPipeline(tr, dict.NewFuzzy(nil, 0), cl)
	p.Listener = func(Event) {} // non-nil so streaming path is taken
	p.ChunkerOpts = ChunkerOpts{
		VoiceThreshold: 0.005,
		SilenceHangMs:  100, // tiny so the test silences split
		MaxChunkMs:     12_000,
		ForceCutScanMs: 100,
	}

	frames := make(chan []float32, 4)
	frames <- toneFrames48k(500, 0.3) // 500ms tone
	frames <- silence48k(200)         // 200ms silence > SilenceHangMs (100ms)
	frames <- toneFrames48k(500, 0.3) // 500ms tone
	close(frames)

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	res, err := p.Run(ctx, frames)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if tr.calls != 2 {
		t.Errorf("transcribe calls = %d, want 2", tr.calls)
	}
	if cl.streamCalls != 1 {
		t.Errorf("CleanStream calls = %d, want 1", cl.streamCalls)
	}
	if res.Raw != "hello world" {
		t.Errorf("Raw = %q, want %q", res.Raw, "hello world")
	}
	if res.Cleaned != "Hello world." {
		t.Errorf("Cleaned = %q, want %q", res.Cleaned, "Hello world.")
	}
}

type errOnNthTranscriber struct {
	calls  int
	failOn int
}

func (f *errOnNthTranscriber) Transcribe(ctx context.Context, _ []float32) (string, error) {
	f.calls++
	if f.calls == f.failOn {
		return "", errors.New("whisper boom")
	}
	return "ok", nil
}
func (f *errOnNthTranscriber) Close() error { return nil }

func TestPipeline_WorkerErrorPropagates(t *testing.T) {
	tr := &errOnNthTranscriber{failOn: 2}
	cl := &fakeStreamingCleaner{}
	p := newTestPipeline(tr, dict.NewFuzzy(nil, 0), cl)
	p.Listener = func(Event) {} // non-nil so streaming path is taken
	p.ChunkerOpts = ChunkerOpts{
		VoiceThreshold: 0.005,
		SilenceHangMs:  100,
		MaxChunkMs:     12_000,
		ForceCutScanMs: 100,
	}

	frames := make(chan []float32, 6)
	frames <- toneFrames48k(500, 0.3)
	frames <- silence48k(200)
	frames <- toneFrames48k(500, 0.3)
	frames <- silence48k(200)
	frames <- toneFrames48k(500, 0.3)
	close(frames)

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_, err := p.Run(ctx, frames)
	if err == nil || err.Error() != "whisper boom" {
		t.Fatalf("err = %v, want whisper boom", err)
	}
	if cl.streamCalls != 0 {
		t.Errorf("CleanStream called %d times, want 0 (LLM should not run on transcribe error)", cl.streamCalls)
	}
}

type slowTranscriber struct {
	delay time.Duration
}

func (s *slowTranscriber) Transcribe(ctx context.Context, _ []float32) (string, error) {
	select {
	case <-time.After(s.delay):
		return "ok", nil
	case <-ctx.Done():
		return "", ctx.Err()
	}
}
func (s *slowTranscriber) Close() error { return nil }

func TestPipeline_CancelMidRecordingReturnsContextErr(t *testing.T) {
	tr := &slowTranscriber{delay: 200 * time.Millisecond}
	cl := &fakeStreamingCleaner{}
	p := newTestPipeline(tr, dict.NewFuzzy(nil, 0), cl)
	p.Listener = func(Event) {} // non-nil so streaming path is taken
	p.ChunkerOpts = ChunkerOpts{
		VoiceThreshold: 0.005,
		SilenceHangMs:  100,
		MaxChunkMs:     12_000,
		ForceCutScanMs: 100,
	}

	frames := make(chan []float32, 4)
	go func() {
		frames <- toneFrames48k(500, 0.3)
		frames <- silence48k(200)
		frames <- toneFrames48k(500, 0.3)
		// don't close — let cancel cut us off
	}()

	ctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
	defer cancel()
	_, err := p.Run(ctx, frames)
	if !errors.Is(err, context.DeadlineExceeded) && !errors.Is(err, context.Canceled) {
		t.Fatalf("err = %v, want context.DeadlineExceeded or Canceled", err)
	}
	if cl.streamCalls != 0 {
		t.Errorf("CleanStream called %d times after cancel, want 0", cl.streamCalls)
	}
}
