#!/usr/bin/env python3
"""
Compute a speaker embedding from enrollment.wav using the exported ONNX model
and save it as enrollment.emb (raw float32 little-endian binary, 256 values).

Usage:
    python scripts/compute_enrollment_embedding.py \
        --model  core/build/models/tse_model.onnx \
        --wav    ~/.config/voice-keyboard/enrollment.wav \
        --out    ~/.config/voice-keyboard/enrollment.emb
"""

import argparse
import struct


def read_wav_float32(path):
    """Read a WAV file and return float32 samples.
    Uses manual binary parsing to support IEEE float WAV (AudioFormat=3)
    which Python's wave module rejects."""
    import numpy as np

    with open(path, "rb") as f:
        data = f.read()

    # Parse RIFF header manually
    assert data[:4] == b"RIFF" and data[8:12] == b"WAVE", "not a WAV file"

    i = 12
    fmt_tag = num_channels = sample_rate = bits = 0
    audio_data = b""
    while i < len(data):
        chunk_id = data[i:i+4]
        chunk_size = struct.unpack_from("<I", data, i+4)[0]
        chunk_data = data[i+8:i+8+chunk_size]
        if chunk_id == b"fmt ":
            fmt_tag, num_channels, sample_rate = struct.unpack_from("<HHI", chunk_data)
            bits = struct.unpack_from("<H", chunk_data, 14)[0]
        elif chunk_id == b"data":
            audio_data = chunk_data
        i += 8 + chunk_size

    n = len(audio_data) // (bits // 8)
    if fmt_tag == 3 and bits == 32:  # IEEE float
        samples = np.frombuffer(audio_data, dtype="<f4").copy()
    elif fmt_tag == 1 and bits == 16:  # PCM int16
        pcm = np.frombuffer(audio_data, dtype="<i2")
        samples = pcm.astype(np.float32) / 32768.0
    else:
        raise ValueError(f"unsupported WAV format tag={fmt_tag} bits={bits}")

    if num_channels > 1:
        samples = samples[::num_channels]

    return samples.astype(np.float32)


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--model", required=True)
    p.add_argument("--wav", required=True)
    p.add_argument("--out", required=True)
    args = p.parse_args()

    import numpy as np
    import onnxruntime as ort

    wav = read_wav_float32(args.wav)
    print(f"Loaded {args.wav}: {len(wav)/16000:.2f}s, {len(wav)} samples")

    sess = ort.InferenceSession(args.model)
    embedding = sess.run(["embedding"], {"audio": wav[np.newaxis]})[0].flatten()
    print(f"Embedding shape: {embedding.shape}, norm: {np.linalg.norm(embedding):.4f}")

    with open(args.out, "wb") as f:
        f.write(struct.pack(f"<{len(embedding)}f", *embedding))
    print(f"Saved embedding → {args.out}")


if __name__ == "__main__":
    main()
