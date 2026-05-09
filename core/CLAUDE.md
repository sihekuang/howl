# core/ — Voice Keyboard Go core

The C-ABI library (`libvkb.dylib`) consumed by the Mac app and future
Win/Linux shells. Pipeline lives in `internal/`; C ABI exports in
`cmd/libvkb`.

## Audio pipeline evaluation harness

Any audio pipeline change (TSE replacement, denoiser swap, ASR backend
swap, beamforming, target-speaker conditioning, etc.) should plug into
the existing evaluation harness rather than be judged with a one-off
notebook or ad-hoc script. Apples-to-apples comparison only works if
every candidate runs against the same fixtures, the same mix
conditions, and pass criteria recorded in a written spec.

**Where it lives:** `internal/speaker/`

- `voice_fixtures_test.go` — `voiceFixture` interface. Two
  implementations: `libriSpeechFixture` (two committed clips,
  always-on) and `elevenLabsFixture` (synth, opt-in via
  `ELEVENLABS_API_KEY`, costs credits — skips silently when absent).
- `tse_real_voice_test.go` — `evaluateTSE` pure helper. Mixes voices
  A+B at equal level, runs the separator with A's embedding, returns
  `tseResult` (the four cosine numbers needed to judge the run).
  `assertTSEResult` applies the pass criteria from
  `docs/superpowers/specs/2026-05-06-tse-real-voice-test-design.md`.
  `TestTSE_ExtractsEnrolledVoiceFromMix` drives both directions per
  fixture.
- `tse_noise_diagnostic_test.go` — SNR sweep diagnostics against the
  same fixtures. Two flavours: single-voice interferer
  (`TestTSE_NoiseRobustness_SNRSweep`) and multi-voice "TV-like"
  noise built from forward+reversed clips
  (`TestTSE_NoiseRobustness_MultiVoice`). Pure measurement, not
  pass/fail regression — surfaces *at what SNR* a component breaks.

### Mixing with noise is the point

A pipeline component evaluated only on clean target audio tells you
nothing about isolation quality. Components only differentiate
themselves under **controlled mixing with interferer / noise at
varied SNR**. Every meaningful question — "does the new TSE handle
TV noise?", "does DiCoW degrade gracefully below 0 dB?", "does
beamforming buy us 6 dB?" — is answered by sweeping SNR against a
known-bad mix and reading the curve.

Treat the SNR sweep as a first-class output of evaluation work, not
a nice-to-have. Single-condition pass/fail (one mix, one SNR) hides
the actual differentiator.

### Required noise classes

Voice-as-noise is necessary but not sufficient. Real dictation
environments are multi-modal: users dictate next to fans, in cafés,
near traffic, with music or TV in the background. A pipeline
component that handles voice-vs-voice cleanly can still mangle audio
when a HVAC fan dominates the spectrum or when music's harmonic
content fools a voice-trained model. Every new component must be
evaluated against the full taxonomy below, not just whichever class
happens to be on disk.

| Class | What it captures | Why it matters |
|---|---|---|
| **Voice interferer** | Single competing speaker | Existing — covers households / open offices |
| **Multi-voice ("TV-like")** | Two or more concurrent voices | Currently synthesised as forward+reversed clip; **real TV adds music + sfx + dynamics that the synthetic stand-in misses** — needs a dedicated fixture |
| **Fan / HVAC** | Steady broadband noise | Stresses denoiser + Whisper's silence-hallucination tendency |
| **Café / restaurant** | Babble + dishes + ambient music | The "open-mic in public" failure mode users complain about |
| **Traffic / outdoor** | Variable-amplitude broadband, transients | Mobile dictation conditions |
| **Music** | Harmonic structure, often vocals | ASR models confuse music vocals for speech and hallucinate lyrics |
| **Keyboard / typing** | Sharp transients near the mic | Common in our actual use case (dictating while at a keyboard) |

A `noiseFixture` interface symmetric to `voiceFixture` should host
each class. Each implementation supplies one or more clips at known
RMS so the SNR sweep machinery treats them identically to voice
interferers.

**Realistic test conditions are mixtures.** Real-world audio is
voice-target + voice-interferer + non-speech-noise simultaneously.
The eval matrix must include voice + non-speech combined (e.g.
target + spouse + TV; target + traffic), not just each axis alone.

### Candidate noise sources

- **MUSAN** (`openslr.org/17`) — `music`, `speech`, `noise` subsets;
  permissive license; covers fan-like / steady noise reasonably.
  Default starting point for fan, traffic, music classes.
- **DEMAND** — multi-channel environmental (`PCAFETER` café,
  `STRAFFIC` traffic, `DKITCHEN`, `OOFFICE`, etc.). Verify license
  for redistribution.
- **FSD50K** (CC BY 4.0) — broad coverage including keyboard, fans,
  appliances. Good for the long tail.
- **TV stand-in** — no clean public source. Either record our own
  short clips off broadcast TV (fair-use risk small for committed
  test fixtures, but verify) or **synthesise** a closer stand-in:
  voice + music + crowd-cheer at variable dynamics.

License every fixture before committing. Bundle small clips
(seconds, not minutes) — same approach as the existing LibriSpeech
clips. Anything large stays out-of-tree and downloads on demand.

**To evaluate a new component:**

1. Reuse `voiceFixture` for paired-speaker inputs — don't introduce
   parallel test data.
2. Reuse the existing mix machinery. Run **both** an equal-level
   baseline *and* a full SNR sweep (e.g. +12 / +6 / 0 / -6 / -12 dB)
   against single-voice and multi-voice interferers at minimum.
   Single-condition results are misleading.
3. Add an evaluator that returns whatever the new component actually
   emits. Cosine-similarity for waveform separators (mirror
   `evaluateTSE`'s shape); WER for ASR-side changes like DiCoW (needs
   ground-truth transcripts added to the fixtures).
4. Record pass criteria in a sibling spec under
   `docs/superpowers/specs/` and calibrate thresholds against the
   candidate model — not against benchmark numbers from a paper.
5. Wire the evaluator into a `_test.go` so it runs in CI. SNR sweeps
   stay diagnostic (logged, not asserted); equal-level runs are the
   regression guard.

The harness is the single source of truth for "did this change
improve isolation / recognition on real audio." Bypassing it (ad-hoc
notebooks, one-off scripts, single-condition checks) breaks
apples-to-apples comparison across candidates.
