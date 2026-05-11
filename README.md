<p align="center">
  <img src="assets/icons/howling-husky.png" alt="Howl" width="180" />
</p>

<h1 align="center">Howl</h1>

<p align="center"><strong>Open-source voice dictation. Hold a hotkey, speak, release — your words type themselves.</strong></p>

Whisper transcribes your speech locally on your machine. Then your LLM of choice —
**Claude, GPT, Ollama, or LM Studio** — cleans up the fillers, fixes grammar, and
respects your custom dictionary. Bring your own keys, run fully offline, or mix
and match. No subscription. No vendor lock-in.

A free, self-hostable alternative to **[Wispr Flow](https://wisprflow.ai/)**,
**[Superwhisper](https://superwhisper.com/)**, and **[Voibe](https://www.getvoibe.com/)**.

> macOS today. Linux and Windows share the same Go core and are on the roadmap.

---

## Why Howl

|                          | Howl       | Wispr Flow | Superwhisper   | Voibe         |
|--------------------------|------------|------------|----------------|---------------|
| Price                    | **Free**   | $15/mo     | $250 lifetime  | $99 lifetime  |
| Runs offline             | ✅         | ❌         | ✅             | ✅            |
| Filler-word removal      | ✅         | ✅         | ❌             | ❌            |
| Bring-your-own LLM       | ✅         | ❌         | ❌             | ❌            |
| Open source              | ✅         | ❌         | ❌             | ❌            |
| Custom dictionary        | ✅         | partial    | ❌             | ❌            |

### Features

- 🎙️ **Local Whisper transcription** — your audio never leaves your machine
  unless *you* point Howl at a cloud LLM for cleanup.
- 🧠 **Bring your own LLM** — Anthropic (Claude), OpenAI (GPT), Ollama, or
  LM Studio. Use a $0 local model, or a state-of-the-art API. Your call,
  per-preset.
- 🧼 **Filler-word removal + grammar cleanup** — turn "um, so, like, basically
  what I mean is…" into the sentence you actually meant.
- 📖 **Custom dictionary** — fuzzy + phonetic matching to preserve niche
  jargon (acronyms, brand names, code identifiers) the base model gets wrong.
- ⌨️ **Hold-to-talk hotkey** — press, speak, release. Text injects at the
  cursor in any app via the macOS Accessibility API.
- 🎚️ **Target Speaker Extraction** — optional speaker enrollment isolates
  *your* voice from background voices (meeting chatter, TV, partner on a call).
- 🔌 **Pluggable pipeline** — VAD, noise suppression, transcription, dictionary,
  LLM cleanup are all swappable stages with a CLI for A/B comparison across
  presets.
- 🆓 **No subscription, no telemetry, no account.**

---

## Repo layout

```
core/                 Go pipeline (libhowl.dylib + howl)
mac/                  Swift macOS app
mac/project.yml       Source of truth for the Xcode project
mac/Howl/             App sources
mac/Packages/HowlCore SwiftPM library: bridge to libhowl + settings + audio capture
assets/icons/         Cross-platform icon masters + build pipeline
scripts/              Dev tooling (setup, hooks, model export, ...)
docs/superpowers/     specs/ and plans/ for previous feature work
```


## First-time setup

```bash
# Clone, then:
./scripts/setup-dev.sh
```

That:

- Installs Homebrew deps required for the Mac dev workflow:
  `xcodegen`, `go`, `whisper-cpp`, `ggml`, `onnxruntime`. The last
  three are the cgo runtime deps libhowl.dylib links against — without
  them the Xcode build fails with opaque linker errors.
- Wires the tracked git hooks under `scripts/git-hooks/` into this
  clone (`git config core.hooksPath`).
- Runs an initial `make project` to materialise the Xcode project.
- Runs an initial `make build-dylib` in `core/` so libhowl.dylib
  exists before the first Mac build — surfacing toolchain problems
  up front instead of mid-`xcodebuild`.

The hooks keep `mac/Howl.xcodeproj` and
`core/build/libhowl.dylib` in sync on `git pull` / `git switch
<branch>`:

- xcodeproj regenerates whenever `project.yml`, an xcconfig, or any
  tracked Swift / xcassets / Info.plist file changes.
- libhowl.dylib rebuilds whenever any `core/*.go` / `go.mod` / `go.sum`
  changes. Build is ~5 s warm, ~30 s cold; failures print a hint to
  run `cd core && make build-dylib` for the full error.

If you don't want the hooks (e.g. you only ever use `make build`
from the CLI, which already runs `make project` as a dependency
and which Xcode's preBuild phase already rebuilds the dylib for),
opt out with `git config --unset core.hooksPath`.

## Building

```bash
cd mac
make build       # regenerates the project + xcodebuild Debug
make run         # build + open the .app
make test        # SwiftPM tests for HowlCore
```

The Go core has its own targets in `core/Makefile`. CI runs both
sides on push/PR; release builds attach a signed `.app` artifact
to a GitHub Release on tag push.

## CLI

`howl` is the headless equivalent of the Mac app — useful for CI,
scripting, and reproducing issues without launching the GUI. Same Go
primitives, no SwiftUI.

```bash
# List + inspect presets
howl presets list
howl presets show default

# Run dictation with a specific preset
howl pipe --preset minimal --live
howl pipe --preset default FILE.wav

# Inspect captured sessions
howl sessions list
howl sessions show <id>
howl sessions delete <id>

# A/B compare presets against the same captured audio
howl compare <session-id> --presets default,minimal,paranoid
```

See `core/cmd/howl/README.md` for the full subcommand reference.

## Releases

This is a monorepo, but each platform releases on its own cadence
via **platform-scoped tags**. Each tag prefix triggers its own
workflow and produces a release with only that platform's artifact:

| Tag pattern   | Triggers                  | Artifact                |
|---------------|---------------------------|-------------------------|
| `mac-v*`      | `.github/workflows/build.yml` | `Howl.app.zip`          |
| `win-v*`      | (planned)                 | `.exe` / `.msi`         |
| `linux-v*`    | (planned)                 | `.AppImage` / `.deb`    |

A Windows-only fix tags `win-v0.4.1` and bumps only the Windows
version — mac stays at `mac-v0.3.0` untouched. Tradeoff: users
running multiple platforms can't say "I'm on v0.3 everywhere," but
each wrapper gets independent cadence, which matters more once the
platforms diverge in their feature timelines. This pattern follows
what monorepo projects like Bitwarden and Lokinet do.

Cutting a mac release:

```bash
git tag mac-v0.1.0
git push origin mac-v0.1.0
# Watch the Build .app workflow → release appears under Releases tab
```

Manual builds (no tag, no release) are available via **Actions →
Build .app → Run workflow** for ad-hoc verification.

---

## FAQ

**Is Howl really free?**
Yes. MIT licensed, no paid tier, no telemetry. The only thing you pay
for is your own LLM API usage if you choose a cloud provider — and
that's optional. Run it 100% offline with Ollama or LM Studio for $0.

**How is Howl different from Wispr Flow?**
Wispr Flow is a $15/month cloud service. Your audio leaves your machine
to be transcribed and cleaned up on their servers. Howl runs Whisper
locally and lets you decide whether the cleanup pass goes to a local LLM
(zero data leaves your machine) or a cloud LLM you control (you bring
the key).

**How is Howl different from Superwhisper / Voibe?**
Both are paid, closed-source, and don't remove filler words. Howl is
free, open source, removes fillers, and supports a custom dictionary
for niche vocabulary.

**Why "Howl"?**
Short, memorable, voice-native. Huskies howl. So does this thing —
just into your keyboard.

**Which platforms are supported?**
macOS 14+ today (Apple Silicon). The Go core is platform-agnostic;
Linux and Windows wrappers are on the roadmap.

**Which Whisper model should I use?**
`small` for the speed/accuracy sweet spot, `medium` if you have the
GPU/RAM headroom, `tiny` for older Macs.

---

## Keywords

Open source voice dictation · Wispr Flow alternative · Superwhisper
alternative · Voibe alternative · offline speech-to-text · local Whisper
macOS · privacy-first dictation · BYOK voice keyboard · hold-to-talk
dictation · AI transcription · Claude voice input · Ollama voice
dictation · LM Studio dictation · macOS voice typing.
