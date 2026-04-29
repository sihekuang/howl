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
