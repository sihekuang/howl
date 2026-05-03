package presets

import (
	"github.com/voice-keyboard/core/internal/config"
)

// EngineSecrets carries values that don't live in preset JSON because
// they're per-installation (API keys) or per-machine (model paths).
// The Resolve caller fills these in from settings storage.
type EngineSecrets struct {
	LLMAPIKey           string
	WhisperModelPath    string
	DeepFilterModelPath string
	TSEProfileDir       string
	TSEModelPath        string
	SpeakerEncoderPath  string
	ONNXLibPath         string
	CustomDict          []string
	Language            string
	LLMBaseURL          string
	LLMModel            string
}

// Resolve produces a config.Config equivalent to running this preset.
// secrets supplies fields the preset doesn't (and shouldn't) specify.
//
// The resulting Config is bit-equivalent to what the user would have
// produced by clicking through Settings to assemble the same options.
// Both this Config and one written by the existing settings UI should
// pass `Match(cfg, []Preset{p})` if they describe the same preset.
func Resolve(p Preset, secrets EngineSecrets) config.Config {
	cfg := config.Config{
		WhisperModelPath:    secrets.WhisperModelPath,
		WhisperModelSize:    p.Transcribe.ModelSize,
		Language:            secrets.Language,
		DeepFilterModelPath: secrets.DeepFilterModelPath,
		LLMProvider:         p.LLM.Provider,
		LLMModel:            secrets.LLMModel,
		LLMAPIKey:           secrets.LLMAPIKey,
		LLMBaseURL:          secrets.LLMBaseURL,
		CustomDict:          secrets.CustomDict,
		DeveloperMode:       true, // presets only apply when dev mode is on
		TSEProfileDir:       secrets.TSEProfileDir,
		TSEModelPath:        secrets.TSEModelPath,
		SpeakerEncoderPath:  secrets.SpeakerEncoderPath,
		ONNXLibPath:         secrets.ONNXLibPath,
	}
	// Frame stages: walk the preset's list and translate per-name
	// (denoise → DisableNoiseSuppression, decimate3 → no toggle today).
	for _, st := range p.FrameStages {
		switch st.Name {
		case "denoise":
			cfg.DisableNoiseSuppression = !st.Enabled
		case "decimate3":
			// No corresponding Config field today (always on);
			// preset author can disable for documentation but the
			// engine still inserts decimate3.
		}
	}
	// Chunk stages: only TSE today.
	for _, st := range p.ChunkStages {
		if st.Name != "tse" {
			continue
		}
		cfg.TSEEnabled = st.Enabled
		cfg.TSEBackend = st.Backend
		if st.Threshold != nil {
			t := *st.Threshold
			cfg.TSEThreshold = &t
		}
	}
	return cfg
}
