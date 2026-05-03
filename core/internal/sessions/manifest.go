// Package sessions owns the per-dictation session folder format used
// by the Pipeline tab's Inspector and Compare views. A session folder
// looks like:
//
//	<base>/<id>/
//	├── session.json            (Manifest)
//	├── <stage>.wav             one per pipeline stage (frame + chunk, flat)
//	└── transcripts/{raw,dict,cleaned}.txt
//
// The manifest is the contract between writers (Go pipeline + recorder)
// and readers (Mac Inspector, vkb-cli, replay engine). Versioned at
// birth; new optional fields can be added without bumping `Version`,
// structural changes bump.
package sessions

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
)

// CurrentManifestVersion is the major version this build understands.
// Reader rejects manifests with a different major version.
const CurrentManifestVersion = 1

// ErrManifestNotFound is returned (wrapped) by Read when the session
// folder exists but session.json is absent. Callers that walk a base
// directory (e.g. Store.List in Task 2) check errors.Is(err, ErrManifestNotFound)
// to distinguish "in-progress / unfinished session" from "corrupt
// manifest", and silently skip the former.
var ErrManifestNotFound = errors.New("sessions: manifest not found")

// Manifest is the on-disk session.json schema.
type Manifest struct {
	Version     int               `json:"version"`
	ID          string            `json:"id"`           // RFC3339 timestamp; matches the folder name
	Preset      string            `json:"preset"`       // name of the preset that produced this session ("default", "custom", ...)
	DurationSec float64           `json:"duration_sec"` // total dictation length
	Stages      []StageEntry      `json:"stages"`
	Transcripts TranscriptEntries `json:"transcripts"`
}

// StageEntry describes one captured stage. WavRel is the path of the
// stage's WAV relative to the session folder (e.g. "denoise.wav").
type StageEntry struct {
	Name          string  `json:"name"`
	Kind          string  `json:"kind"`                     // "frame" | "chunk"
	WavRel        string  `json:"wav"`                      // relative path inside session folder
	RateHz        int     `json:"rate_hz"`                  // output sample rate of this stage
	// TSESimilarity is the cosine similarity between the extracted
	// source's ECAPA embedding and the enrolled reference, populated
	// only for the TSE chunk stage. nil = stage didn't run / didn't
	// emit similarity; a non-nil zero is a legitimate value
	// (orthogonal embeddings) and must not be confused with absent.
	TSESimilarity *float32 `json:"tse_similarity,omitempty"`
}

// TranscriptEntries records the relative paths of the three text outputs.
type TranscriptEntries struct {
	Raw     string `json:"raw"`
	Dict    string `json:"dict"`
	Cleaned string `json:"cleaned"`
}

// Write serializes m to <dir>/session.json (overwriting if present).
// Caller is responsible for ensuring dir exists.
func (m *Manifest) Write(dir string) error {
	if m.Version == 0 {
		m.Version = CurrentManifestVersion
	}
	buf, err := json.MarshalIndent(m, "", "  ")
	if err != nil {
		return fmt.Errorf("sessions: marshal manifest: %w", err)
	}
	if err := os.WriteFile(filepath.Join(dir, "session.json"), buf, 0o644); err != nil {
		return fmt.Errorf("sessions: write manifest: %w", err)
	}
	return nil
}

// Read parses <dir>/session.json and returns the Manifest. Returns an
// error for missing files, malformed JSON, or an unknown major version
// (forward-incompat — caller should treat the session as unreadable
// until the runtime is upgraded).
func Read(dir string) (*Manifest, error) {
	buf, err := os.ReadFile(filepath.Join(dir, "session.json"))
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil, fmt.Errorf("%w: %s", ErrManifestNotFound, dir)
		}
		return nil, fmt.Errorf("sessions: read manifest: %w", err)
	}
	var m Manifest
	if err := json.Unmarshal(buf, &m); err != nil {
		return nil, fmt.Errorf("sessions: parse manifest: %w", err)
	}
	if m.Version != CurrentManifestVersion {
		return nil, fmt.Errorf("sessions: unsupported manifest version %d (this build supports %d)", m.Version, CurrentManifestVersion)
	}
	return &m, nil
}
