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

That installs `xcodegen` (via Homebrew if missing), wires the tracked
git hooks under `scripts/git-hooks/` into this clone, and runs an
initial `make project` so the Xcode project exists.

The hooks regenerate `mac/VoiceKeyboard.xcodeproj` automatically on
`git pull` / `git switch <branch>` whenever an input changes
(`project.yml`, `Local.xcconfig`, or any tracked Swift / xcassets /
Info.plist file). Without them you'd have to remember to run
`make project` after every merge that adds a file — and Xcode IDE
silently breaks until you do.

If you don't want the hooks (e.g. you only ever use `make build`
from the CLI, which already runs `make project` as a dependency),
you can opt out with `git config --unset core.hooksPath`.

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
