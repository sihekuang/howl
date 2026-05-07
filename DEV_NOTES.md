# Dev Notes

Working notes on architecture decisions, research findings, and open questions.
Not user-facing. Update freely; commit when stable.

---

## TSE noise robustness — research findings (2026-05-07)

### Problem we're trying to solve

Current TSE pipeline (ConvTasNet Libri2Mix sep_noisy 16k + ECAPA-TDNN-512
embedding, conditioned waveform extraction) works on clean 2-speaker mixes
but breaks on multi-voice "TV noise" — the diagnostic `TestTSE_NoiseRobustness_MultiVoice`
shows `simNoise > simTarget` at SNR ≤ -6 dB once the interferer track itself
contains 2+ voices. Architectural limit: a 2-channel separator forced to fit
3+ sources puts the user's voice and competing voices into the same channel.

### What shipping products actually do

**TSE is in production, but rarely as waveform separation.** Disclosed deployments:

| Product | Approach | Speaker-conditioned? |
|---|---|---|
| Google VoiceFilter-Lite | Feature-space personalized filter (log-Mel masking), 2.2 MB, asymmetric loss biased toward leakage | Yes |
| MS Teams Voice Isolation | Personalized DNN, ~30 s enrollment, conservative tuning | Yes |
| Krisp Background Voice Cancellation | Waveform TSE with pitch-bucket separation | Yes (with admitted failure when interferer pitch overlaps) |
| Apple Voice Isolation | Voice-vs-noise on-device | **No** (not speaker-conditioned per public disclosures) |
| Nvidia Broadcast / RTX Voice | Noise suppression only | **No** |
| Zoom / Google Meet default | Noise suppression only | **No** |

**Dictation tools publish nothing about speaker-conditioned filtering.** Wispr Flow,
Superwhisper, MacWhisper, Aqua, Dragon all rely on Whisper's intrinsic noise
robustness + a good mic + CoreAudio's voice processing AU. Our ConvTasNet+ECAPA
pipeline is more aggressive than what's shipping in any open-source dictation product.

### Architectural alternatives, ranked

1. **Personal-VAD / speaker-verification gate** (cheapest)
   Per-frame ECAPA cosine vs enrolled embedding + hysteresis → mute non-target frames.
   No separation, just gating. ~1 day of work; reuses our existing encoder.
   Solves the most common "user pauses, TV continues" scenario.

2. **CoreAudio Voice Processing AU / mic-array beamforming** (free)
   AVAudioEngine's voice processing on Apple Silicon does noise + echo suppression
   with multi-mic null-steering. MacBook 3-mic arrays accessible via CoreAudio.

3. **Personalized denoiser** (medium effort, production-proven)
   DeepFilterNet3 + ECAPA conditioning, mask-domain, asymmetric loss
   (Wang et al., VoiceFilter-Lite-style). Stops trying to "split" 3+ sources;
   asks "is this frame the user?" Open-source base at Rikorose/DeepFilterNet.

4. **SOTA waveform TSE** (MossFormer2, USEF-TFGridNet)
   Bigger, better separators in the same family as ConvTasNet.
   MossFormer2: SI-SDRi 24.1 dB on WSJ0-2mix. Same fundamental brittleness class —
   they reconstruct waveforms, which still introduces artifacts.

5. **Target-speaker ASR** (DiCoW, TS-ASR-Whisper) — see quality section below

### Best-quality answer: DiCoW (Diarization-Conditioned Whisper)

**The field has converged on diarization-conditioned end-to-end ASR, not cascade.**
Best runnable-on-a-Mac SOTA is DiCoW (BUT/JHU, Dec 2024, arXiv 2501.00114).

**Architecture:**

```
single-mic audio ──► personal-VAD ──► DiCoW (Whisper-large-v3-turbo + FDDT layers)
                       ▲
                  ECAPA enrollment
```

**What DiCoW does internally:**

Inputs: audio waveform + per-frame diarization tensor at Whisper's ~50 ms frame
resolution. Each frame is one of {silent, target, other, overlap}.

Three modifications to Whisper:

- **FDDT (Frame-level Diarization-Dependent Transformations)** — four small
  linear projections per encoder layer (one per diarization category). Each
  frame routes through the projection matching its label. The model learns to
  amplify target frames, suppress other frames, separate overlap frames.
- **Query-Key biasing** — learnable bias on self-attention keyed on
  diarization labels. Target-active frames bias toward attending to other
  target-active frames.
- **CTC head** (training-time only) — auxiliary loss aligning text tokens to
  target-speaker frames.

**Why this beats cascades:** Waveform separation introduces nonlinear distortion
Whisper wasn't trained on. CHiME-8 published lesson: *"Dia-Sep-ASR systems
outperformed CSS-ASR-Dia systems"* — wins came from the ASR, not the separator.
Whisper-large-v3 already handles noisy audio; it just needs to be told *who* to
transcribe.

### Reported numbers (Whisper-large-v3-turbo, oracle diarization)

| Benchmark | Vanilla Whisper | DiCoW |
|---|---|---|
| Libri2Mix tcpWER | 588% | **4.4%** |
| LibriCSS | — | **5.5%** |
| AMI single-distant-mic | 220% | **19.7%** |
| NOTSOFAR-1 (real meetings) | 260% | **19.7%** |

With real (non-oracle) diarization, NOTSOFAR-1 jumps to 33.5%. **~70% of remaining
error is the diarizer**, not the ASR — the personal-VAD is where quality is won.

### Quality ceiling

- ~4–5% WER on 2-talker mixtures (oracle diar)
- ~15–20% WER in TV-with-3-talkers conditions (best published)
- Below -5 dB SNR with same-language interferer: every published system collapses
- Diarization quality dominates remaining error at realistic SNRs

### Architectural fit assessment

**What survives if we adopt DiCoW:**
- Audio capture / Go core / C ABI / Swift shell: unchanged
- ECAPA enrollment (`vkb_enroll_compute`): reused to condition the personal-VAD
- TSE Lab UI, Settings, Compare, Inspector: unchanged
- xcodegen / model-bundling shape: same, different files

**What doesn't:**
- ConvTasNet TSE block: deleted (separator artifacts actively hurt DiCoW WER)
- whisper.cpp: **the real architectural blocker.** DiCoW modifies Whisper's
  encoder layers internally (FDDT + QKb). whisper.cpp's ggml graph has no hook
  points for that. Three options:
  1. Fork whisper.cpp and add FDDT injection into ggml ops (weeks of low-level work)
  2. Export DiCoW to ONNX/CoreML, run via onnxruntime_go alongside existing TSE plumbing
  3. Run DiCoW as a Python sidecar (easiest, worst for distribution — bundles a Python runtime)
- Streaming → chunked. Today: partial transcripts as user speaks. DiCoW: ~30 s
  windows, push-to-talk-and-wait. UX shift.
- Model size jump: probably Whisper-small/base (~100 MB) → large-v3-turbo
  (~1.6 GB fp16). Disk, RAM, first-load grow.
- C ABI surface grows: today we pass audio bytes; with DiCoW we'd pass audio +
  a per-frame diar tensor. New `vkb_*` export, new Swift bridge call.

### Open-source / Mac realism

- DiCoW: github.com/BUTSpeechFIT/DiCoW, weights on HF (CC BY 4.0), in HF Transformers.
  ~809M params, ~1.6 GB fp16. Backbone Whisper-large-v3-turbo CoreML-convertable
  via whisper.cpp; FDDT layers are simple per-layer projections, ~3-5% extra params.
- Bundled diarizer is CC BY-NC (research-only) — for commercial use, swap in
  pyannote-3.1, NeMo Sortformer, or build personal-VAD on top of our ECAPA enrollment
  (cheaper and more accurate than full diarization for single-user dictation).
- Not natively streaming. Chunk-based offline; ~2-3× real-time on M2/M3 for 30 s windows.
- True sub-200 ms streaming is not achievable with this class of model.

### Recommendation if money/effort were no object

1. **ECAPA-conditioned personal-VAD** as the diarizer. Single user → easier than
   meeting diarization; should land near oracle WER numbers.
2. **DiCoW on Whisper-large-v3-turbo** with that personal-VAD as conditioning.
3. **DeepFilterNet3 for non-speech noise** (fans, keyboards) as light pre-clean.
4. **Drop ConvTasNet entirely.** USEF-TFGridNet/MossFormer2 win SI-SDR but lose
   WER once Whisper sees their artifacts.

### Halfway path (if we want to ship something soon)

Build the **personal-VAD** piece first. It's useful in *both* worlds:
- Today's pipeline: gates ConvTasNet so TV-noise scenarios stop fighting the
  2-channel separator.
- Future DiCoW pipeline: it *is* the diarizer.

Personal-VAD work is never wasted. ~1-2 weeks. Highest-leverage single change.

### Honest caveat

Best published WER numbers (USTC's 22.2% on NOTSOFAR-1, MS Teams Voice Isolation
in production) come from systems we cannot run — heavy ensembles, internal data,
internal models. DiCoW is the best **runnable** SOTA, within ~3-5 absolute WER
points of closed leaders. **For streaming dictation**, nothing published is
*both* SOTA and truly streaming — we'd trade ~2-3% WER for chunked-streaming UX.

### Sources

- [DiCoW: Diarization-Conditioned Whisper for TS-ASR (arXiv 2501.00114)](https://arxiv.org/abs/2501.00114)
- [DiCoW HTML with WER tables](https://arxiv.org/html/2501.00114v1)
- [VoiceFilter-Lite (arXiv 2009.04323)](https://arxiv.org/abs/2009.04323)
- [Google Research blog: VoiceFilter-Lite](https://research.google/blog/improving-on-device-speech-recognition-with-voicefilter-lite/)
- [MS Teams Voice Isolation announcement](https://techcommunity.microsoft.com/blog/microsoftteamsblog/voice-isolation-in-microsoft-teams-enables-personalized-noise-suppression-for-ca/4096077)
- [Krisp BVC docs (pitch-bucket separation)](https://help.krisp.ai/hc/en-us/articles/5356050927644-Background-Voice-Cancellation-with-Krisp)
- [CHiME-8 DASR Challenge overview (arXiv 2407.16447)](https://arxiv.org/html/2407.16447)
- [NOTSOFAR-1 Challenge Summary (arXiv 2501.17304)](https://arxiv.org/html/2501.17304.pdf)
- [USEF-TSE: Universal Speaker Embedding Free TSE (arXiv 2409.02615)](https://arxiv.org/abs/2409.02615)
- [MossFormer2 paper (arXiv 2312.11825)](https://arxiv.org/html/2312.11825v1)
- [DeepFilterNet GitHub](https://github.com/Rikorose/DeepFilterNet)
- [Thinking in Cocktail Party: CoT + RL for TS-ASR (arXiv 2509.15612)](https://arxiv.org/html/2509.15612)
- [TS-ASR-Whisper code (BUT)](https://github.com/BUTSpeechFIT/TS-ASR-Whisper)
- [DiCoW code](https://github.com/BUTSpeechFIT/DiCoW)
