package config

import (
	"encoding/json"
	"testing"
)

func TestConfig_RoundTrip(t *testing.T) {
	original := Config{
		WhisperModelPath:        "/tmp/ggml-small.bin",
		WhisperModelSize:        "small",
		Language:                "en",
		DisableNoiseSuppression: true,
		DeepFilterModelPath:     "/tmp/DeepFilterNet3.tar.gz",
		LLMProvider:             "anthropic",
		LLMModel:                "claude-sonnet-4-6",
		LLMAPIKey:               "sk-ant-test",
		CustomDict:              []string{"MCP", "WebRTC"},
	}

	data, err := json.Marshal(original)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}

	var roundtripped Config
	if err := json.Unmarshal(data, &roundtripped); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}

	if roundtripped.WhisperModelPath != original.WhisperModelPath {
		t.Errorf("WhisperModelPath mismatch: got %q want %q", roundtripped.WhisperModelPath, original.WhisperModelPath)
	}
	if roundtripped.WhisperModelSize != original.WhisperModelSize {
		t.Errorf("WhisperModelSize mismatch: got %q want %q", roundtripped.WhisperModelSize, original.WhisperModelSize)
	}
	if roundtripped.Language != original.Language {
		t.Errorf("Language mismatch: got %q want %q", roundtripped.Language, original.Language)
	}
	if roundtripped.DeepFilterModelPath != original.DeepFilterModelPath {
		t.Errorf("DeepFilterModelPath mismatch: got %q want %q", roundtripped.DeepFilterModelPath, original.DeepFilterModelPath)
	}
	if roundtripped.DisableNoiseSuppression != original.DisableNoiseSuppression {
		t.Errorf("DisableNoiseSuppression mismatch")
	}
	if len(roundtripped.CustomDict) != 2 || roundtripped.CustomDict[0] != "MCP" {
		t.Errorf("CustomDict mismatch: %+v", roundtripped.CustomDict)
	}
	if roundtripped.LLMProvider != original.LLMProvider {
		t.Errorf("LLMProvider mismatch: got %q want %q", roundtripped.LLMProvider, original.LLMProvider)
	}
	if roundtripped.LLMModel != original.LLMModel {
		t.Errorf("LLMModel mismatch: got %q want %q", roundtripped.LLMModel, original.LLMModel)
	}
	if roundtripped.LLMAPIKey != original.LLMAPIKey {
		t.Errorf("LLMAPIKey mismatch: got %q want %q", roundtripped.LLMAPIKey, original.LLMAPIKey)
	}
}

func TestConfig_DefaultsApplied(t *testing.T) {
	var empty Config
	WithDefaults(&empty)
	if empty.WhisperModelSize != "small" {
		t.Errorf("expected default WhisperModelSize=small, got %q", empty.WhisperModelSize)
	}
	if empty.Language != "auto" {
		t.Errorf("expected default Language=auto, got %q", empty.Language)
	}
	if empty.LLMProvider != "anthropic" {
		t.Errorf("expected default LLMProvider=anthropic, got %q", empty.LLMProvider)
	}
	if empty.LLMModel != "claude-sonnet-4-6" {
		t.Errorf("expected default LLMModel=claude-sonnet-4-6, got %q", empty.LLMModel)
	}
}

func TestWithDefaults_TSEFieldsLeftEmpty(t *testing.T) {
	c := Config{}
	WithDefaults(&c)
	if c.TSEEnabled {
		t.Error("TSEEnabled default should be false")
	}
	if c.TSEProfileDir != "" {
		t.Errorf("TSEProfileDir default should be empty, got %q", c.TSEProfileDir)
	}
	if c.TSEModelPath != "" {
		t.Errorf("TSEModelPath default should be empty, got %q", c.TSEModelPath)
	}
	if c.SpeakerEncoderPath != "" {
		t.Errorf("SpeakerEncoderPath default should be empty, got %q", c.SpeakerEncoderPath)
	}
	if c.ONNXLibPath != "" {
		t.Errorf("ONNXLibPath default should be empty, got %q", c.ONNXLibPath)
	}
}

func TestConfig_DeveloperMode_DefaultFalse(t *testing.T) {
	var c Config
	WithDefaults(&c)
	if c.DeveloperMode {
		t.Error("DeveloperMode default should be false")
	}
}

func TestConfig_DeveloperMode_JSONRoundTrip(t *testing.T) {
	in := Config{DeveloperMode: true}
	buf, err := json.Marshal(in)
	if err != nil {
		t.Fatalf("Marshal: %v", err)
	}
	var out Config
	if err := json.Unmarshal(buf, &out); err != nil {
		t.Fatalf("Unmarshal: %v", err)
	}
	if !out.DeveloperMode {
		t.Errorf("DeveloperMode lost in round-trip; JSON was: %s", buf)
	}
}

// Cross-language contract tests: pin down the exact JSON keys the Mac's
// EngineConfig emits, decoded by the same Unmarshal that howl_configure
// uses. If a key here drifts from the Swift side (mac/Packages/.../
// EngineConfig.swift) the test fails — closing the gap that allowed
// tse_threshold + tse_backend + pipeline_timeout_sec to be silently
// dropped on the Mac apply path.

func TestConfig_AcceptsMacEngineConfigJSON_ParanoidPreset(t *testing.T) {
	// Exact shape the Swift EngineConfig encodes after applying the
	// "paranoid" bundled preset (threshold 0.7) with a global pipeline
	// timeout of 10s. Mirrors the JSON keys produced by
	// `mac/Packages/.../Bridge/EngineConfig.swift`'s `encode(to:)`.
	jsonBlob := []byte(`{
		"whisper_model_path": "/tmp/ggml-small.bin",
		"whisper_model_size": "small",
		"language": "en",
		"disable_noise_suppression": false,
		"deep_filter_model_path": "",
		"llm_provider": "anthropic",
		"llm_model": "claude-sonnet-4-6",
		"llm_api_key": "sk-ant-test",
		"llm_base_url": "",
		"developer_mode": false,
		"custom_dict": [],
		"tse_enabled": true,
		"tse_profile_dir": "/profile",
		"tse_model_path": "/models/tse.onnx",
		"speaker_encoder_path": "/models/enc.onnx",
		"onnx_lib_path": "/lib/libort.dylib",
		"tse_threshold": 0.7,
		"tse_backend": "ecapa",
		"pipeline_timeout_sec": 10
	}`)

	var cfg Config
	if err := json.Unmarshal(jsonBlob, &cfg); err != nil {
		t.Fatalf("Unmarshal: %v", err)
	}

	if !cfg.TSEEnabled {
		t.Errorf("TSEEnabled = false; the bundled paranoid preset must enable TSE")
	}
	if cfg.TSEThreshold == nil || *cfg.TSEThreshold != 0.7 {
		t.Errorf("TSEThreshold = %v, want 0.7 — the Mac apply path used to drop this", cfg.TSEThreshold)
	}
	if cfg.TSEBackend != "ecapa" {
		t.Errorf("TSEBackend = %q, want \"ecapa\"", cfg.TSEBackend)
	}
	if cfg.PipelineTimeoutSec != 10 {
		t.Errorf("PipelineTimeoutSec = %d, want 10", cfg.PipelineTimeoutSec)
	}
	if cfg.TSEThresholdValue() != 0.7 {
		t.Errorf("TSEThresholdValue() = %v, want 0.7", cfg.TSEThresholdValue())
	}
}

func TestConfig_AcceptsMacEngineConfigJSON_OmittedThreshold(t *testing.T) {
	// When the user picks the "default" preset (threshold 0.0), Swift's
	// `encodeIfPresent(tseThreshold)` semantics — and the bridge fix —
	// emit either no key or the literal 0. Both must decode as
	// "no gating" on the Go side.
	for name, blob := range map[string][]byte{
		"omitted":   []byte(`{"whisper_model_path":"","whisper_model_size":"small","language":"en","disable_noise_suppression":false,"deep_filter_model_path":"","llm_provider":"anthropic","llm_model":"claude","llm_api_key":"","custom_dict":[],"tse_enabled":true,"tse_backend":"ecapa"}`),
		"explicit0": []byte(`{"whisper_model_path":"","whisper_model_size":"small","language":"en","disable_noise_suppression":false,"deep_filter_model_path":"","llm_provider":"anthropic","llm_model":"claude","llm_api_key":"","custom_dict":[],"tse_enabled":true,"tse_backend":"ecapa","tse_threshold":0.0}`),
	} {
		t.Run(name, func(t *testing.T) {
			var cfg Config
			if err := json.Unmarshal(blob, &cfg); err != nil {
				t.Fatalf("Unmarshal: %v", err)
			}
			if cfg.TSEThresholdValue() != 0 {
				t.Errorf("TSEThresholdValue() = %v, want 0 (no gating)", cfg.TSEThresholdValue())
			}
		})
	}
}

func TestConfig_AcceptsMacEngineConfigJSON_OmittedTimeout(t *testing.T) {
	// Mac's encode omits pipeline_timeout_sec when 0 (matches Go's
	// `omitempty`). Decoding without the key must yield 0 ("no bound").
	jsonBlob := []byte(`{
		"whisper_model_path": "",
		"whisper_model_size": "small",
		"language": "en",
		"disable_noise_suppression": false,
		"deep_filter_model_path": "",
		"llm_provider": "anthropic",
		"llm_model": "claude",
		"llm_api_key": "",
		"custom_dict": [],
		"tse_enabled": false
	}`)
	var cfg Config
	if err := json.Unmarshal(jsonBlob, &cfg); err != nil {
		t.Fatalf("Unmarshal: %v", err)
	}
	if cfg.PipelineTimeoutSec != 0 {
		t.Errorf("PipelineTimeoutSec = %d, want 0 (no bound)", cfg.PipelineTimeoutSec)
	}
	if cfg.PipelineTimeoutValue() != 0 {
		t.Errorf("PipelineTimeoutValue() = %v, want 0", cfg.PipelineTimeoutValue())
	}
}
