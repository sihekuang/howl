# Building pyannote-seg ONNX

The `pyannoteSegmenter` (diar_mask) expects an ONNX export of
`pyannote/segmentation-3.0` at the path passed via `PYANNOTE_SEG_PATH`.
Day-to-day contributors don't need this — `diar_mask` `t.Skip`s without it.

## Prerequisites
- Python 3.10–3.12 (3.13+ not yet supported by torch/pyannote as of 2026-06)
- HuggingFace token with access to `pyannote/segmentation-3.0` (gated; accept the
  EULA), cached via `huggingface-cli login` — the script reads the cache, so no
  token goes on the command line
- `pip install pyannote.audio onnx onnxruntime torch torchaudio onnxscript`
  (`onnxscript` is imported by torch's ONNX exporter on torch ≥ 2.9, even for the
  legacy path)

## Export script

The maintained copy is committed at `core/scripts/export-pyannote-seg.py` — run it
with `python core/scripts/export-pyannote-seg.py OUT.onnx`. For reference:

```python
"""Export pyannote/segmentation-3.0 to ONNX.

Output names + shapes MUST match core/internal/speaker/diarmask_pyannote.go:
  input  "waveform"     [1, 1, 160000]   (10 s @ 16 kHz mono)
  output "segmentation" [1, num_frames, 7]  (powerset, 7 classes)
"""
import os, torch
from pyannote.audio import Model

# use_auth_token=True reads the token cached by `huggingface-cli login`.
model = Model.from_pretrained("pyannote/segmentation-3.0", use_auth_token=True)
model.eval()

dummy = torch.zeros(1, 1, 160000)
torch.onnx.export(
    model, dummy, "pyannote_seg.onnx",
    input_names=["waveform"], output_names=["segmentation"],
    dynamic_axes={"segmentation": {1: "num_frames"}},
    opset_version=17,
    dynamo=False,  # torch>=2.9: the new dynamo exporter fails on SincNet's
                   # learnable filterbank (aten::clamp w/ a FakeTensor min);
                   # the legacy TorchScript exporter traces it concretely.
)
print("wrote pyannote_seg.onnx")
```

## Verify

The 7 output classes are, in order: non-speech, spk1, spk2, spk3, spk1+2,
spk1+3, spk2+3 (max 2 simultaneous speakers). `powersetToActivity` in
`diarmask.go` depends on this exact ordering — re-check it on any model upgrade.

## Place the model

Drop `pyannote_seg.onnx` at `core/build/models/pyannote_seg.onnx` or point
`PYANNOTE_SEG_PATH` at it, then run:

    PYANNOTE_SEG_PATH=/path/to/pyannote_seg.onnx \
    SPEAKER_ENCODER_PATH=/path/to/speaker_encoder.onnx \
    WHISPER_MODEL_PATH=/path/to/ggml-small.bin \
    go test -tags 'cleanupeval whispercpp' ./core/internal/speaker/ -run TestCleanup_Matrix -v
