# `core/` — Howl Go pipeline

The audio + ML pipeline that powers [Howl](../README.md). Captures mic input,
runs VAD / denoise / target-speaker extraction / Whisper / dictionary / LLM
cleanup, and emits cleaned text. Written in Go, exposed two ways:

- **`libhowl.dylib`** — C ABI shared library loaded by the Mac SwiftUI app
  via `dlopen`. Same dylib will back the Linux and Windows wrappers once
  those land. See `cmd/libhowl/`.
- **`howl`** — headless command-line equivalent of the Mac app. Used
  for CI, scripting, A/B preset comparison, and reproducing issues
  without launching the GUI. See [`cmd/howl/README.md`](cmd/howl/README.md).

> The Go module path is still `github.com/voice-keyboard/core` from the
> project's pre-rename history.

## Pipeline

```
Mic ─► VAD ─► Denoise ─► (TSE) ─► Whisper ─► Dictionary ─► LLM cleanup ─► Text
       │      │                   │          │             │
       │      │                   │          │             └── Anthropic / OpenAI /
       │      │                   │          │                 Ollama / LM Studio
       │      │                   │          └── fuzzy + phonetic term correction
       │      │                   └── ggml whisper.cpp via cgo (whispercpp build tag)
       │      └── DeepFilterNet2 (cgo) or RNNoise; passthrough for tests
       └── Silero VAD (ONNX)
```

Every stage is a swappable component selected by a **preset**
(`internal/presets/`). Bundled presets live in
`internal/presets/builtin.go`; users add their own via
`howl presets save` or the Mac app's editor. Captures land in a
**session** folder (`internal/sessions/`) so any run can be replayed
through a different preset for A/B comparison.

## Package map

```
cmd/
  libhowl/                C ABI exports — the .dylib the Mac app loads
  howl/               Headless CLI; mirrors the Mac app's pipeline
  enroll/                Speaker enrollment for TSE
  ollama-smoke/          Manual smoke test for Ollama provider

internal/
  audio/                 Mic capture (malgo), WAV reader/writer, level meters
  config/                Config struct shared with libhowl's C ABI
  denoise/               DeepFilterNet2 cgo + RNNoise + passthrough
  dict/                  Custom-vocabulary fuzzy + phonetic matching
  llm/                   Provider abstraction; Anthropic, OpenAI, Ollama, LM Studio
  pipeline/              One-PTT-cycle orchestration + chunker + event log
  presets/               Bundled + user pipeline preset CRUD and resolution
  recorder/              Per-stage audio recording for sessions/replay
  replay/                Drives a session's audio through a different preset
  resample/              Decimation between sample rates (48 kHz → 16 kHz, …)
  sessions/              Per-dictation session folder format + manifest
  speaker/               Target Speaker Extraction (ConvTasNet + ECAPA embedding)
  transcribe/            Whisper.cpp wrapper (cgo, whispercpp build tag)
```

## Building

```bash
# C ABI library (libhowl.dylib) — what the Mac app loads
make build-dylib

# Headless CLI (whispercpp build tag, default)
make build-cli

# CLI without whispercpp (pipe/compare/transcribe are stubbed)
go build ./cmd/howl

# Tests
make test           # short tests
go test ./...       # full suite (some need ELEVENLABS_API_KEY etc.)
```

Runtime dependencies (installed by `../scripts/setup-dev.sh`): `whisper-cpp`,
`ggml`, `onnxruntime`, `deepfilternet` — Homebrew formulas. `BUILDING_DENOISE.md`
covers DeepFilterNet build flags in detail.

## Quickstart (headless)

```bash
# Configure providers (cloud or local)
export ANTHROPIC_API_KEY=sk-ant-...           # optional, for Claude cleanup
export HOWL_LLM_PROVIDER=ollama                # or "anthropic" / "openai" / "lmstudio"
export HOWL_MODEL_PATH=~/Library/Application\ Support/VoiceKeyboard/models/ggml-tiny.en.bin

# Verify the toolchain
./build/howl check

# Live dictation from the mic
./build/howl pipe --preset default --live

# Or pipe a WAV
./build/howl pipe --preset default sample.wav
```

The CLI's full subcommand reference lives in [`cmd/howl/README.md`](cmd/howl/README.md).

## Extending the pipeline

Every stage exposes a small interface; swapping an implementation is the
"adding a backend" pattern:

- **New LLM provider** — implement `llm.Cleaner` and register via
  `llm.Register(Provider{...})` in `internal/llm/`. The factory pattern
  in `provider.go` shows the contract.
- **New denoiser** — implement `denoise.Denoiser` and wire it into the
  preset's `Denoise` selector (`internal/denoise/stage.go`).
- **New TSE backend** — implement the speaker separator interface in
  `internal/speaker/` and register in the backend table.

**Audio components specifically** — any change to denoise, TSE, ASR,
beamforming, or speaker conditioning must go through the evaluation
harness in `internal/speaker/`. SNR sweeps against the standard
fixtures are the contract for "did this change improve isolation". See
`CLAUDE.md` for the harness contract and noise-class taxonomy. Bypassing
it (ad-hoc notebooks, single-condition checks) breaks apples-to-apples
comparison.

## C ABI

`cmd/libhowl/exports.go` defines the C functions the Mac app calls
through `dlopen`. Configuration crosses the boundary as JSON
(`internal/config`); transcription results come back through a
registered callback. The Mac SwiftPM package `HowlCore`
(under `mac/Packages/`) wraps the raw C ABI in Swift.

Build tag `whispercpp` switches `cmd/libhowl` and `cmd/howl` between
"real Whisper via cgo" and "stubbed" — keeps test builds fast and lets
CI compile without Homebrew's `whisper-cpp` installed.

## Status

macOS (Apple Silicon) first-class. Linux and Windows builds reuse the
same Go core; UI wrappers (likely Fyne or Wails) are on the roadmap
but not started.
