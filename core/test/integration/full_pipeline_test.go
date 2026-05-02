//go:build integration && whispercpp

package integration

import (
	"context"
	"encoding/binary"
	"math"
	"net/http"
	"net/http/httptest"
	"os"
	"sync/atomic"
	"testing"
	"time"

	"github.com/voice-keyboard/core/internal/audio"
	"github.com/voice-keyboard/core/internal/denoise"
	"github.com/voice-keyboard/core/internal/dict"
	"github.com/voice-keyboard/core/internal/llm"
	"github.com/voice-keyboard/core/internal/pipeline"
	"github.com/voice-keyboard/core/internal/resample"
	"github.com/voice-keyboard/core/internal/transcribe"
)

func TestFullPipeline_RealWhisperFakeAudioMockedLLM(t *testing.T) {
	modelPath := os.ExpandEnv("$HOME/Library/Application Support/VoiceKeyboard/models/ggml-tiny.en.bin")
	if _, err := os.Stat(modelPath); err != nil {
		t.Skipf("Whisper model missing at %s", modelPath)
	}

	pcm48k, err := loadFixtureAt48k("testdata/hello-world.wav")
	if err != nil {
		t.Fatalf("load fixture: %v", err)
	}

	// Mock Anthropic — returns a constant cleaned string.
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{
			"id":"msg","type":"message","role":"assistant",
			"content":[{"type":"text","text":"Cleaned output."}],
			"model":"claude-sonnet-4-6","stop_reason":"end_turn",
			"usage":{"input_tokens":1,"output_tokens":1}
		}`))
	}))
	defer srv.Close()

	cap := audio.NewFakeCapture(pcm48k, denoise.FrameSize)
	d := denoise.NewPassthrough()
	tr, err := transcribe.NewWhisperCpp(transcribe.WhisperOptions{ModelPath: modelPath, Language: "en"})
	if err != nil {
		t.Fatalf("NewWhisperCpp: %v", err)
	}
	defer tr.Close()
	dy := dict.NewFuzzy(nil, 1)
	cl, err := llm.NewAnthropic(llm.AnthropicOptions{
		APIKey:  "sk-ant-test",
		Model:   "claude-sonnet-4-6",
		BaseURL: srv.URL,
		Timeout: 5 * time.Second,
	})
	if err != nil {
		t.Fatalf("NewAnthropic: %v", err)
	}

	p := pipeline.New(tr, dy, cl)
	p.FrameStages = []audio.Stage{denoise.NewStage(d), resample.NewDecimate3()}

	var levelCount int32
	p.Listener = func(ev pipeline.Event) {
		if ev.Kind == pipeline.EventStageProcessed && ev.Stage == "denoise" {
			atomic.AddInt32(&levelCount, 1)
		}
	}

	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()

	frames, err := cap.Start(ctx, 48000)
	if err != nil {
		t.Fatalf("capture start: %v", err)
	}

	res, err := p.Run(ctx, frames)
	_ = cap.Stop()
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if res.Cleaned != "Cleaned output." {
		t.Errorf("Cleaned = %q, want \"Cleaned output.\"", res.Cleaned)
	}
	if res.Raw == "" {
		t.Errorf("Raw should be non-empty (whisper produced something)")
	}
	t.Logf("raw=%q cleaned=%q", res.Raw, res.Cleaned)
	if atomic.LoadInt32(&levelCount) == 0 {
		t.Errorf("expected at least one stage_processed event for 'denoise', got 0")
	}
}

// loadFixtureAt48k reads a 16kHz WAV and naively upsamples 3x for the
// pipeline's 48kHz input expectation. Test shim only — the pipeline
// itself decimates back to 16kHz inside Whisper.
func loadFixtureAt48k(path string) ([]float32, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var pcm16k []float32
	// RIFF chunk walker (reuses the same logic as the test fixture loader
	// in the WhisperCpp test). Walks chunks starting at offset 12 looking
	// for "data".
	if len(data) < 44 || string(data[0:4]) != "RIFF" || string(data[8:12]) != "WAVE" {
		return nil, os.ErrInvalid
	}
	for i := 12; i+8 <= len(data); {
		chunkID := string(data[i : i+4])
		size := int(binary.LittleEndian.Uint32(data[i+4 : i+8]))
		if chunkID == "data" {
			if i+8+size > len(data) {
				return nil, os.ErrInvalid
			}
			raw := data[i+8 : i+8+size]
			pcm16k = make([]float32, len(raw)/2)
			for j := range pcm16k {
				v := int16(binary.LittleEndian.Uint16(raw[j*2 : j*2+2]))
				pcm16k[j] = float32(v) / float32(math.MaxInt16)
			}
			break
		}
		next := i + 8 + size
		if size%2 == 1 {
			next++
		}
		if next <= i {
			return nil, os.ErrInvalid
		}
		i = next
	}
	if pcm16k == nil {
		return nil, os.ErrInvalid
	}
	out := make([]float32, len(pcm16k)*3)
	for i, s := range pcm16k {
		out[i*3] = s
		out[i*3+1] = s
		out[i*3+2] = s
	}
	return out, nil
}
