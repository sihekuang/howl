//go:build whispercpp

package replay

import (
	"context"
	"strings"
	"testing"
)

func TestRun_RejectsEmptyPresetList(t *testing.T) {
	_, err := Run(context.Background(), Options{
		SourceWAVPath: "ignored.wav",
		PresetNames:   nil,
	})
	if err == nil || !strings.Contains(err.Error(), "preset") {
		t.Errorf("expected preset-list error, got %v", err)
	}
}

func TestRun_RejectsMissingSourceWAV(t *testing.T) {
	_, err := Run(context.Background(), Options{
		SourceWAVPath: "/no/such/file.wav",
		PresetNames:   []string{"default"},
	})
	if err == nil {
		t.Errorf("expected error for missing source WAV, got nil")
	}
}
