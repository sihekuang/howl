# Security Policy

## Reporting a vulnerability

Please **do not** open a public GitHub issue for security vulnerabilities.

Email **sihekuang@gmail.com** with:

- A description of the issue and its impact.
- Steps to reproduce, or proof-of-concept code.
- The affected Howl version (Mac menu bar → About) and macOS version.
- Whether you'd like to be credited in the fix's release notes.

You should expect:

- An acknowledgement within **3 business days**.
- A triage assessment within **7 business days**.
- A coordinated disclosure timeline once impact is understood —
  typically 30-90 days, sooner if a fix is straightforward.

## Scope

In scope:

- The Howl macOS app (the published `.app` bundle and its sources
  under `mac/`).
- The Go core library (`core/`) and `howl`.
- The C ABI between them.
- Build / CI configuration committed to the repo.

Out of scope:

- Vulnerabilities in third-party dependencies (`whisper.cpp`,
  `onnxruntime`, `deepfilternet`, the Anthropic / OpenAI SDKs, Ollama,
  LM Studio) — please report those to their respective maintainers.
- Issues that require physical access to an unlocked machine.
- Theoretical attacks that don't have a concrete impact path.

## Threat model

Howl is a local-first tool. Audio is captured on-device, transcribed
locally by Whisper, and optionally sent to a user-configured LLM
provider for cleanup. Things we treat as in-scope security concerns:

- **Audio leakage** — any path by which captured audio could be
  written, transmitted, or persisted outside the user's intended
  destinations (sessions directory, configured LLM).
- **API key leakage** — any path by which a user's `ANTHROPIC_API_KEY`,
  `OPENAI_API_KEY`, or other secrets could be logged, transmitted,
  or persisted unexpectedly.
- **Text-injection escape** — Howl uses the macOS Accessibility API
  to inject transcribed text into focused fields. Any path by which
  a malicious transcript could trigger commands rather than text
  input is a concern.
- **TCC / entitlement scope creep** — Howl requests Accessibility +
  mic permissions. New requests for additional capabilities require
  explicit justification.
- **Supply chain** — tampered binaries, signed-build verification,
  Homebrew dep substitution.

## Disclosure

Once a fix is available, we publish:

- A patched release on the affected platform tag.
- A `SECURITY.md`-noted entry in `CHANGELOG.md` describing the issue
  at a level appropriate to its severity.
- Credit to the reporter, if they want it.
