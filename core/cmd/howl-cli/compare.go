//go:build whispercpp

package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/voice-keyboard/core/internal/presets"
	"github.com/voice-keyboard/core/internal/replay"
	"github.com/voice-keyboard/core/internal/sessions"
)

// runCompare drives a Compare run: replay a captured session's raw audio
// through one or more named presets and surface the per-preset transcripts.
//
//   howl-cli compare <session-id> --presets a,b,c [--json]
//
// rc convention matches the other subcommands (0 ok, 1 runtime/IO, 2 usage).
func runCompare(args []string) int {
	fs := flag.NewFlagSet("compare", flag.ContinueOnError)
	presetsFlag := fs.String("presets", "", "comma-separated preset names to replay against")
	asJSON := fs.Bool("json", false, "emit JSON array of replay results")
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if fs.NArg() != 1 {
		fmt.Fprintln(os.Stderr, "usage: howl-cli compare <session-id> --presets a,b,c [--json]")
		return 2
	}
	id := fs.Arg(0)
	names := splitPresetCSV(*presetsFlag)
	if len(names) == 0 {
		fmt.Fprintln(os.Stderr, "compare: --presets is required (comma-separated)")
		return 2
	}

	base := defaultSessionsBase()
	store := sessions.NewStore(base)
	if _, err := store.Get(id); err != nil {
		fmt.Fprintf(os.Stderr, "session %q: %v\n", id, err)
		return 1
	}

	// Compare consumes the raw 48 kHz mic audio (denoise.wav) — that's
	// the only fair "same input through different pipelines" point.
	wavPath := filepath.Join(store.SessionDir(id), "denoise.wav")
	if _, err := os.Stat(wavPath); err != nil {
		fmt.Fprintf(os.Stderr, "session %q has no denoise.wav (compare needs raw 48 kHz audio): %v\n", id, err)
		return 1
	}

	results, err := replay.Run(context.Background(), replay.Options{
		SourceWAVPath: wavPath,
		SourceID:      id,
		DestRoot:      base,
		PresetNames:   names,
		Secrets:       cliSecrets(),
	})
	if err != nil {
		fmt.Fprintf(os.Stderr, "compare: %v\n", err)
		return 1
	}

	if *asJSON {
		buf, err := json.MarshalIndent(results, "", "  ")
		if err != nil {
			fmt.Fprintf(os.Stderr, "marshal: %v\n", err)
			return 1
		}
		fmt.Println(string(buf))
		return 0
	}
	for _, r := range results {
		fmt.Printf("=== %s ===\n", r.PresetName)
		if r.Error != "" {
			fmt.Printf("ERROR:    %s\n", r.Error)
		}
		fmt.Printf("Total:    %dms\n", r.TotalMS)
		if r.ReplaySessionDir != "" {
			fmt.Printf("Replay:   %s\n", r.ReplaySessionDir)
		}
		if r.Cleaned != "" {
			fmt.Printf("Cleaned:  %s\n", r.Cleaned)
		}
		fmt.Println()
	}
	return 0
}

// splitPresetCSV mirrors the libhowl helper of the same name. Defined
// here so howl compiles without depending on libhowl's package main.
func splitPresetCSV(s string) []string {
	if s == "" {
		return nil
	}
	out := make([]string, 0)
	for _, p := range strings.Split(s, ",") {
		if p = strings.TrimSpace(p); p != "" {
			out = append(out, p)
		}
	}
	return out
}

// cliSecrets pulls API keys + model paths from the same env vars the
// rest of howl uses. Mirrors the Mac engine's secretsFromEngineCfg
// so a Compare run from CLI lands the same audio pipeline through
// the same LLM as the Mac UI would.
func cliSecrets() presets.EngineSecrets {
	modelPath := os.Getenv("HOWL_MODEL_PATH")
	if modelPath == "" {
		modelPath = os.ExpandEnv("$HOME/Library/Application Support/VoiceKeyboard/models/ggml-tiny.en.bin")
	}
	lang := os.Getenv("HOWL_LANGUAGE")
	if lang == "" {
		lang = "en"
	}
	modelsDir := os.Getenv("HOWL_MODELS_DIR")
	if modelsDir == "" {
		modelsDir = os.ExpandEnv("$HOME/Library/Application Support/VoiceKeyboard/models")
	}
	profileDir := os.Getenv("HOWL_PROFILE_DIR")
	if profileDir == "" {
		profileDir = os.ExpandEnv("$HOME/.config/voice-keyboard")
	}
	onnxLib := os.Getenv("ONNXRUNTIME_LIB_PATH")
	if onnxLib == "" {
		onnxLib = "/opt/homebrew/lib/libonnxruntime.dylib"
	}
	return presets.EngineSecrets{
		LLMAPIKey:           os.Getenv("ANTHROPIC_API_KEY"),
		WhisperModelPath:    modelPath,
		Language:            lang,
		DeepFilterModelPath: os.Getenv("HOWL_DEEPFILTER_MODEL_PATH"),
		TSEProfileDir:       profileDir,
		TSEModelPath:        modelsDir,
		ONNXLibPath:         onnxLib,
		LLMProvider:         os.Getenv("HOWL_LLM_PROVIDER"),
		LLMBaseURL:          os.Getenv("HOWL_LLM_BASE_URL"),
		LLMModel:            os.Getenv("HOWL_LLM_MODEL"),
	}
}
