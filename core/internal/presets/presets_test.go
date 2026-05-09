package presets

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestLoad_BundledFileParses(t *testing.T) {
	got, err := loadBundled()
	if err != nil {
		t.Fatalf("loadBundled: %v", err)
	}
	if len(got) < 4 {
		t.Errorf("expected at least 4 bundled presets, got %d", len(got))
	}
	wantNames := map[string]bool{"default": false, "minimal": false, "aggressive": false, "paranoid": false}
	for _, p := range got {
		if _, ok := wantNames[p.Name]; ok {
			wantNames[p.Name] = true
		}
	}
	for n, found := range wantNames {
		if !found {
			t.Errorf("bundled preset %q missing", n)
		}
	}
}

func TestLoad_RejectsUnknownVersion(t *testing.T) {
	body := `{"version": 99, "presets": []}`
	_, err := parseBundle([]byte(body))
	if err == nil {
		t.Fatal("expected version-mismatch error")
	}
	if !strings.Contains(err.Error(), "version") {
		t.Errorf("error %q should mention 'version'", err)
	}
}

func TestLoad_RejectsMalformedJSON(t *testing.T) {
	_, err := parseBundle([]byte("{not json"))
	if err == nil {
		t.Fatal("expected parse error")
	}
}

func TestPreset_DefaultPresetTSEThresholdIsZero(t *testing.T) {
	all, _ := loadBundled()
	for _, p := range all {
		if p.Name != "default" {
			continue
		}
		for _, s := range p.ChunkStages {
			if s.Name == "tse" {
				if s.Threshold == nil || *s.Threshold != 0.0 {
					t.Errorf("default preset's tse threshold = %v, want 0.0", s.Threshold)
				}
				return
			}
		}
		t.Error("default preset has no tse chunk stage")
	}
	t.Error("default preset missing")
}

func TestPreset_ParanoidPresetTSEThresholdIs07(t *testing.T) {
	all, _ := loadBundled()
	for _, p := range all {
		if p.Name == "paranoid" {
			for _, s := range p.ChunkStages {
				if s.Name == "tse" && s.Threshold != nil && *s.Threshold == 0.7 {
					return
				}
			}
			t.Error("paranoid preset's tse threshold is not 0.7")
			return
		}
	}
	t.Error("paranoid preset missing")
}

func TestPreset_DefaultPresetHasTimeoutSec10(t *testing.T) {
	all, _ := loadBundled()
	for _, p := range all {
		if p.Name != "default" {
			continue
		}
		if p.TimeoutSec == nil || *p.TimeoutSec != 10 {
			t.Errorf("default preset's timeout_sec = %v, want 10", p.TimeoutSec)
		}
		return
	}
	t.Error("default preset missing")
}

func TestPreset_TimeoutSecRoundTrips(t *testing.T) {
	timeout := 7
	in := Preset{
		Name: "custom", Description: "x",
		FrameStages: []StageSpec{},
		ChunkStages: []StageSpec{},
		Transcribe:  TranscribeSpec{ModelSize: "small"},
		LLM:         LLMSpec{Provider: "anthropic"},
		TimeoutSec:  &timeout,
	}
	buf, err := json.Marshal(in)
	if err != nil {
		t.Fatal(err)
	}
	var out Preset
	if err := json.Unmarshal(buf, &out); err != nil {
		t.Fatal(err)
	}
	if out.TimeoutSec == nil || *out.TimeoutSec != 7 {
		t.Errorf("TimeoutSec = %v, want 7", out.TimeoutSec)
	}
}

func TestPreset_JSONRoundTrip(t *testing.T) {
	thr := float32(0.5)
	in := Preset{
		Name: "test", Description: "x",
		FrameStages: []StageSpec{{Name: "denoise", Enabled: true}},
		ChunkStages: []StageSpec{{Name: "tse", Enabled: true, Backend: "ecapa", Threshold: &thr}},
		Transcribe:  TranscribeSpec{ModelSize: "small"},
		LLM:         LLMSpec{Provider: "anthropic"},
	}
	buf, err := json.Marshal(in)
	if err != nil {
		t.Fatal(err)
	}
	var out Preset
	if err := json.Unmarshal(buf, &out); err != nil {
		t.Fatal(err)
	}
	if out.Name != "test" || len(out.ChunkStages) != 1 ||
		out.ChunkStages[0].Threshold == nil || *out.ChunkStages[0].Threshold != 0.5 {
		t.Errorf("round-trip mismatch: %+v", out)
	}
}

func TestBundledPresetsHaveLLMModel(t *testing.T) {
	got, err := loadBundled()
	if err != nil {
		t.Fatalf("loadBundled: %v", err)
	}
	for _, p := range got {
		if p.LLM.Model == "" {
			t.Errorf("bundled preset %q has empty LLM.Model — bundled presets must pin a model", p.Name)
		}
	}
}
