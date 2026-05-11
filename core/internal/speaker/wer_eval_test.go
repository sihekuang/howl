//go:build cleanupeval

package speaker

import (
	"context"
	"testing"

	"github.com/voice-keyboard/core/internal/transcribe"
)

// fakeTranscriber returns a hard-coded string regardless of input.
// Decouples the WER evaluator test from whisper.cpp.
type fakeTranscriber struct{ out string }

func (f *fakeTranscriber) Transcribe(_ context.Context, _ []float32) (string, error) {
	return f.out, nil
}
func (f *fakeTranscriber) Close() error { return nil }

func TestEvaluateWER_PerfectMatch(t *testing.T) {
	tr := &fakeTranscriber{out: "the quick brown fox"}
	res := evaluateWER(t, []float32{0, 0, 0}, "the quick brown fox", tr)
	if res.WER != 0 {
		t.Errorf("perfect: WER=%f, want 0", res.WER)
	}
	if res.Hypothesis != "the quick brown fox" {
		t.Errorf("hypothesis = %q", res.Hypothesis)
	}
}

func TestEvaluateWER_RecordsBothStrings(t *testing.T) {
	tr := &fakeTranscriber{out: "wrong words entirely"}
	res := evaluateWER(t, []float32{0}, "expected text here", tr)
	if res.Reference != "expected text here" {
		t.Errorf("Reference not stored")
	}
	if res.Hypothesis != "wrong words entirely" {
		t.Errorf("Hypothesis not stored")
	}
	if res.WER != 1.0 {
		t.Errorf("all wrong: WER=%f, want 1.0", res.WER)
	}
}

// Compile-time check that fakeTranscriber implements the interface.
var _ transcribe.Transcriber = (*fakeTranscriber)(nil)

type werResult struct {
	Reference  string
	Hypothesis string
	WER        float64
}

// evaluateWER runs the transcriber on audio and computes WER vs
// reference. Calls t.Fatalf on transcription failure (a transcribe
// error is a harness bug, not a measurement we want to log silently).
func evaluateWER(t *testing.T, audio []float32, reference string,
	transcriber transcribe.Transcriber) werResult {
	t.Helper()
	hyp, err := transcriber.Transcribe(context.Background(), audio)
	if err != nil {
		t.Fatalf("evaluateWER: transcribe failed: %v", err)
	}
	return werResult{
		Reference:  reference,
		Hypothesis: hyp,
		WER:        computeWER(reference, hyp),
	}
}
