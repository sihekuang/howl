// Package recorder taps audio + transcripts at each pipeline layer for
// offline inspection. Writes one streaming WAV per registered stage at
// the stage's output sample rate, plus plain-text transcript files.
//
// Layout under Dir (only files for enabled taps appear):
//
//	<stage>.wav   per AddStage call
//	raw.txt       joined raw Whisper text
//	dict.txt      after dict-correction
//	cleaned.txt   after LLM cleanup
//
// Methods on a nil *Session are safe no-ops, so callers can write:
//
//	if rec, _ := recorder.Open(opts); rec != nil { defer rec.Close() }
//	rec.AppendStage("denoise", out) // safe even if rec == nil
package recorder

import (
	"encoding/binary"
	"fmt"
	"math"
	"os"
	"path/filepath"
	"sync"

	"github.com/voice-keyboard/core/internal/sessions"
)

// Options selects which taps are enabled and where files land.
type Options struct {
	Dir         string
	AudioStages bool // enable per-stage WAVs (registered via AddStage)
	Transcripts bool // enable raw.txt / dict.txt / cleaned.txt
}

// Session is the live recording context for one pipeline run.
type Session struct {
	dir         string
	audioOn     bool
	transcripts bool

	mu     sync.Mutex
	stages map[string]*wavWriter
}

// Open creates the output directory if any tap is enabled. Returns
// (nil, nil) when nothing is enabled — callers can treat that as "off".
func Open(opts Options) (*Session, error) {
	if !opts.AudioStages && !opts.Transcripts {
		return nil, nil
	}
	if opts.Dir == "" {
		return nil, fmt.Errorf("recorder: Dir is required when a tap is enabled")
	}
	if err := os.MkdirAll(opts.Dir, 0o755); err != nil {
		return nil, fmt.Errorf("recorder: mkdir %q: %w", opts.Dir, err)
	}
	return &Session{
		dir:         opts.Dir,
		audioOn:     opts.AudioStages,
		transcripts: opts.Transcripts,
		stages:      map[string]*wavWriter{},
	}, nil
}

// AddStage registers a stage by name + sample rate. The output file is
// <dir>/<name>.wav. Calling AddStage with the same name twice is an error.
// No-op when audio recording is disabled.
func (s *Session) AddStage(name string, sampleRate int) error {
	if s == nil || !s.audioOn {
		return nil
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, ok := s.stages[name]; ok {
		return fmt.Errorf("recorder: stage %q already registered", name)
	}
	w, err := newWavWriter(filepath.Join(s.dir, name+".wav"), sampleRate)
	if err != nil {
		return err
	}
	s.stages[name] = w
	return nil
}

// AppendStage streams samples to the named stage's WAV. Unknown / disabled
// names are silently ignored — caller doesn't need to guard.
func (s *Session) AppendStage(name string, samples []float32) {
	if s == nil || !s.audioOn || len(samples) == 0 {
		return
	}
	s.mu.Lock()
	w := s.stages[name]
	s.mu.Unlock()
	if w == nil {
		return
	}
	w.append(samples)
}

// WriteTranscript saves text under the given filename (e.g. "raw.txt").
// No-op when transcripts are disabled.
func (s *Session) WriteTranscript(name, text string) error {
	if s == nil || !s.transcripts {
		return nil
	}
	return os.WriteFile(filepath.Join(s.dir, name), []byte(text), 0o644)
}

// WriteManifest serializes a session manifest to <dir>/session.json so
// readers (Inspector, howl-cli) can discover what each WAV represents.
// Caller fills the Manifest with metadata; recorder is the writer
// because it owns the directory the WAVs live in.
//
// No-op when called on a nil *Session.
func (s *Session) WriteManifest(m *sessions.Manifest) error {
	if s == nil {
		return nil
	}
	return m.Write(s.dir)
}

// Close patches the header of every WAV writer and closes the file.
// Safe to call on a nil Session and safe to call multiple times.
func (s *Session) Close() error {
	if s == nil {
		return nil
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	var firstErr error
	for _, w := range s.stages {
		if err := w.close(); err != nil && firstErr == nil {
			firstErr = err
		}
	}
	s.stages = nil
	return firstErr
}

// Dir returns the output directory ("" for nil Session).
func (s *Session) Dir() string {
	if s == nil {
		return ""
	}
	return s.dir
}

// --- streaming WAV writer (16-bit PCM mono) ---

const (
	wavBitsPerSample = 16
	wavChannels      = 1
)

type wavWriter struct {
	mu         sync.Mutex
	f          *os.File
	sampleRate uint32
	dataBytes  uint32
	closed     bool
}

func newWavWriter(path string, sampleRate int) (*wavWriter, error) {
	f, err := os.Create(path)
	if err != nil {
		return nil, fmt.Errorf("recorder: create %q: %w", path, err)
	}
	w := &wavWriter{f: f, sampleRate: uint32(sampleRate)}
	if err := w.writeHeader(0); err != nil {
		_ = f.Close()
		_ = os.Remove(path)
		return nil, err
	}
	return w, nil
}

func (w *wavWriter) writeHeader(dataBytes uint32) error {
	const fmtChunkSize uint32 = 16
	chunkLen := 36 + dataBytes
	byteRate := w.sampleRate * wavChannels * wavBitsPerSample / 8
	blockAlign := uint16(wavChannels * wavBitsPerSample / 8)
	if _, err := w.f.Seek(0, 0); err != nil {
		return err
	}
	if _, err := w.f.Write([]byte("RIFF")); err != nil {
		return err
	}
	if err := binary.Write(w.f, binary.LittleEndian, chunkLen); err != nil {
		return err
	}
	if _, err := w.f.Write([]byte("WAVEfmt ")); err != nil {
		return err
	}
	if err := binary.Write(w.f, binary.LittleEndian, fmtChunkSize); err != nil {
		return err
	}
	if err := binary.Write(w.f, binary.LittleEndian, uint16(1)); err != nil {
		return err
	}
	if err := binary.Write(w.f, binary.LittleEndian, uint16(wavChannels)); err != nil {
		return err
	}
	if err := binary.Write(w.f, binary.LittleEndian, w.sampleRate); err != nil {
		return err
	}
	if err := binary.Write(w.f, binary.LittleEndian, byteRate); err != nil {
		return err
	}
	if err := binary.Write(w.f, binary.LittleEndian, blockAlign); err != nil {
		return err
	}
	if err := binary.Write(w.f, binary.LittleEndian, uint16(wavBitsPerSample)); err != nil {
		return err
	}
	if _, err := w.f.Write([]byte("data")); err != nil {
		return err
	}
	return binary.Write(w.f, binary.LittleEndian, dataBytes)
}

// append streams samples as int16 PCM, little-endian.
// Errors are swallowed (best-effort tap); the eventual close() surfaces
// header-patch failure if any.
func (w *wavWriter) append(samples []float32) {
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.closed || len(samples) == 0 {
		return
	}
	buf := make([]byte, 2*len(samples))
	for i, s := range samples {
		v := int16(math.MaxInt16 * clamp(s, -1, 1))
		buf[2*i] = byte(v)
		buf[2*i+1] = byte(v >> 8)
	}
	n, _ := w.f.Write(buf)
	w.dataBytes += uint32(n)
}

func (w *wavWriter) close() error {
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.closed {
		return nil
	}
	w.closed = true
	if err := w.writeHeader(w.dataBytes); err != nil {
		_ = w.f.Close()
		return err
	}
	return w.f.Close()
}

func clamp(v, lo, hi float32) float32 {
	if v < lo {
		return lo
	}
	if v > hi {
		return hi
	}
	return v
}
