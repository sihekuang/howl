package config

import (
	"encoding/json"
	"testing"
)

func TestConfig_RoundTrip(t *testing.T) {
	original := Config{
		WhisperModelPath:    "/tmp/ggml-small.bin",
		WhisperModelSize:    "small",
		Language:            "en",
		NoiseSuppression:    true,
		DeepFilterModelPath: "/tmp/DeepFilterNet3.tar.gz",
		LLMProvider:         "anthropic",
		LLMModel:            "claude-sonnet-4-6",
		LLMAPIKey:           "sk-ant-test",
		CustomDict:          []string{"MCP", "WebRTC"},
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
	if roundtripped.DeepFilterModelPath != original.DeepFilterModelPath {
		t.Errorf("DeepFilterModelPath mismatch: got %q want %q", roundtripped.DeepFilterModelPath, original.DeepFilterModelPath)
	}
	if roundtripped.NoiseSuppression != original.NoiseSuppression {
		t.Errorf("NoiseSuppression mismatch")
	}
	if len(roundtripped.CustomDict) != 2 || roundtripped.CustomDict[0] != "MCP" {
		t.Errorf("CustomDict mismatch: %+v", roundtripped.CustomDict)
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
	if !empty.NoiseSuppression {
		t.Errorf("expected default NoiseSuppression=true")
	}
	if empty.LLMProvider != "anthropic" {
		t.Errorf("expected default LLMProvider=anthropic, got %q", empty.LLMProvider)
	}
	if empty.LLMModel != "claude-sonnet-4-6" {
		t.Errorf("expected default LLMModel=claude-sonnet-4-6, got %q", empty.LLMModel)
	}
}
