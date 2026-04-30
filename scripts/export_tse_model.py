#!/usr/bin/env python3
"""
Export the combined TSE model to ONNX.

Architecture:
  1. ConvTasNet (mpariente/ConvTasNet_WHAM!_sepclean) separates mixed audio
     into 2 sources.
  2. Resemblyzer GE2E LSTM embeds each source (conv1d mel front-end for
     ONNX traceability).
  3. Soft-select the source whose embedding is closest to the enrolled
     speaker embedding (sharp softmax — no hard indexing, fully traceable).

Inputs:  mixed         float32[1, T]   — 16kHz mono mixed audio
         ref_embedding float32[1, 256] — L2-normalised enrolled speaker embedding
Output:  extracted     float32[1, T]   — separated audio for the enrolled speaker

The enrollment embedding is precomputed once by compute_enrollment_embedding.py
(which uses speaker_encoder.onnx) and saved as enrollment.emb.

Usage:
    python scripts/export_tse_model.py --out core/build/models/tse_model.onnx
"""

import argparse
import os
import warnings

warnings.filterwarnings("ignore")


def make_mel_filterbank(sr=16000, n_fft=400, n_mels=40, fmax=8000.0):
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


def build_models():
    import numpy as np
    import torch
    import torch.nn as nn
    import torch.nn.functional as F
    from asteroid.models import ConvTasNet
    from resemblyzer import VoiceEncoder

    class MelSpecConv(nn.Module):
        """STFT-free mel spectrogram via fixed conv1d — ONNX-traceable."""

        def __init__(self, n_fft=400, hop=160, n_mels=40, sr=16000, fmax=8000.0):
            super().__init__()
            self.hop, self.n_fft = hop, n_fft
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

    class TSEExtract(nn.Module):
        """
        Combined TSE: separate → identify → return target speaker's audio.

        1. ConvTasNet splits mixed into 2 sources.
        2. Resemblyzer encoder embeds each source.
        3. Soft-selects the source closest to ref_embedding.
        """

        def __init__(self, separator, voice_enc):
            super().__init__()
            self.sep = separator
            self.mel = MelSpecConv()
            self.lstm = voice_enc.lstm
            self.linear = voice_enc.linear
            self.relu = voice_enc.relu

        def _embed(self, wav: torch.Tensor) -> torch.Tensor:
            mel = self.mel(wav)
            _, (h, _) = self.lstm(mel)
            raw = self.relu(self.linear(h[-1]))
            return raw / torch.norm(raw, dim=1, keepdim=True)  # [1, 256]

        def forward(self, mixed: torch.Tensor, ref_embedding: torch.Tensor) -> torch.Tensor:
            sources = self.sep(mixed)  # [1, 2, T]
            src0, src1 = sources[:, 0, :], sources[:, 1, :]
            emb0, emb1 = self._embed(src0), self._embed(src1)
            sim0 = F.cosine_similarity(ref_embedding, emb0, dim=1)
            sim1 = F.cosine_similarity(ref_embedding, emb1, dim=1)
            # Hard select: weight the winner 1.0, loser 0.0
            sim = torch.stack([sim0, sim1], dim=1)        # [1, 2]
            best = sim.max(dim=1, keepdim=True).values    # [1, 1]
            w = (sim >= best).float()                      # [1, 2] — 1 for winner, 0 for loser
            return w[:, 0:1] * src0 + w[:, 1:2] * src1  # [1, T]

    print("Loading ConvTasNet separator...")
    separator = ConvTasNet.from_pretrained("mpariente/ConvTasNet_WHAM!_sepclean")
    separator.eval()

    print("Loading resemblyzer GE2E encoder...")
    voice_enc = VoiceEncoder()
    voice_enc.eval()

    model = TSEExtract(separator, voice_enc)
    model.eval()
    return model


def build_speaker_encoder():
    """Also export a standalone speaker encoder for computing enrollment embeddings."""
    import numpy as np
    import torch
    import torch.nn as nn
    import torch.nn.functional as F
    from resemblyzer import VoiceEncoder

    class MelSpecConv(nn.Module):
        def __init__(self, n_fft=400, hop=160, n_mels=40, sr=16000, fmax=8000.0):
            super().__init__()
            self.hop, self.n_fft = hop, n_fft
            window = torch.hann_window(n_fft)
            n = torch.arange(n_fft, dtype=torch.float32)
            freqs = torch.arange(n_fft // 2 + 1, dtype=torch.float32)
            cos_b = (window * torch.cos(2 * np.pi * freqs[:, None] * n[None, :] / n_fft)).unsqueeze(1)
            sin_b = (window * torch.sin(2 * np.pi * freqs[:, None] * n[None, :] / n_fft)).unsqueeze(1)
            self.register_buffer("cos_b", cos_b)
            self.register_buffer("sin_b", sin_b)
            fb = torch.from_numpy(make_mel_filterbank(sr, n_fft, n_mels, fmax))
            self.register_buffer("fb", fb)

        def forward(self, wav):
            x = wav.unsqueeze(1)
            x = F.pad(x, (self.n_fft // 2, self.n_fft // 2), mode="reflect")
            cos_out = F.conv1d(x, self.cos_b, stride=self.hop)
            sin_out = F.conv1d(x, self.sin_b, stride=self.hop)
            power = cos_out ** 2 + sin_out ** 2
            mel = torch.matmul(self.fb, power.squeeze(0))
            return mel.T.unsqueeze(0)

    class SpeakerEncoder(nn.Module):
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

    voice_enc = VoiceEncoder()
    voice_enc.eval()
    enc = SpeakerEncoder(voice_enc)
    enc.eval()
    return enc


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--out", default="core/build/models/tse_model.onnx")
    p.add_argument("--validate", action="store_true")
    args = p.parse_args()

    import torch

    models_dir = os.path.dirname(os.path.abspath(args.out))
    os.makedirs(models_dir, exist_ok=True)

    # Export combined TSE model
    model = build_models()
    T = 32000
    mixed = torch.randn(1, T)
    ref_emb = torch.randn(1, 256)
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
    print(f"TSE model: {os.path.getsize(args.out)/1e6:.1f} MB")

    # Export standalone speaker encoder (used by compute_enrollment_embedding.py)
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
    print(f"Speaker encoder: {os.path.getsize(enc_path)/1e6:.1f} MB")

    if args.validate:
        import numpy as np
        import onnxruntime as ort

        sess = ort.InferenceSession(args.out)
        r = sess.run(["extracted"], {
            "mixed": mixed.numpy(),
            "ref_embedding": ref_emb.numpy(),
        })
        assert r[0].shape == (1, T), f"unexpected shape: {r[0].shape}"
        print("Validation passed.")


if __name__ == "__main__":
    main()
