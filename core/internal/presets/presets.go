// Package presets manages bundled and user-defined pipeline presets.
//
// Bundled presets live in pipeline-presets.json (embedded at build
// time). User presets live in
//
//	~/Library/Application Support/VoiceKeyboard/presets/<name>.json
//
// (one file per preset).
//
// The schema is versioned at birth (CurrentVersion). Add new optional
// fields without bumping; structural changes bump.
package presets

import (
	"encoding/json"
	"fmt"
)

// CurrentVersion is the major version this build understands. The
// bundle loader rejects anything else; the user preset loader is more
// forgiving (skips unparseable files with a log).
const CurrentVersion = 1

// Bundle is the wire shape of pipeline-presets.json.
type Bundle struct {
	Version int      `json:"version"`
	Presets []Preset `json:"presets"`
}

// Preset is one named pipeline configuration.
type Preset struct {
	Name        string         `json:"name"`
	Description string         `json:"description"`
	FrameStages []StageSpec    `json:"frame_stages"`
	ChunkStages []StageSpec    `json:"chunk_stages"`
	Transcribe  TranscribeSpec `json:"transcribe"`
	LLM         LLMSpec        `json:"llm"`
	// TimeoutSec is the per-preset pipeline timeout in seconds.
	// Pointer so 0 (disable timeout) differs from "not set".
	TimeoutSec *int `json:"timeout_sec,omitempty"`
}

// StageSpec is a per-stage entry inside a preset. Threshold is a
// pointer so 0.0 (legitimately disable gating) is distinguishable from
// "not set in JSON" (also nil after decode of an absent key).
type StageSpec struct {
	Name      string   `json:"name"`
	Enabled   bool     `json:"enabled"`
	Backend   string   `json:"backend,omitempty"`
	Threshold *float32 `json:"threshold,omitempty"`
}

// TranscribeSpec mirrors the transcribe-related fields of EngineConfig.
type TranscribeSpec struct {
	ModelSize string `json:"model_size"`
}

// LLMSpec mirrors the LLM-related fields of EngineConfig.
type LLMSpec struct {
	Provider string `json:"provider"`
}

// parseBundle parses a pipeline-presets.json blob and returns its
// Presets slice. Rejects unknown major versions.
func parseBundle(buf []byte) ([]Preset, error) {
	var b Bundle
	if err := json.Unmarshal(buf, &b); err != nil {
		return nil, fmt.Errorf("presets: parse bundle: %w", err)
	}
	if b.Version != CurrentVersion {
		return nil, fmt.Errorf("presets: unsupported bundle version %d (this build supports %d)", b.Version, CurrentVersion)
	}
	return b.Presets, nil
}

// loadBundled parses the //go:embed bundle.
func loadBundled() ([]Preset, error) {
	return parseBundle(builtinJSON)
}
