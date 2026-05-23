package speaker

import (
	"fmt"
	"sync"

	ort "github.com/yalue/onnxruntime_go"
)

// VAD reports whether a 100ms window of 16kHz mono samples contains voiced speech.
type VAD interface {
	IsVoiced(samples []float32) bool
}

const (
	sileroSampleRate = 16000
	sileroStateDepth = 2
	sileroStateBatch = 1
	sileroStateSize  = 64
	sileroThreshold  = float32(0.5)
)

// SileroVAD implements VAD using silero_vad.onnx.
// Construct a new instance per Pipeline.Run — the RNN state resets on construction.
type SileroVAD struct {
	session *ort.DynamicAdvancedSession
	h       []float32 // shape [2,1,64] flattened — RNN hidden state
	c       []float32 // shape [2,1,64] flattened — RNN cell state
}

// InitONNXRuntime initializes the ONNX runtime environment with the
// shared library at libPath. Idempotent: subsequent calls are no-ops
// and return nil.
//
// Idempotency matters because the Mac app rebuilds the pipeline on
// every settings change (howl_configure), and that rebuild path goes
// through pipeline.LoadTSE → InitONNXRuntime. Without this guard,
// the second-and-later calls fail with "onnxruntime has already been
// initialized", which propagates as a "TSE load failed" log line
// and silently drops the TSE chunk stage. Symptom: the first
// configure runs with TSE; every subsequent configure runs without
// it, and the session viewer shows no tse.wav.
//
// libPath is captured at first init; the value passed on subsequent
// calls is ignored (callers should always pass the same path).
func InitONNXRuntime(libPath string) error {
	onnxInitMu.Lock()
	defer onnxInitMu.Unlock()
	if onnxInitDone {
		return nil
	}
	ort.SetSharedLibraryPath(libPath)
	if err := ort.InitializeEnvironment(); err != nil {
		return err
	}
	onnxInitDone = true
	return nil
}

var (
	onnxInitMu   sync.Mutex
	onnxInitDone bool
)

// NewSileroVAD loads the Silero VAD ONNX model from modelPath.
func NewSileroVAD(modelPath string) (*SileroVAD, error) {
	session, err := ort.NewDynamicAdvancedSession(
		modelPath,
		[]string{"input", "sr", "h", "c"},
		[]string{"output", "hn", "cn"},
		nil,
	)
	if err != nil {
		return nil, fmt.Errorf("silero vad: load %q: %w", modelPath, err)
	}
	stateLen := sileroStateDepth * sileroStateBatch * sileroStateSize
	return &SileroVAD{
		session: session,
		h:       make([]float32, stateLen),
		c:       make([]float32, stateLen),
	}, nil
}

// IsVoiced returns true when samples contain voiced speech (probability > 0.5).
// Updates internal RNN state — not safe for concurrent calls.
func (v *SileroVAD) IsVoiced(samples []float32) bool {
	inputT, err := ort.NewTensor(ort.NewShape(1, int64(len(samples))), samples)
	if err != nil {
		return false
	}
	defer inputT.Destroy()

	srT, err := ort.NewTensor(ort.NewShape(1), []int64{int64(sileroSampleRate)})
	if err != nil {
		return false
	}
	defer srT.Destroy()

	hT, err := ort.NewTensor(ort.NewShape(sileroStateDepth, sileroStateBatch, sileroStateSize), v.h)
	if err != nil {
		return false
	}
	defer hT.Destroy()

	cT, err := ort.NewTensor(ort.NewShape(sileroStateDepth, sileroStateBatch, sileroStateSize), v.c)
	if err != nil {
		return false
	}
	defer cT.Destroy()

	outT, err := ort.NewEmptyTensor[float32](ort.NewShape(1))
	if err != nil {
		return false
	}
	defer outT.Destroy()

	hnT, err := ort.NewEmptyTensor[float32](ort.NewShape(sileroStateDepth, sileroStateBatch, sileroStateSize))
	if err != nil {
		return false
	}
	defer hnT.Destroy()

	cnT, err := ort.NewEmptyTensor[float32](ort.NewShape(sileroStateDepth, sileroStateBatch, sileroStateSize))
	if err != nil {
		return false
	}
	defer cnT.Destroy()

	if err := v.session.Run(
		[]ort.Value{inputT, srT, hT, cT},
		[]ort.Value{outT, hnT, cnT},
	); err != nil {
		return false
	}

	prob := outT.GetData()[0]
	copy(v.h, hnT.GetData())
	copy(v.c, cnT.GetData())
	return prob > sileroThreshold
}

// Close releases the ONNX session.
func (v *SileroVAD) Close() error {
	return v.session.Destroy()
}
