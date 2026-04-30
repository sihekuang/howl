#!/usr/bin/env python3
"""
Export a speaker encoder to ONNX for voice-keyboard speaker gating.

Model: resemblyzer GE2E LSTM (trained for speaker verification) with a
STFT-free mel spectrogram front-end (conv1d Hann-windowed basis functions)
that is fully ONNX-traceable.

Input:  audio  float32[1, T]  — 16kHz mono PCM
Output: embedding float32[1, 256] — L2-normalised speaker embedding

Usage:
    python scripts/export_tse_model.py --out core/build/models/tse_model.onnx
"""

import argparse
import os
import warnings

warnings.filterwarnings("ignore")


def make_mel_filterbank(sr=16000, n_fft=400, n_mels=40, fmax=8000.0):
    """HTK-scale mel filterbank [n_mels, n_fft//2+1] matching librosa defaults."""
    import numpy as np

    n_freqs = n_fft // 2 + 1
    freq = np.linspace(0, sr / 2, n_freqs)
    mel_min = 2595 * np.log10(1 + 0 / 700)
    mel_max = 2595 * np.log10(1 + fmax / 700)
    mel_pts = np.linspace(mel_min, mel_max, n_mels + 2)
    hz_pts = 700 * (10 ** (mel_pts / 2595) - 1)
    fb = np.zeros((n_mels, n_freqs), dtype="float32")
    for m in range(n_mels):
        lo, ctr, hi = hz_pts[m], hz_pts[m + 1], hz_pts[m + 2]
        for k, f in enumerate(freq):
            if lo <= f <= ctr:
                fb[m, k] = (f - lo) / (ctr - lo)
            elif ctr < f <= hi:
                fb[m, k] = (hi - f) / (hi - ctr)
    return fb


def build_model():
    import torch
    import torch.nn as nn
    import torch.nn.functional as F
    import numpy as np
    from resemblyzer import VoiceEncoder

    class MelSpecConv(nn.Module):
        """STFT-free mel spectrogram via fixed conv1d kernels — fully ONNX-traceable.
        Input: [1, T] float32.  Output: [1, n_frames, n_mels]."""

        def __init__(self, n_fft=400, hop=160, n_mels=40, sr=16000, fmax=8000.0):
            super().__init__()
            self.hop = hop
            self.n_fft = n_fft
            window = torch.hann_window(n_fft)
            n = torch.arange(n_fft, dtype=torch.float32)
            freqs = torch.arange(n_fft // 2 + 1, dtype=torch.float32)
            cos_b = (window * torch.cos(2 * np.pi * freqs[:, None] * n[None, :] / n_fft)).unsqueeze(1)
            sin_b = (window * torch.sin(2 * np.pi * freqs[:, None] * n[None, :] / n_fft)).unsqueeze(1)
            self.register_buffer("cos_b", cos_b)
            self.register_buffer("sin_b", sin_b)
            fb = torch.from_numpy(make_mel_filterbank(sr, n_fft, n_mels, fmax))
            self.register_buffer("fb", fb)

        def forward(self, wav: torch.Tensor) -> torch.Tensor:
            x = wav.unsqueeze(1)
            x = F.pad(x, (self.n_fft // 2, self.n_fft // 2), mode="reflect")
            cos_out = F.conv1d(x, self.cos_b, stride=self.hop)
            sin_out = F.conv1d(x, self.sin_b, stride=self.hop)
            power = cos_out ** 2 + sin_out ** 2
            mel = torch.matmul(self.fb, power.squeeze(0))
            return mel.T.unsqueeze(0)  # [1, n_frames, n_mels]

    class SpeakerEncoder(nn.Module):
        """Raw 16kHz audio [1, T] → L2-normalised speaker embedding [1, 256]."""

        def __init__(self, voice_enc):
            super().__init__()
            self.mel = MelSpecConv()
            self.lstm = voice_enc.lstm
            self.linear = voice_enc.linear
            self.relu = voice_enc.relu

        def forward(self, wav: torch.Tensor) -> torch.Tensor:
            mel = self.mel(wav)
            _, (h, _) = self.lstm(mel)
            raw = self.relu(self.linear(h[-1]))
            return raw / torch.norm(raw, dim=1, keepdim=True)

    print("Loading resemblyzer GE2E voice encoder...")
    voice_enc = VoiceEncoder()
    voice_enc.eval()
    model = SpeakerEncoder(voice_enc)
    model.eval()
    return model


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--out", default="core/build/models/tse_model.onnx")
    p.add_argument("--validate", action="store_true")
    args = p.parse_args()

    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)

    import torch

    model = build_model()
    wav_dummy = torch.randn(1, 32000)

    print(f"Exporting to {args.out}...")
    torch.onnx.export(
        model,
        wav_dummy,
        args.out,
        input_names=["audio"],
        output_names=["embedding"],
        dynamic_axes={"audio": {1: "T"}},
        opset_version=17,
        dynamo=False,
    )
    size_mb = os.path.getsize(args.out) / 1e6
    print(f"Export complete. ({size_mb:.1f} MB)")

    if args.validate:
        import numpy as np
        import onnxruntime as ort

        sess = ort.InferenceSession(args.out)
        rng = np.random.default_rng(42)

        def voiced(f0, dur=3.0):
            t = np.arange(int(dur * 16000)) / 16000
            s = sum(np.sin(2 * np.pi * f0 * k * t) / k for k in range(1, 12))
            return (s + rng.normal(0, 0.05, len(t))).astype(np.float32)

        def embed(wav):
            return sess.run(["embedding"], {"audio": wav[np.newaxis]})[0].flatten()

        ea1 = embed(voiced(120))
        ea2 = embed(voiced(123))
        eb = embed(voiced(220))
        cos = lambda a, b: float(np.dot(a, b) / (np.linalg.norm(a) * np.linalg.norm(b)))
        same = cos(ea1, ea2)
        diff = cos(ea1, eb)
        print(f"Validation: same-speaker={same:.3f}  diff-speaker={diff:.3f}")
        assert same > diff + 0.2, f"poor speaker discrimination: {same:.3f} vs {diff:.3f}"
        print("Validation passed.")


if __name__ == "__main__":
    main()
