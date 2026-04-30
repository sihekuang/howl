// Package config holds the Config struct that travels across the C ABI
// as JSON. Defaults are applied by WithDefaults, never inside JSON tags.
package config

type Config struct {
	WhisperModelPath        string   `json:"whisper_model_path"`
	WhisperModelSize        string   `json:"whisper_model_size"`
	Language                string   `json:"language"`
	DisableNoiseSuppression bool     `json:"disable_noise_suppression"`
	DeepFilterModelPath     string   `json:"deep_filter_model_path"` // path to DeepFilterNet model archive (.tar.gz)
	LLMProvider             string   `json:"llm_provider"`
	LLMModel                string   `json:"llm_model"`
	LLMAPIKey               string   `json:"llm_api_key"`
	CustomDict              []string `json:"custom_dict"`

	// TSE (Target Speaker Extraction) fields. All optional; when
	// TSEEnabled is false the pipeline runs without the TSE stage.
	TSEEnabled         bool   `json:"tse_enabled"`
	TSEProfileDir      string `json:"tse_profile_dir"`
	TSEModelPath       string `json:"tse_model_path"`
	SpeakerEncoderPath string `json:"speaker_encoder_path"`
	ONNXLibPath        string `json:"onnx_lib_path"`
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
