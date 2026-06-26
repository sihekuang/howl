# diar_mask / pyannote backend — findings & learnings

**Date:** 2026-06-25
**Branch:** `worktree-speaker-diarization-tse` (not merged to `main`)
**Spec:** `docs/superpowers/specs/2026-06-21-audio-filter-backend-diarmask-frontend-design.md`
**Plan:** `docs/superpowers/plans/2026-06-21-audio-filter-backend-diarmask-frontend.md`

A record of what was built, what the real pyannote model actually does, and where the approach's limits are. Written after exporting the real model and running it end-to-end.

## What was built

`diar_mask` (diarize → cosine-SELECT the enrolled speaker → time-MASK the original audio) is now a **user-selectable `pyannote` backend** in the `audio_filter` pipeline slot (renamed from `tse`), chosen the same way the existing `ecapa` backend is. Full vertical slice:

- **Go core:** `speaker.Backend` generalized with a `Kind` (`separation` | `diarmask`); `pyannote` registered; `LoadAudioFilter` dispatches to either `SpeakerGate` (ecapa) or `DiarMask`+pyannote segmenter; backend-aware C-ABI (`howl_tse_extract_file` gained a `backend` param).
- **Rename:** the chunk stage `tse` → `audio_filter` (data-model identity only). Config keys (`tse_*`), model filenames (`tse_model.onnx`), the C-ABI symbol, and the manifest key (`tse_similarity`) deliberately kept on legacy names; legacy `tse` reads tolerated on both Go and Swift sides.
- **Swift:** backend picker (ecapa | pyannote), threshold control hidden for pyannote (it has no gate), `pyannote_seg.onnx` model-status row, TSE Lab wired to run either backend.
- All tasks reviewed; final whole-branch review clean; Go + Swift suites green.

## The export (`pyannote_seg.onnx`)

`pyannote/segmentation-3.0` → ONNX. **Not committed** (5.9 MB binary); reproduce via `core/scripts/export-pyannote-seg.py`. Gotchas hit and fixed:

- **Python:** use 3.12 (Homebrew `python3.12`). The machine default 3.14 is too new for torch/pyannote.
- **Gated model:** must accept the EULA on the HF model page + have a cached HF token (`huggingface-cli login` → `~/.cache/huggingface/token`). The script reads the cache (`use_auth_token=True`); no token on the CLI.
- **torch ≥ 2.9 export:** the script needs `onnxscript` installed, and **`torch.onnx.export(..., dynamo=False)`** — torch's new "dynamo" exporter fails on SincNet's learnable filterbank (`aten::clamp` with a FakeTensor min); the legacy TorchScript exporter traces it concretely.
- **ONNX contract (verified):** input `waveform [1,1,160000]` (10 s @ 16 kHz) → output `segmentation [1, num_frames, 7]` (7-class powerset, max 2 simultaneous speakers). Class order: non-speech, spk1, spk2, spk3, spk1+2, spk1+3, spk2+3 — `powersetToActivity` depends on this.

## Verification results

Same Daniel+Samantha (or real-enrolled) mixtures; retention = how much of the target's solo audio survives (1.0 = fully kept), leak = how much of the interferer-only region survives (0 = fully removed, 1.0 = passthrough).

| Condition | retention (target) | interferer leak | notes |
|---|---|---|---|
| oracle segmenter (clean TTS, 1 window) | 0.997 | **0.000** | masking logic given perfect diarization |
| **real pyannote** (clean TTS, 1 window) | 0.997 | **0.165** | SELECT conf 0.991 → powerset decode + class order CORRECT |
| **real pyannote** (real enrolled voice, 2 windows) | 1.000 | **0.189** | window with 1 speaker → correct passthrough |

**The design is verified end-to-end with the real model.** Target retention matches the oracle (≈1.0 — the enrolled voice is *not* cut, which was the whole goal). The export is correct: if the powerset class ordering or output format had been wrong, the SELECT would have picked the wrong track; it didn't.

## Key learnings (why it can feel like it "isn't working well")

These are properties of the approach, not bugs:

1. **diar_mask is inclusion-biased by design.** It preserves the target fully and leaves **~15–20% interferer residual** rather than risk cutting the user. It will *never* aggressively scrub — that's the `ecapa`/TSE backend's behavior, and aggressive scrubbing is exactly what was over-suppressing the user's voice (the original motivation). The tradeoff is explicit: "stop cutting my voice" (retention ≈ 1.0) costs "doesn't fully remove interference" (leak ≈ 0.18).
2. **Single-speaker input → passthrough.** If only one speaker has ≥0.5 s of exclusive speech in a window, there's nothing to separate, so diar_mask returns the audio unchanged. Correct, but reads as "doing nothing." (Observed directly: a window of the user talking alone → `ok=false` → passthrough.)
3. **pyannote's real-audio boundaries are fuzzy.** On the real-enrollment test, pyannote tagged a 3.4 s solo region as only 1.37 s of "exclusive" speech. The SELECT still found the target (cosine 0.833), but mask edges are soft, so some interferer bleeds at the seams.
4. **Per-window (10 s) independent diarization.** Local speaker indices are not tracked across windows; the per-window cosine SELECT re-identifies the target each window (robust), but the `minExclusiveSeconds = 0.5` gate means brief interferers in short/final windows pass through.

## Open questions / next steps

- **User-reported underperformance is not yet reproduced on the user's actual audio.** Need: the specific clip (single-speaker vs multi-speaker? noisy?) and the expectation (interferer fully gone vs voice not cut). The diagnostic harness `TestDiarMask_DiagnoseRealEnrollment` (tag `cleanupeval`, needs `HOWL_VOICE_DIR`) runs any such clip through the real path with per-window decisions logged.
- **If more interferer removal is wanted**, tuning levers: lower `MinSelectCosine` / `MinExclusiveSeconds`, pair diar_mask with the denoiser stage, or add an optional soft gate. Each trades some of the inclusion-bias safety.
- **Harder regimes still untested:** real noise fixtures (MUSAN/DEMAND), lower SNR, music/TV interferers, larger Whisper — the existing eval harness (`core/CLAUDE.md`) is the place for these.

## Status

Code complete, reviewed, tests green. The pyannote model functions correctly end-to-end. Branch pushed to `origin` for the record; **not merged to `main`** (held per project policy). The remaining question is product-level: whether diar_mask's inclusion-biased behavior matches what the user wants, or whether it needs tuning toward more aggressive removal.
