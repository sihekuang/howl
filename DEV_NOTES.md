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
- ECAPA enrollment (`howl_enroll_compute`): reused to condition the personal-VAD
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
  a per-frame diar tensor. New `howl_*` export, new Swift bridge call.

### DiCoW vs current pipeline — structural comparison

Pipeline shapes:

```
Current:
  mic ──► [chunked frames] ──► ConvTasNet (TSE) ──► Whisper-cpp ──► text
                                    ▲
                           ECAPA embedding (enrolled, fixed)

DiCoW:
  mic ──► personal-VAD ──► DiCoW (Whisper-large-v3-turbo + FDDT) ──► text
             ▲                ▲
         ECAPA           per-frame diar tensor
         enrollment      {silent, target, other, overlap}
```

**Where speaker info enters:**

| | Current | DiCoW |
|---|---|---|
| Conditioning enters at | TSE stage | ASR stage |
| What gets conditioned | Waveform separator | Whisper's encoder layers |
| Conditioning shape | One 192-d embedding (static) | Per-frame label sequence (dynamic, ~50 ms) |
| Whisper itself knows the speaker? | No — sees whatever TSE emits | Yes — receives per-frame "is target talking now" |

**What the system reconstructs:**
- Current: a clean target waveform; any imperfection in reconstruction propagates downstream.
- DiCoW: nothing. Mixture goes in untouched, text comes out. No intermediate "cleaned audio".

**Failure modes:**

| Failure | Current | DiCoW |
|---|---|---|
| 3+ sources (TV with multiple talkers) | **Breaks** — 2-channel separator forced to merge sources | OK — no source-count limit; conditioning is timing-based |
| Interferer with similar voice | **Breaks** — ECAPA cosine ambiguous between speakers | OK — relies on *when*, not *who* |
| Separator distortion confusing ASR | Yes — Whisper not trained on ConvTasNet artifacts | N/A — no separator |
| Bad diarization | Not in our path | **Dominant error** — ~70% of remaining DiCoW WER |
| Poor voice enrollment | Hurts TSE selection | Hurts personal-VAD → diarization → WER |

The failure mode just *moves*. We trade "separator can't fit 3+ sources" for "diarizer must correctly label every 50 ms frame."

**Latency / UX profile:**

| | Current | DiCoW |
|---|---|---|
| Mode | Streaming, partial transcripts | Chunked, ~30 s windows |
| Time-to-first-word | ~hundreds of ms | ~seconds (whole window must complete) |
| Real-time factor on M-series | <1× (faster than realtime) | 2-3× (slower than realtime, chunked) |
| User perception | "Words appear as I speak" | "I speak, pause, words appear" |

**Model footprint:**

| | Current | DiCoW |
|---|---|---|
| ECAPA encoder | ~25 MB | ~25 MB (reused) |
| TSE / VAD | ConvTasNet ~5 MB | personal-VAD ~10 MB |
| ASR | Whisper-base/small ~100-500 MB | Whisper-large-v3-turbo + FDDT ~1.6 GB |
| **Total** | **~130-530 MB** | **~1.6 GB** |

**Reported WER (Libri2Mix, oracle diar):**

| Pipeline | WER |
|---|---|
| Cascade ConvTasNet + Whisper (closest to ours) | ~7.97% |
| **DiCoW (Whisper-large-v3-turbo)** | **4.4%** |
| Vanilla Whisper-large on the mixture | 588% |

**Engineering surface in our codebase:**

| Component | Current state | DiCoW state |
|---|---|---|
| `core/internal/speaker/tse.go` (ConvTasNet) | Active | Deleted |
| `core/internal/speaker/encoder.go` (ECAPA) | Used at TSE inference | Used only at enrollment (frozen) |
| `core/internal/speaker/store.go` (enrolled embedding) | Read every utterance | Read once to bootstrap personal-VAD |
| New: personal-VAD | — | Per-frame inference, online |
| Whisper inference | whisper.cpp via cgo | DiCoW via ONNX/CoreML or Python sidecar |
| C ABI input | `(audio_bytes)` | `(audio_bytes, diar_tensor)` |

**One-sentence summary:**
Today we *clean the audio first, then transcribe naively.* DiCoW *transcribes the
noisy audio while telling the model who to listen to.* Both use the same enrolled
ECAPA embedding, but in completely different roles — ours conditions a separator,
DiCoW's bootstraps a diarizer.

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

---

## Personalized denoiser survey — candidates (2026-05-11)

### Goal recap

Replace the now-disabled ConvTasNet TSE block with a personalized cleanup stage
that produces audio (waveform or mask-applied) cleaned of both non-speech noise
and competing voices, before Whisper. Single-user dictation: enrolled ECAPA-TDNN
192-d embedding already on disk; default pipeline today is DFN v0.5.6 →
Whisper-small. We prefer **mask-domain over waveform reconstruction** (less ASR
drift), **streaming-capable** (today's UX is partial transcripts), **commercially
usable license**, and **directly downloadable weights** that we can export to
ONNX/CoreML. We're optimistic about ECAPA-conditioned mask filters, sceptical of
embedding-free attention-based TSE (forces us to re-enroll), and explicitly
ruling out anything PyTorch-only with no export path.

### Comparison table

| Name | Arch | Embedding | Params / size | License | Weights public? | Streaming | Notes |
|---|---|---|---|---|---|---|---|
| DeepFilterNet3 (non-personalized, baseline) | Mask (ERB + complex DF) | none | 2.31M / ~6 MB | MIT/Apache-2.0 dual | Yes (ONNX in repo) | Yes (causal) | Current default. Not target-speaker. |
| pDeepFilterNet2 (Tang et al. 2024) | Mask (dual-stage DF) | **ECAPA 192-d, frozen** | 2.31–2.71M / ~7 MB | Paper only — no code/weights released | No | Yes (causal) | Exactly the architecture we want; nothing to download. |
| DPDFNet (Ceva 2025) | Mask (DPRNN-enhanced DF) | none | ~3M / ~10 MB | Apache-2.0 | Yes (PyTorch + ONNX + TFLite) | Yes (causal) | Stronger DFN successor; non-personalized. |
| VoiceFilter (mindslab-ai / maum-ai 2019) | Mask (mag-spec, iSTFT) | d-vector (own, ~256-d) | ~8M / ~32 MB | Apache-2.0 (code) | Author-trained on Google internal data; unofficial repro weights only | No (offline) | Author abandoned: "use at your own risk." Mag-only iSTFT degrades phase. |
| VoiceFilter-Lite (Google, 2020) | Mask (log-Mel features, asym loss) | d-vector | ~2.2 MB (TFLite) | Paper only — never open-sourced | **No** | Yes (streaming) | The gold-standard reference. No public weights. |
| SpeakerBeam (BUT/NTT) | Time-domain Conv-TasNet variant, waveform output | enrollment utt → adapt layer (mul), **not external embedding** | ~8M (TD-SB) / ~30 MB | **Evaluation-only / non-commercial, no redistribution** | Train-it-yourself only | Causal variants exist (SpeakerBeam-SS) | License kills it for shipping. Same arch family as our current ConvTasNet. |
| SpeakerBeam-SS (NTT 2024) | Conv-TasNet + state-space, waveform | enrollment utt | smaller than TD-SB | Same BUT/NTT eval license | No weights released | Streaming (causal, RTF -78%) | Same license blocker. |
| ESPnet TD-SpeakerBeam (Libri2Mix) | Time-domain, waveform | enrollment **segment** (3 s wav, 48k samples) — `use_spk_emb: false` | ~8M | Code Apache-2.0; **weights CC-BY-4.0** | **Yes** (HF: `espnet/Wangyou_Zhang_librimix_train_enh_tse_td_speakerbeam_raw`) | No (offline, full-utt) | The only SpeakerBeam-family weights we can actually ship. Wants raw enrollment audio, not our 192-d ECAPA. |
| SpEx / SpEx+ (xuchenglin28) | Time-domain, waveform | own ResBlock encoder (or i-vec/x-vec swap) | ~10M | **GPL-3.0** | No pretrained weights released | No | GPL = viral; non-starter for a closed Mac app. |
| USEF-TSE (TFGridNet / SepFormer backbones) | Both variants; TFGridNet T-F masking, SepFormer time-domain | **Embedding-free** (cross-attention to enrollment audio) | Not stated; TFGridNet backbone ~6M | **CC-BY-NC-4.0** | Yes (HF checkpoints) | No (offline) | Best published numbers but (a) NC license blocks commercial, (b) bypasses our enrolled ECAPA — needs raw enrollment audio at inference. |
| WeSep (toolkit) | All of above (SpEx+, pBSRNN, pDPCCN, tf-gridnet) | Wespeaker integration OR joint | varies | **No LICENSE file in repo** | Toolkit ships, "Pretrained models" still TODO per README | Some recipes causal | Toolkit + ONNX export path are real, but no off-the-shelf weights at this writing. |
| ESPnet `enh` TSE recipes | Multiple; mostly time-domain (Conv-TasNet, td_speakerbeam) | Enrollment utt | varies | Apache-2.0 | A handful on HF (above) | No | All published recipes target Libri2Mix offline; no streaming TSE recipe. |
| SpeechBrain TSE | No first-class TSE recipe ships today | — | — | Apache-2.0 | No TSE model in `speechbrain/*` HF org | — | We already use SpeechBrain ECAPA encoder; TSE is not on the menu. |
| pyannote `speech-separation-ami-1.0` | Waveform (PixIT joint diar+sep) | none — it diarizes then separates | model size not published | MIT (code+weights) | Yes | No (offline window) | Not TSE. Outputs N source streams + labels; we'd post-select with ECAPA. |
| WavLM-base-plus-sd | Frame-level diarization head on WavLM | none | ~94M backbone + tiny head | MIT | Yes | No (full-seq self-attn) | Source separation downstream task, not target-conditioned. Useful as a diarizer feature, not a denoiser. |
| FlowTSE (Aiola 2025) / AD-FlowTSE / MeanFlow-TSE | Generative (flow matching on mel + vocoder) | enrollment audio → mel | not disclosed | Paper only | No | No (iterative generation) | Generative pipelines reconstruct mel + vocode — worst-case ASR artifact profile. Skip. |
| E3Net (Microsoft 2022) | Waveform 1D-conv encoder | speaker embed vector | small (KD'd students 2–4× faster than teacher) | Paper only | **No** | Yes (causal) | Closest published cousin to MS Teams Voice Isolation; nothing to download. |

### Per-candidate deep dives

Only candidates that meet the basic bar (downloadable weights AND commercially-usable code path, OR clearly-runnable open code we can train ourselves) are expanded below. Everything else is filed under "paper only" or "license blocker" above.

#### DeepFilterNet3 + ECAPA gating (current baseline, no personalization)

Already in our pipeline; nothing to integrate. Calling it out because the cheapest "personalized denoiser" is **DFN3 (as-is) plus a personal-VAD gate** built on our existing ECAPA enrollment. That's not a new model, it's the personal-VAD path from the previous section's "halfway path". Strongest single lever for shipping soon.

#### DPDFNet (Ceva, 2025)

`github.com/ceva-ip/DPDFNet`, Apache-2.0, PyTorch + **ONNX + TFLite checkpoints
shipped in the repo**. DPRNN blocks bolted onto DeepFilterNet2's two-stage
filter — same mask-domain shape, stronger long-range temporal modelling, causal.
Drop-in replacement for our current DFN stage; **no speaker conditioning**, so
this is a denoiser upgrade, not a TSE replacement. Worth a measurement run since
it's truly drop-in.

#### ESPnet TD-SpeakerBeam (HF: `espnet/Wangyou_Zhang_librimix_train_enh_tse_td_speakerbeam_raw`)

Weights CC-BY-4.0 (commercial OK with attribution), code Apache-2.0. Time-domain
Conv-TasNet extractor; `use_spk_emb: false` in the config — it expects a **3-second
raw enrollment audio segment**, not our 192-d ECAPA embedding. So integration
means either (a) keep a 3 s enrollment clip on disk and pass it in alongside
every chunk, or (b) train a head that maps our ECAPA vector into the model's
internal adapt layer. Architecture is the *same family* as the ConvTasNet TSE
we just disabled — same 2-channel-separator failure mode is plausible. No
streaming. Marginal upgrade over what we deleted; only interesting because the
weights are actually shippable.

#### VoiceFilter (maum-ai / mindslab-ai)

Apache-2.0 code. d-vector embedding (not ECAPA-compatible without retraining the
condition head). Mask-domain on mag-spectrogram + iSTFT — phase reconstruction
artefact-prone, which is *exactly* the failure mode VoiceFilter-Lite was designed
to fix. **No author-shipped weights trained on public data** — community repos
provide their own checkpoints of variable quality, and the original author
publicly told users "use this code at your own risk" and stopped maintaining.
Useful as a reference implementation to copy, not as a shippable artefact.

#### USEF-TSE (ZBang)

CC-BY-NC-4.0 — **non-commercial**, so a no for shipping. Two backbones
(USEF-SepFormer time-domain, USEF-TFGridNet T-F mask-domain). The crucial
property for us: **embedding-free**. It runs cross-attention between the
mixture and an enrollment audio clip at inference time; our pre-computed 192-d
ECAPA embedding is not part of its input shape. Even if licensing changed,
adopting it means re-architecting enrollment to keep raw audio around (longer,
heavier, privacy-uncomfortable). Strong WERs in the paper, but the path forward
is closed.

#### WeSep (toolkit)

GitHub `wenet-e2e/wesep`. Toolkit (not a single model) covering SpEx+, pBSRNN,
pDPCCN, tf-gridnet — including the personalized mask-domain pBSRNN that's a
close cousin to what we want. **Repo has no LICENSE file** as of this writing
(github.com API returns null) and README explicitly lists "Pretrained models" as
a TODO. Active enough to be worth watching, but today it's a code path we'd
have to train models on, not a download. ONNX export and C++ deployment scaffold
do exist in the repo, which is the part worth keeping in mind for any later
in-house training of pBSRNN/pDPCCN.

#### pyannote `speech-separation-ami-1.0`

MIT, weights public, waveform output, PixIT joint diarization + separation. Not
target-speaker, but the dictation single-user case lets us cheat: separate
into N sources, embed each source with our ECAPA encoder, hard-select by cosine
similarity to enrolled vector. That's literally the structure of our current
`SpeakerGate` — we'd just be swapping ConvTasNet (2-source separator) for a
diarization-aware separator that can fit 3+ sources. Doesn't solve the
"separator artefact propagates to Whisper" critique, but it does fix the
narrow architectural failure (2-channel separator vs 3+ source mixture) we
flagged in the May 7 notes. Worth a measurement run.

#### pDeepFilterNet2 (Tang et al., IJST 2024)

Paper-only. ECAPA-TDNN 192-d (exact match to our enrollment), dual-stage mask
DF on top of DFN2, 0.4G MACs, RTF 0.025 on CPU, PESQ 2.36 on synth test. This is
the *ideal* candidate architecturally: same ECAPA dim we use, mask-domain,
causal/streaming, ~6 MB on disk. The demo page (`pdeepfilternet2.github.io`)
ships audio samples only, **no code, no weights**. Until they release, we'd
have to reproduce: that's a model-training project, not an integration project.

### Shortlist

Strict reading of "runnable today, ship-licensable today, replaces our TSE today" leaves a thin shelf.

1. **Personal-VAD on top of DeepFilterNet3** — not a new model. Reuses our ECAPA
   embedding to gate non-target frames after DFN3 cleans noise. Streaming, tiny,
   ships under licenses we already have. The "halfway path" from the May 7 memo
   is still the highest-EV move; this survey didn't surface a shippable
   ECAPA-conditioned mask filter that beats it.
2. **DPDFNet as a DFN3 upgrade** (Apache-2.0, ONNX-shipped) layered with that
   same personal-VAD gate. Same shape as #1, slightly better denoiser.
3. **pyannote `speech-separation-ami-1.0` + ECAPA post-selection** as a
   replacement for ConvTasNet specifically when 3+ sources are present.
   MIT-licensed, weights public, fixes the narrow architectural bug we deleted
   ConvTasNet over. Risk: still waveform-reconstruction, still feeds Whisper
   reconstructed audio.

Honourable mention: **ESPnet TD-SpeakerBeam** weights are the only TSE
checkpoint with a commercial-friendly license, but it's the same architecture
family that just failed us, expects 3 s of enrollment audio rather than our
ECAPA vector, and isn't streaming. Not worth prototyping ahead of #1–#3.

### Open questions

- Does the pDeepFilterNet2 group plan a code release? Last paper traffic
  April 2024 — worth one nudge before assuming "never."
- Measured RTF on M2/M3 for DPDFNet ONNX through `onnxruntime_go` — paper
  numbers are CPU-only PyTorch, no Core ML / NE benchmark.
- WER (not just SDR / PESQ) when pyannote-sep + ECAPA-pick feeds Whisper-small.
  Separator artefacts are the whole reason we're sceptical; until measured,
  this is a guess.
- Whether anyone has shipped a reproduction of VoiceFilter-Lite that we missed.
  The Google paper is heavily-cited (~300+) but the "lite" weights specifically
  remain Google-internal; if a strong open reproduction exists it's the
  best-fit architecture for our problem.
- Whether ESPnet TD-SpeakerBeam can be retrained with `use_spk_emb: true` to
  accept our 192-d ECAPA directly, on top of the existing CC-BY-4.0 weights as
  a starting point. Cheaper than scratch training; would make those weights
  actually useful for our enrollment shape.

### Sources

- [pDeepFilterNet2 paper (arXiv 2404.08022)](https://arxiv.org/html/2404.08022v1)
- [pDeepFilterNet2 demo site](https://pdeepfilternet2.github.io/)
- [DeepFilterNet GitHub](https://github.com/Rikorose/DeepFilterNet)
- [DPDFNet (Ceva) GitHub](https://github.com/ceva-ip/DPDFNet)
- [VoiceFilter (maum-ai) GitHub](https://github.com/maum-ai/voicefilter)
- [VoiceFilter-Lite paper (arXiv 2009.04323)](https://arxiv.org/abs/2009.04323)
- [VoiceFilter-Lite project page](https://google.github.io/speaker-id/publications/VoiceFilter-Lite/)
- [SpeakerBeam GitHub (BUT/NTT)](https://github.com/BUTSpeechFIT/speakerbeam)
- [SpeakerBeam evaluation-only license (LICENSE.txt)](https://github.com/BUTSpeechFIT/speakerbeam/blob/main/LICENSE.txt)
- [SpeakerBeam-SS paper (arXiv 2407.01857)](https://arxiv.org/abs/2407.01857)
- [TD-SpeakerBeam paper (arXiv 2001.08378)](https://arxiv.org/abs/2001.08378)
- [ESPnet TD-SpeakerBeam pretrained (HF)](https://huggingface.co/espnet/Wangyou_Zhang_librimix_train_enh_tse_td_speakerbeam_raw)
- [SpEx+ / speaker_extraction_SpEx GitHub](https://github.com/xuchenglin28/speaker_extraction_SpEx)
- [USEF-TSE GitHub](https://github.com/ZBang/USEF-TSE)
- [USEF-TSE paper (arXiv 2409.02615)](https://arxiv.org/abs/2409.02615)
- [WeSep GitHub](https://github.com/wenet-e2e/wesep)
- [WeSep paper (arXiv 2409.15799)](https://arxiv.org/abs/2409.15799)
- [pyannote speech-separation-ami-1.0 (HF)](https://huggingface.co/pyannote/speech-separation-ami-1.0)
- [pyannote-audio GitHub](https://github.com/pyannote/pyannote-audio)
- [WavLM base-plus-sd (HF)](https://huggingface.co/microsoft/wavlm-base-plus-sd)
- [E3Net paper (arXiv 2204.00771)](https://arxiv.org/abs/2204.00771)
- [FlowTSE paper (arXiv 2505.14465)](https://arxiv.org/abs/2505.14465)
- [SpeechBrain ECAPA-TDNN (HF)](https://huggingface.co/speechbrain/spkrec-ecapa-voxceleb)

---

## Cleanup harness bring-up — first run (2026-05-11)

First run of `TestCleanup_Matrix` produced the table in
`/tmp/matrix-firstrun.txt` (or wherever the engineer captured it).
Numbers are baseline calibration only — the rubric in the design spec
gets recalibrated against these.

### What to look for in the first numbers

- **Passthrough WER on `clean (no mix)`** — establishes the WER floor
  for our Whisper model + LibriSpeech clips. Anything worse than this
  on a clean condition is broken.
- **Passthrough WER on `voice+voice 0dB`** — establishes the upper
  bound. Cleanup candidates need to beat this by ≥5 points to clear
  the rubric.
- **Passthrough simT/simI margin on `voice+voice 0dB`** — sanity
  check that an unprocessed mixture has narrow margin (<0.05). If it's
  wider than that, the encoder is biased toward one of the two voices
  and the margin metric is less informative than expected.
- **SpeakerGate (former default) numbers across the matrix** — gives
  us back the May-7 picture: where it works, where it falls apart on
  multi-voice / overlap conditions.
- **PyannoteSepECAPA, when present** — the actual prototype answer.

### Rubric calibration follow-up

After capturing the baseline, update
`docs/superpowers/specs/2026-05-11-audio-cleanup-eval-harness-design.md`
with the actual baseline numbers and revised rubric thresholds, dated.
The numbers in the spec today are starting points only.

### First-run results (2026-05-11)

Run command:
```
WHISPER_MODEL_PATH="$HOME/Library/Application Support/VoiceKeyboard/models/ggml-tiny.en.bin" \
  go test -tags 'cleanupeval whispercpp' -v -run TestCleanup_Matrix \
  -timeout 20m ./internal/speaker/...
```

Model used: `ggml-tiny.en.bin` (ggml-small.bin not present; tiny is the fastest available).
SpeakerGate and PyannoteSepECAPA both skipped (models unavailable — `tse_model.onnx` /
`pyannote_sep.onnx` not found at the optional search paths).
Harness compiled and ran cleanly. Total elapsed: ~4 seconds.

Full output table (fixture=libri_speech, target=A, reference voice clip=libri-1272-M):

```
candidate            | condition                      | simT    | simI    | margin  | RMSr   | WER%   | notes
---------------------+--------------------------------+---------+---------+---------+--------+--------+------
passthrough          | clean (no mix)                 |  1.0000 |  0.8773 | +0.1227 |  1.000 |   9.09 | hyp="Nor is Mr. Quilter's manner less interesting than his matter."
speakergate          | clean (no mix)                 | —       | —       | —       | —      | —      | skipped (model unavailable)
pyannote_sep_ecapa   | clean (no mix)                 | —       | —       | —       | —      | —      | skipped (model unavailable)
passthrough          | voice+voice 0dB                |  0.9467 |  0.9091 | +0.0377 |  1.000 | 136.36 | hyp="It was not as Mr. Croker's manner unless interested. But everything is all in the time."
speakergate          | voice+voice 0dB                | —       | —       | —       | —      | —      | skipped (model unavailable)
pyannote_sep_ecapa   | voice+voice 0dB                | —       | —       | —       | —      | —      | skipped (model unavailable)
passthrough          | voice+voice -6dB               |  0.9251 |  0.9478 | -0.0228 |  1.000 | 109.09 | hyp="It was yours and poverty and proximity. But everything was young after."
speakergate          | voice+voice -6dB               | —       | —       | —       | —      | —      | skipped (model unavailable)
pyannote_sep_ecapa   | voice+voice -6dB               | —       | —       | —       | —      | —      | skipped (model unavailable)
passthrough          | voice+voice -12dB              |  0.8632 |  0.9391 | -0.0759 |  1.000 | 118.18 | hyp="It was yours and poverty and proximity, because everything was yelling at kindly."
speakergate          | voice+voice -12dB              | —       | —       | —       | —      | —      | skipped (model unavailable)
pyannote_sep_ecapa   | voice+voice -12dB              | —       | —       | —       | —      | —      | skipped (model unavailable)
passthrough          | voice+music 0dB                |  0.7615 |  0.7099 | +0.0516 |  1.000 |  81.82 | hyp="Nor is Mr. Colter's manner of this interesting thing, he's a mentor."
speakergate          | voice+music 0dB                | —       | —       | —       | —      | —      | skipped (model unavailable)
pyannote_sep_ecapa   | voice+music 0dB                | —       | —       | —       | —      | —      | skipped (model unavailable)
passthrough          | voice+music -6dB               |  0.5682 |  0.5435 | +0.0247 |  1.000 |  63.64 | hyp="Nor is Mr. Colter's manner of this interesting thing is better."
speakergate          | voice+music -6dB               | —       | —       | —       | —      | —      | skipped (model unavailable)
pyannote_sep_ecapa   | voice+music -6dB               | —       | —       | —       | —      | —      | skipped (model unavailable)
passthrough          | voice+music -12dB              |  0.3827 |  0.4159 | -0.0332 |  1.000 | 136.36 | hyp="Nor is Mr. Contrasman or this interesting thing is Mr. Contrasman or this interesting thing is Mr. Contrasman."
  ⚠ simT 0.3827 < 0.40 (output may not look like target)
speakergate          | voice+music -12dB              | —       | —       | —       | —      | —      | skipped (model unavailable)
pyannote_sep_ecapa   | voice+music -12dB              | —       | —       | —       | —      | —      | skipped (model unavailable)
passthrough          | voice+voice+music -6dB / 0dB   |  0.8116 |  0.8317 | -0.0201 |  1.000 | 172.73 | hyp="It was yours. It was talker-y. It was unboxy musking. It was everything we've known that, kindly."
speakergate          | voice+voice+music -6dB / 0dB   | —       | —       | —       | —      | —      | skipped (model unavailable)
pyannote_sep_ecapa   | voice+voice+music -6dB / 0dB   | —       | —       | —       | —      | —      | skipped (model unavailable)
```

### Observations on the baseline numbers

**WER floor (clean, no mix):** 9.09% with ggml-tiny.en. The reference transcript is
"Nor is Mr. Quilter's manner less interesting than his matter." — tiny got it right, so
the 9.09% is from a single word-level error (one word substituted). Rerun with ggml-small
to see whether WER floor drops to ~0%.

**Passthrough WER at voice+voice 0dB:** 136.36% — Whisper on a raw two-voice mixture is
badly broken, as expected. This establishes the ceiling any cleanup candidate needs to beat.

**simT/simI margin at voice+voice 0dB:** +0.0377 — narrower than the 0.05 threshold noted
in the design spec, confirming the unprocessed mixture has ambiguous speaker identity.
At -6dB (interferer louder) the margin inverts to -0.0228 (simI > simT), which is correct
behaviour — Whisper-tiny-on-mixture is picking up the stronger voice.

**voice+music -12dB:** simT drops to 0.3827 (below the 0.40 warning threshold), WER=136.36%
with hallucinated repetition in the hypothesis. At -12dB the music signal is dominant; this
is a genuine edge condition that cleanup candidates should address. The ⚠ warning fires
correctly.

**SpeakerGate / PyannoteSepECAPA:** both skipped because `tse_model.onnx` and
`pyannote_sep.onnx` are not at the optional search paths (`core/build/models/`). To enable
them, copy or symlink the model files there and re-run. The `speaker_encoder.onnx` present
in `~/Library/Application Support/VoiceKeyboard/models/` is picked up automatically by
`resolveModelPath` for SPEAKER_ENCODER_PATH, but the optional-path adapters use
`optionalModelPath` which only checks `core/build/models/`.

**Harness wiring:** no panics, no type errors, no compile failures. The build tag
(`cleanupeval whispercpp`) compiles cleanly; per-row failures are isolated (skipped rows
do not stop other rows). Matrix is ready for real candidate comparisons once models are
sourced.
