#!/usr/bin/env python3
"""
Export SpeakerBeam-SS from Asteroid to a single ONNX model.
Inputs:  mixed     float32[1, T]  — mixed audio at 16kHz
         ref_audio float32[1, R]  — enrollment audio at 16kHz
Output:  output    float32[1, T]  — extracted target-speaker audio

Usage:
    python scripts/export_tse_model.py --out core/build/models/tse_model.onnx
"""

import argparse
import os
import numpy as np
import torch
import torch.nn as nn


def get_args():
    p = argparse.ArgumentParser()
    p.add_argument("--out", default="core/build/models/tse_model.onnx")
    p.add_argument("--validate", action="store_true")
    return p.parse_args()


class SpeakerBeamWrapper(nn.Module):
    """Wraps SpeakerBeam-SS so it takes (mixed, ref_audio) and returns extracted audio."""

    def __init__(self, model):
        super().__init__()
        self.model = model

    def forward(self, mixed: torch.Tensor, ref_audio: torch.Tensor) -> torch.Tensor:
        # Extract speaker embedding from ref_audio using the model's encoder
        ref_emb = self.model.encoder(ref_audio)  # [1, D]
        # Separate using mixed + embedding
        est = self.model(mixed, ref_emb)
        return est


def main():
    args = get_args()
    os.makedirs(os.path.dirname(args.out), exist_ok=True)

    print("Loading SpeakerBeam-SS from Asteroid hub...")
    try:
        from asteroid.models import SpeakerBeam
        model = SpeakerBeam.from_pretrained("mpariente/SpeakerBeam-WHAM-oracle")
    except Exception as e:
        print(f"Could not load from hub: {e}")
        print("Install asteroid: pip install asteroid-filterbanks")
        raise

    model.eval()
    wrapper = SpeakerBeamWrapper(model)

    # Dummy inputs for tracing
    T = 16000  # 1s mixed
    R = 16000  # 1s reference
    mixed = torch.randn(1, T)
    ref_audio = torch.randn(1, R)

    print(f"Exporting to {args.out}...")
    torch.onnx.export(
        wrapper,
        (mixed, ref_audio),
        args.out,
        input_names=["mixed", "ref_audio"],
        output_names=["output"],
        dynamic_axes={
            "mixed":     {1: "T"},
            "ref_audio": {1: "R"},
            "output":    {1: "T"},
        },
        opset_version=17,
    )
    print("Export complete.")

    if args.validate:
        import onnxruntime as ort
        sess = ort.InferenceSession(args.out)
        out = sess.run(
            ["output"],
            {"mixed": mixed.numpy(), "ref_audio": ref_audio.numpy()},
        )
        assert out[0].shape == (1, T), f"unexpected output shape: {out[0].shape}"
        print("Validation passed.")


if __name__ == "__main__":
    main()
