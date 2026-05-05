# Contributing to Voice Keyboard

Thanks for your interest in contributing. Below is everything you need to go from a fresh clone to a passing CI run.

## Setup

```bash
git clone https://github.com/sihekuang/silver-adventure.git
cd silver-adventure
./scripts/setup-dev.sh
```

`setup-dev.sh` installs Homebrew deps, wires git hooks, and does an initial build of the Xcode project and Go dylib.

## Running tests

```bash
# Go core
cd core && go test -tags whispercpp ./...

# Swift package
cd mac/Packages/VoiceKeyboardCore && swift test

# Mac app (full xcodebuild)
cd mac && make test
```

CI runs both sides on every push and PR against `main`.

## Branch and PR conventions

- Branch off `main` for all changes.
- Use the tag prefixes in the README when cutting releases (`mac-v*`, `win-v*`, `linux-v*`).
- Prefer small, focused PRs — one logical change per PR makes review faster.
- PRs require passing CI before merge. CI runs on macOS only (the Go core uses macOS Homebrew deps).

## Commit style

Follow the existing history: `type(scope): short description` where `type` is one of `feat`, `fix`, `refactor`, `test`, `docs`, `ci`, or `chore`.

## Adding a pipeline stage

See `core/internal/pipeline/` for existing stages. A new stage implements the `Stage` interface and registers itself in `core/internal/pipeline/build/build.go`. Add a corresponding preset entry in `core/internal/presets/`.

## Reporting issues

Use GitHub Issues. For security vulnerabilities, see `SECURITY.md` instead of opening a public issue.

## License

By contributing you agree that your contributions will be licensed under the [MIT License](LICENSE).
