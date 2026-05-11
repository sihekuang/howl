//go:build whispercpp

// Package replay drives a captured session's raw audio through one or
// more presets via audio.FakeCapture. Used by the Mac Compare view and
// (future) the howl compare subcommand to do A/B evaluation on
// identical input.
package replay

import (
	"context"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"time"

	"github.com/voice-keyboard/core/internal/audio"
	"github.com/voice-keyboard/core/internal/config"
	"github.com/voice-keyboard/core/internal/denoise"
	pipelinebuild "github.com/voice-keyboard/core/internal/pipeline/build"
	"github.com/voice-keyboard/core/internal/presets"
	"github.com/voice-keyboard/core/internal/recorder"
	"github.com/voice-keyboard/core/internal/transcribe"
)

// inputSampleRate matches the engine's expected mic input rate.
const inputSampleRate = 48000

// frameSizeFor48k = 10 ms @ 48 kHz, matching what the live engine pushes.
const frameSizeFor48k = 480

// Options drives a single Compare run.
type Options struct {
	// SourceWAVPath is the input WAV (typically <session>/denoise.wav,
	// raw 48 kHz mic audio before any pipeline processing).
	SourceWAVPath string
	// SourceID is the originating session id (used to namespace replay
	// outputs as <DestRoot>/<SourceID>/replay-<preset>/).
	SourceID string
	// DestRoot is the sessions base dir (typically /tmp/voicekeyboard/sessions).
	DestRoot string
	// PresetNames selects which presets to replay. Each must be present
	// in presets.Load(). Empty list returns an error.
	PresetNames []string
	// Secrets fills in API keys + model paths that don't live in presets.
	Secrets presets.EngineSecrets
}

// Result is one preset's replay outcome.
type Result struct {
	PresetName       string `json:"preset"`
	Cleaned          string `json:"cleaned"`
	Raw              string `json:"raw"`
	Dict             string `json:"dict"`
	TotalMS          int64  `json:"total_ms"`
	ReplaySessionDir string `json:"replay_dir,omitempty"`
	Error            string `json:"error,omitempty"`
}

// noOpDeepFilter — replay always uses passthrough. Real DeepFilterNet
// requires the deepfilter build tag and a model path; rather than
// pulling that into replay (and tag-leaking the package), we accept
// that replays of denoise-enabled presets use the passthrough denoise.
// The captured source WAV is already denoise.wav (post-DeepFilter) so
// re-denoising during replay is double-processing anyway.
func noOpDeepFilter(string) denoise.Denoiser { return denoise.NewPassthrough() }

// Run replays SourceWAVPath through each named preset and returns one
// Result per preset (in input order). A failed preset surfaces as
// Result.Error rather than aborting the whole run.
func Run(ctx context.Context, opts Options) ([]Result, error) {
	if len(opts.PresetNames) == 0 {
		return nil, fmt.Errorf("replay: preset list is empty")
	}
	all, err := presets.Load()
	if err != nil {
		return nil, fmt.Errorf("replay: load presets: %w", err)
	}
	byName := map[string]presets.Preset{}
	for _, p := range all {
		byName[p.Name] = p
	}

	samples, sr, err := audio.ReadWAVMono(opts.SourceWAVPath)
	if err != nil {
		return nil, fmt.Errorf("replay: read source: %w", err)
	}
	if sr != inputSampleRate {
		return nil, fmt.Errorf("replay: source must be %d Hz, got %d Hz", inputSampleRate, sr)
	}

	// Cache transcribers across presets that share the same Whisper
	// config (model path + language). Avoids 3× model-load latency
	// for typical 3-preset comparisons.
	type whisperKey struct{ path, lang string }
	cache := map[whisperKey]transcribe.Transcriber{}
	defer func() {
		for _, t := range cache {
			_ = t.Close()
		}
	}()

	out := make([]Result, 0, len(opts.PresetNames))
	for _, name := range opts.PresetNames {
		p, ok := byName[name]
		if !ok {
			out = append(out, Result{PresetName: name, Error: "preset not found"})
			continue
		}
		cfg := presets.Resolve(p, opts.Secrets)
		key := whisperKey{path: cfg.WhisperModelPath, lang: cfg.Language}
		shared := cache[key]
		if shared == nil {
			t, err := transcribe.NewWhisperCpp(transcribe.WhisperOptions{
				ModelPath: cfg.WhisperModelPath,
				Language:  cfg.Language,
			})
			if err != nil {
				out = append(out, Result{PresetName: name, Error: "whisper load: " + err.Error()})
				continue
			}
			cache[key] = t
			shared = t
		}

		t0 := time.Now()
		res, err := runOne(ctx, p, cfg, shared, samples, opts)
		res.PresetName = name
		res.TotalMS = time.Since(t0).Milliseconds()
		if err != nil {
			res.Error = err.Error()
		}
		out = append(out, res)
	}
	return out, nil
}

func runOne(ctx context.Context, p presets.Preset, cfg config.Config, tr transcribe.Transcriber, samples []float32, opts Options) (Result, error) {
	pipe, err := pipelinebuild.FromOptions(pipelinebuild.Options{
		Config:            cfg,
		NewDeepFilter:     noOpDeepFilter,
		SharedTranscriber: tr,
	})
	if err != nil {
		return Result{}, fmt.Errorf("build pipeline: %w", err)
	}
	defer pipe.Close()

	// Replay output goes under <DestRoot>/<SourceID>/replay-<preset>/.
	// Sub-folder layout keeps replays out of the top-level Inspector list.
	destDir := filepath.Join(opts.DestRoot, opts.SourceID, "replay-"+p.Name)
	if err := os.MkdirAll(destDir, 0o755); err != nil {
		return Result{}, fmt.Errorf("mkdir dest: %w", err)
	}
	rec, err := recorder.Open(recorder.Options{Dir: destDir, AudioStages: true, Transcripts: true})
	if err != nil {
		return Result{}, fmt.Errorf("open recorder: %w", err)
	}
	pipe.Recorder = rec
	defer rec.Close()

	// Drive the pipeline via FakeCapture.
	fake := audio.NewFakeCapture(samples, frameSizeFor48k)
	frames, err := fake.Start(ctx, inputSampleRate)
	if err != nil {
		return Result{}, fmt.Errorf("fake capture start: %w", err)
	}
	defer fake.Stop()

	res, err := pipe.Run(ctx, frames)
	if err != nil {
		return Result{ReplaySessionDir: destDir}, err
	}

	// Write session.json so the Mac Compare view can load this replay
	// via SessionDetail. Use a path-style id ("<sourceID>/replay-<preset>")
	// so SessionPaths.dir(for: id) on the Swift side resolves to the
	// same destDir.
	manifestID := filepath.Join(opts.SourceID, "replay-"+p.Name)
	if err := pipe.WriteSessionManifest(destDir, manifestID, p.Name); err != nil {
		log.Printf("[replay] WriteSessionManifest failed (continuing): %v", err)
	}

	// pipeline.Result doesn't separately expose the dict-corrected
	// intermediate; we approximate Dict with Cleaned. The recorder
	// wrote dict.txt to disk so callers that need the intermediate
	// can read it from ReplaySessionDir/transcripts/dict.txt.
	// A pipeline.Result extension is queued as Slice 4.5.
	return Result{
		Cleaned:          res.Cleaned,
		Raw:              res.Raw,
		Dict:             res.Cleaned,
		ReplaySessionDir: destDir,
	}, nil
}
