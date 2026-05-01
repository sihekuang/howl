#!/usr/bin/env python3
"""
Export the combined TSE model to ONNX.

Architecture:
  1. ConvTasNet (JorisCos/ConvTasNet_Libri2Mix_sepnoisy_16k) separates mixed
     audio into 2 sources. Native 16 kHz, trained on noisy 2-speaker mixes
     (Libri2Mix sep_noisy task) — handles speech mixed with WHAM-style noise.
  2. ECAPA-TDNN-512 (Wespeaker/wespeaker-voxceleb-ecapa-tdnn512) embeds each
     source. Kaldi-style 80-dim Fbank front-end is built into the ONNX graph
     (conv1d-based) so the runtime contract stays "raw audio in, embedding out".
  3. Hard-select the source whose L2-normalised embedding is closest to the
     enrolled speaker embedding (cosine similarity).

Inputs:  mixed         float32[1, T]   — 16 kHz mono mixed audio
         ref_embedding float32[1, 192] — L2-normalised enrolled ECAPA embedding
Output:  extracted     float32[1, T]   — separated audio for the enrolled speaker

The enrollment embedding is precomputed once by compute_enrollment_embedding.py
(which uses speaker_encoder.onnx) and saved as enrollment.emb.

This script requires Wespeaker's pretrained ECAPA ONNX (auto-downloaded to
~/.cache/voice-keyboard/ecapa.onnx on first run) and onnx2torch to load it back
as a PyTorch module so it can be embedded inside the combined TSE graph.

Usage:
    python scripts/export_tse_model.py --out core/build/models/tse_model.onnx
"""

import argparse
import os
import urllib.request
import warnings
from pathlib import Path

warnings.filterwarnings("ignore")


ECAPA_URL = "https://huggingface.co/Wespeaker/wespeaker-voxceleb-ecapa-tdnn512/resolve/main/voxceleb_ECAPA512.onnx?download=true"
ECAPA_CACHE = Path.home() / ".cache" / "voice-keyboard" / "ecapa.onnx"
ECAPA_CACHE_FIXED = Path.home() / ".cache" / "voice-keyboard" / "ecapa_fixed.onnx"
EMBED_DIM = 192
N_MELS = 80


def fetch_ecapa_onnx() -> Path:
    """Download ECAPA ONNX into the user cache and patch a malformed Clip node.

    The published ONNX has a Clip op with an empty third input (optional max),
    which onnx2torch rejects. Trim trailing empty inputs and save a fixed copy.
    Idempotent.
    """
    import onnx

    ECAPA_CACHE.parent.mkdir(parents=True, exist_ok=True)
    if not ECAPA_CACHE.exists():
        print(f"Downloading ECAPA ONNX to {ECAPA_CACHE}...")
        urllib.request.urlretrieve(ECAPA_URL, ECAPA_CACHE)

    if not ECAPA_CACHE_FIXED.exists():
        print(f"Patching ECAPA ONNX (Clip-with-empty-max) → {ECAPA_CACHE_FIXED}")
        m = onnx.load(str(ECAPA_CACHE))
        for node in m.graph.node:
            if node.op_type == "Clip":
                while len(node.input) > 0 and node.input[-1] == "":
                    node.input.pop()
        onnx.save(m, str(ECAPA_CACHE_FIXED))
    return ECAPA_CACHE_FIXED


def make_kaldi_mel_filterbank(sr=16000, n_fft=512, n_mels=80, low=20.0, high=None):
    """Kaldi-style triangular mel filterbank with htk-compat=False. Returns [n_mels, n_freqs]."""
    import numpy as np

    def hz_to_mel(f):
        return 1127.0 * np.log(1.0 + f / 700.0)

    def mel_to_hz(m):
        return 700.0 * (np.exp(m / 1127.0) - 1.0)

    if high is None:
        high = sr / 2.0  # Kaldi default — up to Nyquist when high_freq=0

    n_freqs = n_fft // 2 + 1
    fft_bin_hz = np.linspace(0.0, sr / 2.0, n_freqs).astype("float32")
    mel_low, mel_high = hz_to_mel(low), hz_to_mel(high)
    mel_pts = np.linspace(mel_low, mel_high, n_mels + 2).astype("float32")
    hz_pts = mel_to_hz(mel_pts).astype("float32")
    fb = np.zeros((n_mels, n_freqs), dtype="float32")
    for m in range(n_mels):
        lo, ctr, hi = hz_pts[m], hz_pts[m + 1], hz_pts[m + 2]
        for k, f in enumerate(fft_bin_hz):
            if lo <= f <= ctr:
                fb[m, k] = (f - lo) / (ctr - lo)
            elif ctr < f <= hi:
                fb[m, k] = (hi - f) / (hi - ctr)
    return fb


def make_povey_window(n: int):
    """Povey window — Kaldi default. Raised cosine to power 0.85."""
    import numpy as np
    import torch

    a = np.arange(n, dtype="float32")
    w = (0.5 - 0.5 * np.cos(2.0 * np.pi * a / (n - 1))) ** 0.85
    return torch.from_numpy(w.astype("float32"))


class KaldiFbank80(__import__("torch").nn.Module):
    """ONNX-traceable Kaldi-compatible 80-dim Fbank.

    Steps per frame (matches torchaudio.compliance.kaldi.fbank with
    num_mel_bins=80, frame_length=25, frame_shift=10, dither=0,
    sample_frequency=16000, energy_floor=1.0):
      1. Frame: 25 ms (400 samples) windows, 10 ms (160 samples) hop
      2. DC removal: subtract per-frame mean
      3. Pre-emphasis: y[i] = x[i] - 0.97 * x[i-1] (replicate-pad start)
      4. Multiply by Povey window
      5. Zero-pad to n_fft=512
      6. STFT magnitude → power
      7. Mel filterbank (Kaldi-style, low=20 Hz, high=7600 Hz)
      8. log(max(., energy_floor))
    Returns [B, T_frames, 80].
    """

    def __init__(self, sr=16000, frame_length=400, frame_shift=160, n_fft=512,
                 n_mels=N_MELS, log_floor=1.19209e-7, preemph=0.97):
        import numpy as np
        import torch

        super().__init__()
        self.sr = sr
        self.frame_length = frame_length
        self.frame_shift = frame_shift
        self.n_fft = n_fft
        self.log_floor = log_floor
        self.preemph = preemph

        povey = make_povey_window(frame_length)  # [frame_length]
        self.register_buffer("povey", povey)

        # Identity kernel for conv1d-based framing (replaces torch.unfold which
        # doesn't ONNX-export under dynamic input length). Each output channel
        # picks one sample within the kernel window: out[b, k, t] = in[b, 0, t*stride + k].
        frame_kernel = torch.eye(frame_length, dtype=torch.float32).unsqueeze(1)
        self.register_buffer("frame_kernel", frame_kernel)

        # STFT basis: cos/sin at each frequency bin × time index
        n = torch.arange(n_fft, dtype=torch.float32)
        freqs = torch.arange(n_fft // 2 + 1, dtype=torch.float32)
        cos_b = torch.cos(2.0 * np.pi * freqs[:, None] * n[None, :] / n_fft).unsqueeze(1)
        sin_b = torch.sin(2.0 * np.pi * freqs[:, None] * n[None, :] / n_fft).unsqueeze(1)
        self.register_buffer("cos_b", cos_b)
        self.register_buffer("sin_b", sin_b)

        fb = make_kaldi_mel_filterbank(sr, n_fft, n_mels)
        self.register_buffer("mel_fb", torch.from_numpy(fb))

    def forward(self, wav):
        import torch
        import torch.nn.functional as F

        # wav: [B, T] (float32, 16 kHz, range ~[-1, 1])
        if wav.dim() == 1:
            wav = wav.unsqueeze(0)
        B = wav.shape[0]

        # Frame first (Kaldi-style; pre-emphasis is per-frame with replicate pad).
        # ONNX-traceable framing via conv1d with identity kernel: each output channel
        # picks one position within the window, stride = frame_shift.
        x = wav.unsqueeze(1)  # [B, 1, T]
        frames = F.conv1d(x, self.frame_kernel, stride=self.frame_shift)  # [B, frame_length, n_frames]
        frames = frames.transpose(1, 2)  # [B, n_frames, frame_length]

        # DC removal: subtract per-frame mean (must come before pre-emphasis to match Kaldi).
        frames = frames - frames.mean(dim=-1, keepdim=True)

        # Per-frame pre-emphasis with replicate-pad at the frame's first sample:
        # shifted[t] = frames[max(t-1, 0)]; out[t] = frames[t] - preemph * shifted[t].
        shifted = F.pad(frames[..., :-1], (1, 0), mode="replicate")
        frames = frames - self.preemph * shifted

        # Window
        frames = frames * self.povey  # broadcast: [B, n_frames, frame_length]

        # Zero-pad to n_fft
        if self.n_fft > self.frame_length:
            pad = self.n_fft - self.frame_length
            frames = F.pad(frames, (0, pad))  # [B, n_frames, n_fft]

        # STFT magnitude via conv-style cos/sin projection.
        # frames: [B, n_frames, n_fft] → reshape so each frame is treated as one "batch element"
        flat = frames.reshape(-1, 1, self.n_fft)  # [B*n_frames, 1, n_fft]
        cos_out = F.conv1d(flat, self.cos_b)  # [B*n_frames, n_freqs, 1]
        sin_out = F.conv1d(flat, self.sin_b)  # [B*n_frames, n_freqs, 1]
        power = (cos_out ** 2 + sin_out ** 2).squeeze(-1)  # [B*n_frames, n_freqs]

        # Mel filterbank — power * fb^T
        mel = power @ self.mel_fb.t()  # [B*n_frames, n_mels]
        n_frames = frames.shape[1]
        mel = mel.reshape(B, n_frames, -1)  # [B, n_frames, n_mels]

        # log with float32-epsilon floor (Kaldi default).
        mel = torch.log(torch.clamp(mel, min=self.log_floor))
        return mel


def build_speaker_encoder():
    """raw audio [1, T] → 192-dim L2-normalised ECAPA embedding."""
    import torch
    import torch.nn as nn
    from onnx2torch import convert

    ecapa_pt = convert(str(fetch_ecapa_onnx()))
    ecapa_pt.eval()

    fbank = KaldiFbank80()
    fbank.eval()

    class SpeakerEncoder(nn.Module):
        def __init__(self, fbank, ecapa):
            super().__init__()
            self.fbank = fbank
            self.ecapa = ecapa

        def forward(self, wav):
            feats = self.fbank(wav)  # [1, T_frames, 80]
            emb = self.ecapa(feats)  # [1, 192]
            return emb / torch.norm(emb, dim=1, keepdim=True)

    enc = SpeakerEncoder(fbank, ecapa_pt)
    enc.eval()
    return enc


def build_models():
    import torch
    import torch.nn as nn
    import torch.nn.functional as F
    from asteroid.models import ConvTasNet
    from onnx2torch import convert

    ecapa_pt = convert(str(fetch_ecapa_onnx()))
    ecapa_pt.eval()

    fbank = KaldiFbank80()
    fbank.eval()

    class TSEExtract(nn.Module):
        """Combined: separate → embed each source → cosine-pick the target."""

        def __init__(self, separator, fbank, ecapa):
            super().__init__()
            self.sep = separator
            self.fbank = fbank
            self.ecapa = ecapa

        def _embed(self, wav):
            feats = self.fbank(wav)
            emb = self.ecapa(feats)
            return emb / torch.norm(emb, dim=1, keepdim=True)

        def forward(self, mixed, ref_embedding):
            sources = self.sep(mixed)  # [1, 2, T]
            src0, src1 = sources[:, 0, :], sources[:, 1, :]
            emb0 = self._embed(src0)
            emb1 = self._embed(src1)
            sim0 = F.cosine_similarity(ref_embedding, emb0, dim=1)
            sim1 = F.cosine_similarity(ref_embedding, emb1, dim=1)
            sim = torch.stack([sim0, sim1], dim=1)         # [1, 2]
            best = sim.max(dim=1, keepdim=True).values     # [1, 1]
            w = (sim >= best).float()                      # [1, 2]
            picked = w[:, 0:1] * src0 + w[:, 1:2] * src1   # [1, T]
            # JorisCos ConvTasNet was trained with SI-SDR loss → output is
            # scale-invariant (any amplitude). Recover absolute scale by
            # projecting onto the input mixture: alpha minimises ‖mixed − α·picked‖².
            num = (picked * mixed).sum(dim=-1, keepdim=True)
            den = (picked * picked).sum(dim=-1, keepdim=True) + 1e-9
            return (num / den) * picked                     # [1, T]

    print("Loading ConvTasNet separator (Libri2Mix sep_noisy 16k)...")
    separator = ConvTasNet.from_pretrained("JorisCos/ConvTasNet_Libri2Mix_sepnoisy_16k")
    separator.eval()

    model = TSEExtract(separator, fbank, ecapa_pt)
    model.eval()
    return model


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--out", default="core/build/models/tse_model.onnx")
    p.add_argument("--validate", action="store_true")
    args = p.parse_args()

    import torch

    models_dir = os.path.dirname(os.path.abspath(args.out))
    os.makedirs(models_dir, exist_ok=True)

    # Combined TSE model
    model = build_models()
    T = 32000  # 2 s at 16 kHz
    mixed = torch.randn(1, T)
    ref_emb = torch.randn(1, EMBED_DIM)
    ref_emb = ref_emb / torch.norm(ref_emb, dim=1, keepdim=True)

    print(f"Exporting TSE model to {args.out}...")
    torch.onnx.export(
        model,
        (mixed, ref_emb),
        args.out,
        input_names=["mixed", "ref_embedding"],
        output_names=["extracted"],
        dynamic_axes={"mixed": {1: "T"}, "extracted": {1: "T"}},
        opset_version=17,
        dynamo=False,
    )
    print(f"TSE model: {os.path.getsize(args.out) / 1e6:.1f} MB")

    # Standalone speaker encoder (used by compute_enrollment_embedding.py)
    enc_path = os.path.join(models_dir, "speaker_encoder.onnx")
    enc = build_speaker_encoder()
    wav_dummy = torch.randn(1, 32000)
    print(f"Exporting speaker encoder to {enc_path}...")
    torch.onnx.export(
        enc,
        wav_dummy,
        enc_path,
        input_names=["audio"],
        output_names=["embedding"],
        dynamic_axes={"audio": {1: "T"}},
        opset_version=17,
        dynamo=False,
    )
    print(f"Speaker encoder: {os.path.getsize(enc_path) / 1e6:.1f} MB")

    if args.validate:
        import numpy as np
        import onnxruntime as ort

        sess = ort.InferenceSession(args.out)
        r = sess.run(["extracted"], {
            "mixed": mixed.numpy(),
            "ref_embedding": ref_emb.numpy(),
        })
        assert r[0].shape == (1, T), f"unexpected shape: {r[0].shape}"
        sess_e = ort.InferenceSession(enc_path)
        e = sess_e.run(["embedding"], {"audio": wav_dummy.numpy()})[0]
        assert e.shape == (1, EMBED_DIM), f"unexpected emb shape: {e.shape}"
        norm = float(np.linalg.norm(e))
        assert abs(norm - 1.0) < 1e-3, f"emb not L2-normalised: norm={norm}"
        print("Validation passed.")


if __name__ == "__main__":
    main()
