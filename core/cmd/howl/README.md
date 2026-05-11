# `howl`

Headless equivalent of the Mac app. Wraps the same `internal/{presets,sessions,replay,pipeline,...}` Go packages the Mac app consumes via libhowl's C ABI.

## Build

```bash
cd core && make build-cli                    # default build (whispercpp tag)
cd core && go build ./cmd/howl            # without whispercpp; pipe/compare are stubbed
```

## Subcommands

### `howl check`

Verifies `ANTHROPIC_API_KEY`, `HOWL_MODEL_PATH`, and at-runtime libwhisper / libdf linkage.

### `howl capture --out FILE [--secs N]`

Records mic input to a WAV. Used as input for `transcribe` and `pipe FILE.wav`.

### `howl transcribe FILE.wav`

Runs Whisper on a WAV and prints the raw transcript.

### `howl pipe FILE.wav` / `howl pipe --live`

Runs the full pipeline (denoise → decimate → TSE? → Whisper → dict → LLM) on a WAV or live mic.

```bash
# File mode
howl pipe sample.wav

# Live mode (press Enter to stop)
howl pipe --live

# Preset overlay — flag overrides on top of the named preset
howl pipe --preset minimal --live
howl pipe --preset default --no-llm sample.wav

# Tap audio + transcripts to disk
howl pipe --record-dir /tmp/dbg --record audio,transcripts sample.wav
```

### `howl backends [--models-dir DIR]`

Lists registered TSE backends. With `--models-dir`, also checks each backend's ONNX files exist.

### `howl providers [--models]`

Lists registered LLM providers. With `--models`, lists each provider's available models (e.g. installed Ollama models).

### `howl presets {list|show|save|delete}`

Manages bundled and user pipeline presets. User presets live in `~/Library/Application Support/VoiceKeyboard/presets/<name>.json`.

```bash
# List all (bundled + user); --json for machine-readable
howl presets list
howl presets list --json

# Show one preset's details
howl presets show default
howl presets show --json minimal

# Save a user preset (clones bundled 'default' or --from <session-id>'s preset)
howl presets save --description "my custom" my-preset
howl presets save --from 2026-05-03T14:32:11Z derived-from-session

# Delete a user preset
howl presets delete my-preset
```

Names must match `^[a-z0-9_-]{1,40}$`. Bundled-name collisions are rejected.

### `howl sessions {list|show|delete|clear}`

Inspects captured per-stage sessions written by libhowl (or by `howl pipe --record-dir`). Defaults to `/tmp/voicekeyboard/sessions/`; override with `HOWL_SESSIONS_DIR`.

```bash
# Newest-first list with cleaned-text preview; --json for full manifests
howl sessions list
howl sessions list --json

# One session's manifest
howl sessions show 2026-05-03T14:32:11Z
howl sessions show --json 2026-05-03T14:32:11Z

# Delete one
howl sessions delete 2026-05-03T14:32:11Z

# Clear all (defensive: requires --force)
howl sessions clear --force
```

### `howl compare <session-id> --presets a,b,c [--json]`

A/B replay: feeds the session's `denoise.wav` (raw 48 kHz mic audio) through each named preset's transient pipeline. Replay output lands at `<sessions-dir>/<source-id>/replay-<preset>/`.

```bash
howl compare 2026-05-03T14:32:11Z --presets default,minimal,paranoid
howl compare 2026-05-03T14:32:11Z --presets default,minimal --json
```

Per-preset failures surface in `Result.Error` rather than aborting the whole call.

## Environment

| Var | Purpose |
|---|---|
| `ANTHROPIC_API_KEY` | Required for `pipe` (anthropic provider unless `--no-llm`) |
| `HOWL_MODEL_PATH` | Whisper `.bin` path; default `~/Library/Application Support/VoiceKeyboard/models/ggml-tiny.en.bin` |
| `HOWL_LANGUAGE` | Whisper language hint; default `en` |
| `HOWL_MODELS_DIR` | TSE ONNX models directory; default `~/Library/Application Support/VoiceKeyboard/models` |
| `HOWL_PROFILE_DIR` | Speaker enrollment profile; default `~/.config/voice-keyboard` |
| `HOWL_SESSIONS_DIR` | Sessions root; default `/tmp/voicekeyboard/sessions` |
| `HOWL_PRESETS_USER_DIR` | User presets root; default `~/Library/Application Support/VoiceKeyboard/presets` |
| `HOWL_LLM_PROVIDER` / `HOWL_LLM_MODEL` / `HOWL_LLM_BASE_URL` | Used by `compare` to fix the LLM across replays |
| `ONNXRUNTIME_LIB_PATH` | Default `/opt/homebrew/lib/libonnxruntime.dylib` |
