// Package config holds the Config struct that travels across the C ABI
// as JSON. Defaults are applied by WithDefaults, never inside JSON tags.
package config

type Config struct {
	WhisperModelPath        string   `json:"whisper_model_path"`
	WhisperModelSize        string   `json:"whisper_model_size"`
	Language                string   `json:"language"`
	DisableNoiseSuppression bool     `json:"disable_noise_suppression"`
	// DeveloperMode gates power-user features (always-on per-stage
	// session capture, the Pipeline tab in the Mac app). Casual users
	// keep DeveloperMode == false (the default) and never see the
	// extra UI surface or the temp-folder writes.
	DeveloperMode           bool     `json:"developer_mode"`
	DeepFilterModelPath     string   `json:"deep_filter_model_path"` // path to DeepFilterNet model archive (.tar.gz)
	LLMProvider             string   `json:"llm_provider"`
	LLMModel                string   `json:"llm_model"`
	LLMAPIKey               string   `json:"llm_api_key"`
	// LLMBaseURL is an optional override for providers that talk to a
	// configurable endpoint (Ollama on a non-default host, a test
	// harness pointing at a fake server). Empty = provider's default.
	LLMBaseURL              string   `json:"llm_base_url"`
	CustomDict              []string `json:"custom_dict"`

	// TSE (Target Speaker Extraction) fields. All optional; when
	// TSEEnabled is false the pipeline runs without the TSE stage.
	//
	// Backend selection is by name (TSEBackend), and the ONNX files
	// live in TSEModelPath's parent directory. TSEModelPath and
	// SpeakerEncoderPath are kept for back-compat with existing Swift
	// callers; their basenames are ignored when TSEBackend is set.
	TSEEnabled         bool   `json:"tse_enabled"`
	TSEBackend         string `json:"tse_backend"` // e.g. "ecapa"; empty = default
	TSEProfileDir      string `json:"tse_profile_dir"`
	TSEModelPath       string `json:"tse_model_path"`
	SpeakerEncoderPath string `json:"speaker_encoder_path"`
	ONNXLibPath        string `json:"onnx_lib_path"`
	// TSEThreshold is the cosine-similarity threshold below which the
	// SpeakerGate gates its output to zeros (silences a chunk that
	// doesn't sound enough like the enrolled speaker). nil or 0.0
	// disables the gate entirely (current default behavior).
	TSEThreshold *float32 `json:"tse_threshold,omitempty"`
}

// TSEThresholdValue returns the configured TSE threshold or 0 if unset.
// 0 disables gating; the SpeakerGate treats 0 as a no-op.
func (c *Config) TSEThresholdValue() float32 {
	if c == nil || c.TSEThreshold == nil {
		return 0
	}
	return *c.TSEThreshold
}

func WithDefaults(c *Config) {
	if c.WhisperModelSize == "" {
		c.WhisperModelSize = "small"
	}
	if c.Language == "" {
		c.Language = "auto"
	}
	if c.LLMProvider == "" {
		c.LLMProvider = "anthropic"
	}
	if c.LLMModel == "" {
		c.LLMModel = "claude-sonnet-4-6"
	}
}
