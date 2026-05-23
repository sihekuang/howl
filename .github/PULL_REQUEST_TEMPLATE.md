## What

A one-paragraph summary of the change. The diff shows the *what* — this
section is for the *why*.

## How to test

- [ ] `go test ./...` under `core/` passes
- [ ] `make test` under `mac/` passes
- [ ] Manual smoke test (describe):

## Notes for the reviewer

Anything non-obvious: a workaround, a follow-up that's intentionally
out of scope, a question about an approach.

## Checklist

- [ ] Commit messages follow [Conventional Commits](https://www.conventionalcommits.org/)
- [ ] Docs updated where relevant (README, `core/README.md`, `cmd/howl-cli/README.md`, etc.)
- [ ] No new TCC entitlements requested without justification in the PR description
- [ ] If this touches the audio pipeline, the evaluation harness in `core/internal/speaker/` was run — SNR sweep results in the PR description
