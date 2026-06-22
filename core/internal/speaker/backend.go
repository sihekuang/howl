package speaker

import (
	"fmt"
	"path/filepath"
	"sort"
)

// BackendKind distinguishes how a backend isolates the enrolled speaker.
type BackendKind int

const (
	// BackendSeparation reconstructs the target's audio (TSE / SpeakerGate).
	BackendSeparation BackendKind = iota
	// BackendDiarMask diarizes, cosine-SELECTs the enrolled track, and
	// time-MASKs the original audio (DiarMask + pyannote segmenter).
	BackendDiarMask
)

// Backend describes a TSE backend: the on-disk model layout and the shape
// of the embedding it produces.
//
// Different backends bundle different speaker encoders and separators into
// the combined TSE ONNX, but they all conform to the audio.Stage interface
// (and the TSEExtractor alias) — so the pipeline is backend-agnostic.
// Adding a backend is a matter of
// writing the export script and registering a new Backend value here.
type Backend struct {
	// Name is the identifier surfaced in flags, logs, and config.
	Name string
	// Kind selects the isolation strategy (separation vs diarize-mask).
	Kind BackendKind
	// EmbeddingDim is the encoder output dimensionality (length of
	// enrollment.emb / ref_embedding tensor).
	EmbeddingDim int
	// EncoderModelFile is the speaker-encoder ONNX filename inside modelsDir.
	EncoderModelFile string
	// TSEModelFile is the combined-TSE (separation) ONNX filename inside
	// modelsDir. Set only for BackendSeparation.
	TSEModelFile string
	// SegModelFile is the segmentation ONNX filename inside modelsDir.
	// Set only for BackendDiarMask.
	SegModelFile string
}

// EncoderPath resolves the encoder ONNX file relative to modelsDir.
func (b *Backend) EncoderPath(modelsDir string) string {
	return filepath.Join(modelsDir, b.EncoderModelFile)
}

// TSEPath resolves the combined-TSE ONNX file relative to modelsDir.
func (b *Backend) TSEPath(modelsDir string) string {
	return filepath.Join(modelsDir, b.TSEModelFile)
}

// SegPath resolves the segmentation ONNX file relative to modelsDir.
func (b *Backend) SegPath(modelsDir string) string {
	return filepath.Join(modelsDir, b.SegModelFile)
}

// ECAPA: Wespeaker ECAPA-TDNN-512 with Kaldi Fbank front-end + JorisCos
// ConvTasNet Libri2Mix sep_noisy 16k separator. Output is 192-dim,
// L2-normalised inside the ONNX.
var ECAPA = &Backend{
	Name:             "ecapa",
	Kind:             BackendSeparation,
	EmbeddingDim:     192,
	EncoderModelFile: "speaker_encoder.onnx",
	TSEModelFile:     "tse_model.onnx",
}

// Pyannote: pyannote/segmentation-3.0 powerset diarizer + ECAPA encoder for
// cosine target SELECT, then time-MASK of the original audio (no separation,
// no suppression gate). Inclusion-biased — see DiarMask.
var Pyannote = &Backend{
	Name:             "pyannote",
	Kind:             BackendDiarMask,
	EmbeddingDim:     192,
	EncoderModelFile: "speaker_encoder.onnx",
	SegModelFile:     "pyannote_seg.onnx",
}

// Default is the backend used when no explicit selection is made.
var Default = ECAPA

// backends is the registry keyed by Name. Add new backends here.
var backends = map[string]*Backend{
	ECAPA.Name:    ECAPA,
	Pyannote.Name: Pyannote,
}

// BackendByName returns the registered backend with the given name. If
// name is empty, returns Default. Returns an error for unknown names.
func BackendByName(name string) (*Backend, error) {
	if name == "" {
		return Default, nil
	}
	b, ok := backends[name]
	if !ok {
		return nil, fmt.Errorf("speaker: unknown backend %q", name)
	}
	return b, nil
}

// BackendNames returns all registered backend names in sorted order.
func BackendNames() []string {
	names := make([]string, 0, len(backends))
	for n := range backends {
		names = append(names, n)
	}
	sort.Strings(names)
	return names
}
