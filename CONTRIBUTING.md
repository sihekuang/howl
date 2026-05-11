# Contributing to Howl

Thanks for your interest. Howl is a small project and contributions are
welcome — bug reports, fixes, new pipeline stages, packaging for new
platforms, docs improvements, all of it.

## Quick start

```bash
git clone <your-fork-url> howl
cd howl
./scripts/setup-dev.sh
cd mac
make build && make run
```

`scripts/setup-dev.sh` installs Homebrew deps, wires git hooks, and
bootstraps the Go dylib so the first Xcode build succeeds. See the
[README](README.md) for what each step does in detail.

## Where to put your change

| Change | Lands in |
|---|---|
| Audio pipeline (VAD, denoise, TSE, ASR, dictionary, LLM cleanup) | `core/internal/<package>/` — see [`core/README.md`](core/README.md) |
| New LLM provider | `core/internal/llm/` + register in `provider.go` |
| New TSE backend | `core/internal/speaker/` + register in the backend table |
| C ABI exposure of new Go API | `core/cmd/libhowl/exports.go` (keep the C surface narrow; pass JSON) |
| Mac SwiftUI app | `mac/Howl/` (Swift sources); `mac/Packages/HowlCore/` (reusable Core wrapping libhowl) |
| Headless CLI | `core/cmd/howl-cli/` |
| Build / CI / scripts | `core/Makefile`, `mac/Makefile`, `scripts/`, `.github/workflows/` |
| Specs and plans for new work | `docs/superpowers/specs/` and `docs/superpowers/plans/` |

## Commit messages

We use **[Conventional Commits](https://www.conventionalcommits.org/)**:

```
feat(scope): short summary in imperative mood
fix(scope): ...
refactor(scope): ...
docs(scope): ...
chore(scope): ...
```

Examples from the log:

```
feat(presets): delete user presets + disable TSE in default
fix(mac): restore disable-library-validation + add audio-input entitlement
refactor(dictionary): promote stats + bulk actions to list header
```

Scope is optional but encouraged — it tells reviewers and changelog
readers which layer is affected (`mac`, `core`, `presets`, `dictionary`,
`editor`, `playground`, `general`, `scripts`, etc.).

## Pull requests

1. Open a draft PR early if the change is non-trivial. A short
   one-paragraph description of *why* beats a 12-bullet *what* — the
   diff already shows the what.
2. Keep PRs focused. One feature, one fix, one refactor per PR.
   Unrelated cleanups should go in their own PR.
3. **Tests required for behaviour changes.** Go core: `go test ./...`
   under `core/`. Swift: `make test` under `mac/` (SwiftPM tests for
   `HowlCore`). New pipeline components must plug into the
   evaluation harness in `core/internal/speaker/` — see
   [`core/CLAUDE.md`](core/CLAUDE.md) for the SNR-sweep contract.
4. **Run the full test suite locally** before pushing. CI runs both
   Go and Mac builds on every push and PR.
5. Update relevant docs in the same PR. If you add a CLI subcommand,
   update [`core/cmd/howl-cli/README.md`](core/cmd/howl-cli/README.md).
   If you add an environment variable, update the env table in the
   same file.
6. Get one approving review before merging. The maintainer
   (`@sihekuang`) reviews everything currently.

## Releases

Platform-scoped tags trigger platform-scoped releases (see the
**Releases** section of the README). Cutting a mac release:

```bash
git tag mac-v0.X.Y
git push origin mac-v0.X.Y
```

Bump `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` in
`mac/Configs/SharedSettings.xcconfig` before tagging — the Xcode
project picks them up automatically.

## Code style

- **Go**: `gofmt -s`, `go vet`. Run `go test ./...` before pushing.
  Prefer small, single-purpose packages over one growing `internal/`
  catchall.
- **Swift**: SwiftUI for new UI; Swift 6 strict concurrency on. The
  project is set up to fail the build on concurrency warnings — fix
  them, don't suppress them.
- **Comments**: explain *why*, not *what*. The code already says what.
  Save commentary for non-obvious constraints, invariants, or
  workarounds for specific bugs.

## Reporting bugs / requesting features

Use the issue templates. Include:

- macOS version + chip (Apple Silicon required currently)
- Howl version (Mac menu bar → About, or `howl-cli` build line)
- A reproducer or, for transcription quality issues, a captured
  session — `howl-cli sessions list` and attach the manifest
  (audio stays local, you choose what to share).

For security issues, **do not open a public issue**. See
[SECURITY.md](SECURITY.md).
