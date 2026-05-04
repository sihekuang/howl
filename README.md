# Voice Keyboard

Voice dictation app for macOS (Linux/Windows planned). Hold a hotkey, speak,
release — Whisper transcribes locally, Claude or a local LLM cleans up the
text, the result types into the focused field.

See `project.md` for the broader vision and competitive context.

## Repo layout

```
core/                 Go pipeline (libvkb.dylib + vkb-cli)
mac/                  Swift macOS app
mac/project.yml       Source of truth for the Xcode project
mac/VoiceKeyboard/    App sources
mac/Packages/         SwiftPM packages (Core)
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
  three are the cgo runtime deps libvkb.dylib links against — without
  them the Xcode build fails with opaque linker errors.
- Wires the tracked git hooks under `scripts/git-hooks/` into this
  clone (`git config core.hooksPath`).
- Runs an initial `make project` to materialise the Xcode project.
- Runs an initial `make build-dylib` in `core/` so libvkb.dylib
  exists before the first Mac build — surfacing toolchain problems
  up front instead of mid-`xcodebuild`.

The hooks keep `mac/VoiceKeyboard.xcodeproj` and
`core/build/libvkb.dylib` in sync on `git pull` / `git switch
<branch>`:

- xcodeproj regenerates whenever `project.yml`, an xcconfig, or any
  tracked Swift / xcassets / Info.plist file changes.
- libvkb.dylib rebuilds whenever any `core/*.go` / `go.mod` / `go.sum`
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
make test        # SwiftPM tests for VoiceKeyboardCore
```

The Go core has its own targets in `core/Makefile`. CI runs both
sides on push/PR; release builds attach a signed `.app` artifact
to a GitHub Release on tag push.

## CLI

`vkb-cli` is the headless equivalent of the Mac app — useful for CI,
scripting, and reproducing issues without launching the GUI. Same Go
primitives, no SwiftUI.

```bash
# List + inspect presets
vkb-cli presets list
vkb-cli presets show default

# Run dictation with a specific preset
vkb-cli pipe --preset minimal --live
vkb-cli pipe --preset default FILE.wav

# Inspect captured sessions
vkb-cli sessions list
vkb-cli sessions show <id>
vkb-cli sessions delete <id>

# A/B compare presets against the same captured audio
vkb-cli compare <session-id> --presets default,minimal,paranoid
```

See `core/cmd/vkb-cli/README.md` for the full subcommand reference.

## Releases

This is a monorepo, but each platform releases on its own cadence
via **platform-scoped tags**. Each tag prefix triggers its own
workflow and produces a release with only that platform's artifact:

| Tag pattern   | Triggers                  | Artifact                |
|---------------|---------------------------|-------------------------|
| `mac-v*`      | `.github/workflows/build.yml` | `VoiceKeyboard.app.zip` |
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
