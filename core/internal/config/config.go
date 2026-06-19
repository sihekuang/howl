// Package config holds the Config struct that travels across the C ABI
// as JSON. Defaults are applied by WithDefaults, never inside JSON tags.
package config

import (
	"fmt"
	"time"

	"github.com/voice-keyboard/core/internal/llm"
)

type Config struct {
	WhisperModelPath        string   `json:"whisper_model_path"`
	WhisperModelSize        string   `json:"whisper_model_size"`
	Language                string   `json:"language"`
	// SecondaryLanguage is the optional second language for code-switch
	// dictation. "none" (the default) means single-language behavior. When
	// set, the Mac app loads the multilingual large model and the custom
	// dictionary (whisper initial prompt) primes both scripts. The engine
	// itself stays anchored on Language; this field is threaded through for
	// model selection (Swift side) and observability.
	SecondaryLanguage       string   `json:"secondary_language"`
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
	// LLMPrompt is the cleanup prompt template sent to the LLM. Two %s
	// verbs are expected: the first receives the preserved-terms list,
	// the second the raw transcription. Empty = llm.DefaultPrompt.
	LLMPrompt               string   `json:"llm_prompt,omitempty"`
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

	// PipelineTimeoutSec bounds the POST-STOP pipeline budget — Whisper
	// drain + LLM cleanup, measured from howl_stop_capture. The recording
	// phase itself runs unbounded; the user holds PTT as long as they
	// want without risk of being cut off mid-sentence. 0 disables the
	// watchdog (legacy behavior). On expiry the pipeline emits a warning
	// event ("pipeline timed out") and an empty result so the host
	// transitions back to idle. Future work: preserve dict-corrected
	// text on timeout instead of dropping the transcript.
	PipelineTimeoutSec int `json:"pipeline_timeout_sec,omitempty"`

	// PresetName is the name of the active preset (e.g. "default",
	// "meeting", a user-created name). Stamped into session manifests
	// so the Compare tab can show which preset produced each recording.
	PresetName string `json:"preset_name,omitempty"`
}

// TSEThresholdValue returns the configured TSE threshold or 0 if unset.
// 0 disables gating; the SpeakerGate treats 0 as a no-op.
func (c *Config) TSEThresholdValue() float32 {
	if c == nil || c.TSEThreshold == nil {
		return 0
	}
	return *c.TSEThreshold
}

// PipelineTimeoutValue returns cfg.PipelineTimeoutSec as a Duration,
// or 0 (no timeout) if unset.
func (c *Config) PipelineTimeoutValue() time.Duration {
	if c == nil || c.PipelineTimeoutSec <= 0 {
		return 0
	}
	return time.Duration(c.PipelineTimeoutSec) * time.Second
}

// LogSummary returns a one-line, log-safe summary of the recognition-relevant
// config — primary/secondary language and the custom dictionary — so the
// dictionary → initial-prompt and language propagation are observable in
// /tmp/howl.log on every howl_configure.
func (c *Config) LogSummary() string {
	secondary := c.SecondaryLanguage
	if secondary == "" {
		secondary = "none"
	}
	return fmt.Sprintf("primary=%s secondary=%s, %d dictionary term(s): %q",
		c.Language, secondary, len(c.CustomDict), c.CustomDict)
}

func WithDefaults(c *Config) {
	if c.WhisperModelSize == "" {
		c.WhisperModelSize = "small"
	}
	if c.Language == "" {
		c.Language = "auto"
	}
	if c.SecondaryLanguage == "" {
		c.SecondaryLanguage = "none"
	}
	if c.LLMProvider == "" {
		c.LLMProvider = "anthropic"
	}
	if c.LLMModel == "" {
		c.LLMModel = "claude-sonnet-4-6"
	}
	if c.LLMPrompt == "" {
		c.LLMPrompt = llm.DefaultPrompt
	}
}
