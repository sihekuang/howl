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

// Match returns the name of the preset whose Resolve(...) would produce
// `cfg`'s preset-relevant fields, or "custom" if no preset matches.
//
// Preset-relevant fields: those Resolve actually sets from the preset
// (TSEEnabled, TSEBackend, TSEThreshold, DisableNoiseSuppression,
// LLMProvider, WhisperModelSize). Fields populated only from secrets
// (LLMAPIKey, WhisperModelPath, etc.) are intentionally ignored —
// changing your API key doesn't make your config "custom."
func Match(cfg config.Config, all []Preset) string {
	for _, p := range all {
		if presetMatchesConfig(p, cfg) {
			return p.Name
		}
	}
	return "custom"
}

func presetMatchesConfig(p Preset, cfg config.Config) bool {
	if cfg.LLMProvider != p.LLM.Provider {
		return false
	}
	if cfg.WhisperModelSize != p.Transcribe.ModelSize {
		return false
	}
	for _, st := range p.FrameStages {
		switch st.Name {
		case "denoise":
			wantOff := !st.Enabled
			if cfg.DisableNoiseSuppression != wantOff {
				return false
			}
		}
	}
	for _, st := range p.ChunkStages {
		if st.Name != "tse" {
			continue
		}
		if cfg.TSEEnabled != st.Enabled {
			return false
		}
		if cfg.TSEEnabled {
			if cfg.TSEBackend != st.Backend {
				return false
			}
			// Threshold compare: nil-or-0 are treated as equivalent
			// ("no gating"); explicit non-zero must match.
			cfgThr := float32(0)
			if cfg.TSEThreshold != nil {
				cfgThr = *cfg.TSEThreshold
			}
			presetThr := float32(0)
			if st.Threshold != nil {
				presetThr = *st.Threshold
			}
			if cfgThr != presetThr {
				return false
			}
		}
	}
	return true
}
