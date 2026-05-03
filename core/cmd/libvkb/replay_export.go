//go:build whispercpp

package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"context"
	"encoding/json"
	"strings"

	"github.com/voice-keyboard/core/internal/presets"
	"github.com/voice-keyboard/core/internal/replay"
)

// vkb_replay drives a Compare run. sourceID is the originating session
// id (folder name under /tmp/voicekeyboard/sessions/). presetsCSV is a
// comma-separated list of preset names. Returns a JSON array of replay
// Results — caller frees via vkb_free_string. NULL on engine-not-init.
//
// Per-preset failures surface as Result.Error rather than aborting the
// whole call. A top-level error (no session, bad CSV, etc.) returns a
// JSON object {"error": "..."} so the Swift side can render it as a
// banner above the result cards.
//
//export vkb_replay
func vkb_replay(sourceIDC, presetsCSVC *C.char) *C.char {
	e := getEngine()
	if e == nil {
		return nil
	}
	if sourceIDC == nil || presetsCSVC == nil {
		return jsonErrorC("vkb_replay: nil argument")
	}
	sourceID := C.GoString(sourceIDC)
	presetsCSV := C.GoString(presetsCSVC)

	names := splitCSV(presetsCSV)
	if len(names) == 0 {
		return jsonErrorC("vkb_replay: empty preset list")
	}

	if e.sessions == nil {
		return jsonErrorC("vkb_replay: sessions store not initialized")
	}
	sessionDir := e.sessions.SessionDir(sourceID)
	wavPath := sessionDir + "/denoise.wav"

	results, err := replay.Run(context.Background(), replay.Options{
		SourceWAVPath: wavPath,
		SourceID:      sourceID,
		DestRoot:      e.sessions.Base(),
		PresetNames:   names,
		Secrets:       secretsFromEngineCfg(e),
	})
	if err != nil {
		return jsonErrorC("vkb_replay: " + err.Error())
	}
	buf, err := json.Marshal(results)
	if err != nil {
		return jsonErrorC("vkb_replay: marshal: " + err.Error())
	}
	return C.CString(string(buf))
}

func splitCSV(s string) []string {
	if s == "" {
		return nil
	}
	parts := strings.Split(s, ",")
	cleaned := make([]string, 0, len(parts))
	for _, n := range parts {
		n = strings.TrimSpace(n)
		if n != "" {
			cleaned = append(cleaned, n)
		}
	}
	return cleaned
}

// jsonErrorC builds a JSON {"error":"..."} payload + a heap C string.
func jsonErrorC(msg string) *C.char {
	buf, _ := json.Marshal(map[string]string{"error": msg})
	return C.CString(string(buf))
}

// secretsFromEngineCfg lifts secrets out of the engine's Config so
// replay.Run can resolve presets with the user's API key + model paths.
func secretsFromEngineCfg(e *engine) presets.EngineSecrets {
	e.mu.Lock()
	defer e.mu.Unlock()
	return presets.EngineSecrets{
		LLMAPIKey:           e.cfg.LLMAPIKey,
		WhisperModelPath:    e.cfg.WhisperModelPath,
		DeepFilterModelPath: e.cfg.DeepFilterModelPath,
		TSEProfileDir:       e.cfg.TSEProfileDir,
		TSEModelPath:        e.cfg.TSEModelPath,
		SpeakerEncoderPath:  e.cfg.SpeakerEncoderPath,
		ONNXLibPath:         e.cfg.ONNXLibPath,
		CustomDict:          append([]string{}, e.cfg.CustomDict...),
		Language:            e.cfg.Language,
		// Compare keeps LLM constant across replays: audio pipeline
		// is the variable being compared. Override the preset's
		// llm.provider with the engine's current choice so the user's
		// configured Ollama/LMStudio/etc. is honored, not the preset's
		// default of anthropic.
		LLMProvider: e.cfg.LLMProvider,
		LLMBaseURL:  e.cfg.LLMBaseURL,
		LLMModel:    e.cfg.LLMModel,
	}
}
