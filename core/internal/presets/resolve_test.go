package presets

import (
	"testing"

	"github.com/voice-keyboard/core/internal/config"
)

func TestResolve_DefaultPresetMatchesEngineConfig(t *testing.T) {
	all, _ := loadBundled()
	def := findPreset(t, all, "default")

	got := Resolve(def, EngineSecrets{LLMAPIKey: "test-key"})

	// Critical fields the default preset specifies:
	if got.WhisperModelSize != "small" {
		t.Errorf("WhisperModelSize = %q, want small", got.WhisperModelSize)
	}
	if got.LLMProvider != "anthropic" {
		t.Errorf("LLMProvider = %q, want anthropic", got.LLMProvider)
	}
	if got.LLMAPIKey != "test-key" {
		t.Errorf("LLMAPIKey = %q, want test-key", got.LLMAPIKey)
	}
	if got.DisableNoiseSuppression {
		t.Errorf("default should have noise suppression on")
	}
	if !got.TSEEnabled {
		t.Errorf("default should have TSE on")
	}
}

func TestResolve_MinimalDisablesDenoiseAndTSE(t *testing.T) {
	all, _ := loadBundled()
	min := findPreset(t, all, "minimal")
	got := Resolve(min, EngineSecrets{})

	if !got.DisableNoiseSuppression {
		t.Errorf("minimal: DisableNoiseSuppression should be true")
	}
	if got.TSEEnabled {
		t.Errorf("minimal: TSEEnabled should be false")
	}
}

func TestResolve_ParanoidPropagatesThresholdInTSEBackend(t *testing.T) {
	all, _ := loadBundled()
	p := findPreset(t, all, "paranoid")
	got := Resolve(p, EngineSecrets{})

	if got.TSEThreshold == nil || *got.TSEThreshold != 0.7 {
		t.Errorf("TSEThreshold = %v, want 0.7", got.TSEThreshold)
	}
}

func TestResolve_BackendSelected(t *testing.T) {
	all, _ := loadBundled()
	def := findPreset(t, all, "default")
	got := Resolve(def, EngineSecrets{})
	if got.TSEBackend != "ecapa" {
		t.Errorf("TSEBackend = %q, want ecapa", got.TSEBackend)
	}
}

func findPreset(t *testing.T, all []Preset, name string) Preset {
	t.Helper()
	for _, p := range all {
		if p.Name == name {
			return p
		}
	}
	t.Fatalf("preset %q not found in bundled set", name)
	return Preset{}
}

// Compile-time check: Resolve produces a config.Config.
var _ = config.Config{}

func TestResolve_DefaultTimeoutPropagates(t *testing.T) {
	all, _ := loadBundled()
	def := findPreset(t, all, "default")
	got := Resolve(def, EngineSecrets{})
	if got.PipelineTimeoutSec != 10 {
		t.Errorf("PipelineTimeoutSec = %d, want 10", got.PipelineTimeoutSec)
	}
}

func TestMatch_DivergedTimeoutReturnsCustom(t *testing.T) {
	all, _ := loadBundled()
	def := findPreset(t, all, "default")
	cfg := Resolve(def, EngineSecrets{})
	cfg.PipelineTimeoutSec = 99 // diverge

	if got := Match(cfg, all); got != "custom" {
		t.Errorf("Match(divergent timeout) = %q, want \"custom\"", got)
	}
}

func TestMatch_AllBundledPresetsAreSelfMatching(t *testing.T) {
	all, _ := loadBundled()
	for _, p := range all {
		cfg := Resolve(p, EngineSecrets{})
		got := Match(cfg, all)
		if got != p.Name {
			t.Errorf("Match(Resolve(%q)) = %q, want %q", p.Name, got, p.Name)
		}
	}
}

func TestMatch_DivergedConfigReturnsCustom(t *testing.T) {
	all, _ := loadBundled()
	def := findPreset(t, all, "default")
	cfg := Resolve(def, EngineSecrets{})
	cfg.DisableNoiseSuppression = !cfg.DisableNoiseSuppression // diverge

	if got := Match(cfg, all); got != "custom" {
		t.Errorf("Match(divergent) = %q, want \"custom\"", got)
	}
}

func TestMatch_EmptyPresetListReturnsCustom(t *testing.T) {
	if got := Match(config.Config{}, nil); got != "custom" {
		t.Errorf("Match(empty list) = %q, want \"custom\"", got)
	}
}

func TestResolveStampsLLMModelFromPreset(t *testing.T) {
	p := Preset{
		Name:        "test",
		Transcribe:  TranscribeSpec{ModelSize: "small"},
		LLM:         LLMSpec{Provider: "anthropic", Model: "claude-haiku-4-5"},
	}
	cfg := Resolve(p, EngineSecrets{LLMModel: "ignored-from-secrets"})
	if cfg.LLMModel != "claude-haiku-4-5" {
		t.Errorf("LLMModel = %q, want %q", cfg.LLMModel, "claude-haiku-4-5")
	}
}

func TestResolveLeavesLLMModelWhenPresetEmpty(t *testing.T) {
	p := Preset{
		Name:       "test",
		Transcribe: TranscribeSpec{ModelSize: "small"},
		LLM:        LLMSpec{Provider: "anthropic"}, // no Model
	}
	cfg := Resolve(p, EngineSecrets{LLMModel: "from-secrets"})
	if cfg.LLMModel != "from-secrets" {
		t.Errorf("LLMModel = %q, want %q (preset-empty should preserve secrets)", cfg.LLMModel, "from-secrets")
	}
}
