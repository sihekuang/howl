# Changelog

All notable changes to Howl are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the
project uses platform-scoped semantic versioning (`mac-vX.Y.Z`,
`linux-vX.Y.Z`, `win-vX.Y.Z`) — see the **Releases** section of the
[README](README.md) for the rationale.

## [Unreleased]

### Changed
- Project renamed from "Voice Keyboard" to **Howl**. README, project
  brief, and `core/README.md` rebranded with SEO-optimized intro
  positioning vs Wispr Flow / Superwhisper / Voibe.
- **Mac app rename** — display name, Xcode target, SwiftPM package,
  and bundle ID:
  - `mac/VoiceKeyboard/` → `mac/Howl/`
  - `mac/VoiceKeyboard.xcodeproj` → `mac/Howl.xcodeproj`
  - `mac/Packages/VoiceKeyboardCore` → `mac/Packages/HowlCore`
  - Bundle ID `com.voicekeyboard.app` → `com.howl.app`
  - SwiftUI app struct `VoiceKeyboardApp` → `HowlApp`
  - All `import VoiceKeyboardCore` → `import HowlCore`
  - User-facing strings in menu bar + onboarding panels updated
  - CI workflow artifact `VoiceKeyboard.app.zip` → `Howl.app.zip`

  **User impact (existing dev installs):** the bundle-ID change means
  macOS treats the app as a fresh install. Accessibility and
  microphone TCC permissions must be re-granted once on first launch
  after pulling this change.

- **Go core rename** — binaries, directories, and link wiring:
  - `core/cmd/libvkb/` → `core/cmd/libhowl/`
  - `core/cmd/vkb-cli/` → `core/cmd/howl/`
  - Build outputs: `libvkb.dylib` → `libhowl.dylib`, `libvkb.h` → `libhowl.h`, CLI binary `vkb-cli` → `howl`
  - Linker flag `-lvkb` → `-lhowl`
  - CVKB shim header `libvkb_shim.h` → `libhowl_shim.h`; header guard `LIBVKB_SHIM` → `LIBHOWL_SHIM`
  - Mac postCompile/preBuild scripts updated to copy + dlopen `libhowl.dylib`
  - Run scripts (`run.sh`, `run-streaming.sh`, `run-whisper.sh`) updated to call `howl`

- **C ABI symbol prefix** — all 22 exported functions renamed (`vkb_init` → `howl_init`, `vkb_configure` → `howl_configure`, …). Affects Go `//export` directives, CVKB shim header declarations, CVKBStubs test stubs, and the Swift `LibhowlEngine` (renamed from `LibvkbEngine`) call sites.
- **Environment variables** — all `VKB_*` env vars renamed to `HOWL_*` (`HOWL_LLM_PROVIDER`, `HOWL_MODEL_PATH`, `HOWL_SESSIONS_DIR`, `HOWL_PRESETS_USER_DIR`, `HOWL_LANGUAGE`, `HOWL_DICT`, `HOWL_LLM_MODEL`, `HOWL_LLM_BASE_URL`, `HOWL_MODELS_DIR`, `HOWL_PROFILE_DIR`, `HOWL_DEEPFILTER_MODEL_PATH`, `HOWL_TEST_MODEL`, `HOWL_TEST_WAV`, `HOWL_E2E_FIXTURE_WAV`). Existing dev shell configs that export `VKB_*` need updating.
- **Log prefix + tmp paths** — `[vkb]` log lines now `[howl]`; `/tmp/vkb.log` → `/tmp/howl.log`; `/tmp/vkb-test.wav` etc. → `/tmp/howl-*`.

### Pending (data migration — separate release)
- Keychain service name (`VoiceKeyboard` → `Howl`), UserDefaults key prefix (`VoiceKeyboard.UserSettings.v1` → `Howl.UserSettings.v1`), and `~/Library/Application Support/VoiceKeyboard/` paths still use the pre-rename namespace to preserve dev install state. Rename them together with a migration path so users don't lose stored API keys + settings + downloaded Whisper models.
- The Go module path is still `github.com/voice-keyboard/core`. Renaming requires updating every internal import and the repo's go.mod — likely landed alongside the GitHub repo rename.

### Added
- `LICENSE` (MIT) — repository was missing a license file despite the
  README claiming MIT.
- `core/README.md` — public-facing docs for the Go pipeline layer
  (architecture diagram, package map, build, extension guide).
- `CONTRIBUTING.md`, `SECURITY.md`, `CHANGELOG.md`, GitHub issue and
  PR templates.

---

## [mac-v0.4.0] — 2026-05

### Added
- In-app mic permission button with TCC status logging.
- `scripts/debug-mic-tcc.sh` for diagnosing mic permission issues.
- A/B preset comparison via `howl compare <session-id>`.
- User preset CRUD (`howl presets save/delete`).
- Pluggable LLM providers: Anthropic, OpenAI, Ollama, LM Studio.
- Target Speaker Extraction (TSE) pipeline with speaker enrollment.
- Custom dictionary with fuzzy + phonetic matching.

### Changed
- Pipeline editor redesigned around pluggable stages.
- General settings owns "Active preset"; Playground and Pipeline tabs
  indicate-only.
- Bundled presets defer Whisper/LLM choice to user globals.
- Capture is always-on; sessions are visible without developer-mode
  toggle.

### Fixed
- macOS entitlements: restored `disable-library-validation` and added
  `audio-input`.
- Dictionary list now shows all terms (flat rows, not nested List).
- "Edited" badge clears after successful Save in the preset editor.

[Unreleased]: https://github.com/sihekuang/silver-adventure/compare/mac-v0.4.0...HEAD
[mac-v0.4.0]: https://github.com/sihekuang/silver-adventure/releases/tag/mac-v0.4.0
