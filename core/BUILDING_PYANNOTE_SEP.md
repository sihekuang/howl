# Building pyannote-sep ONNX

The `PyannoteSepECAPA` cleanup adapter expects an ONNX export of
`pyannote/speech-separation-ami-1.0` at the path passed via
`PYANNOTE_SEP_PATH`. This document describes how to produce that
artifact. Day-to-day contributors don't need to run this — the
adapter `t.Skip`s cleanly without the model.

## Prerequisites
- Python 3.10+
- HuggingFace token with access to `pyannote/speech-separation-ami-1.0`
  (the model is gated; accept the EULA on the HF page first)
- `pip install pyannote.audio onnx onnxruntime torch torchaudio`

## Export script

Save as `scripts/export-pyannote-sep.py`:

```python
"""Export pyannote/speech-separation-ami-1.0 to ONNX.

Run once per upstream release; commit the resulting ONNX out-of-tree
(it's ~50 MB; bundle via the build pipeline rather than git LFS).
"""
import os
import torch
from pyannote.audio import Pipeline

HF_TOKEN = os.environ["HF_TOKEN"]
OUT = "pyannote_sep.onnx"

pipeline = Pipeline.from_pretrained(
    "pyannote/speech-separation-ami-1.0",
    use_auth_token=HF_TOKEN,
)
# pyannote pipelines are composite; we want only the separator
# submodel for the ONNX export.
separator = pipeline._model  # PixIT separator
separator.eval()

# Trace at a fixed input length (10 s at 16 kHz). Variable-length
# tracing is possible but pyannote's separator was trained on
# fixed windows, so a fixed export matches its training distribution.
dummy = torch.zeros(1, 16000 * 10)
torch.onnx.export(
    separator,
    dummy,
    OUT,
    input_names=["mixed"],
    output_names=["sources"],
    dynamic_axes={"mixed": {1: "T"}, "sources": {2: "T"}},
    opset_version=17,
)
print(f"Wrote {OUT}")
```

## Steps

1. Install Python dependencies:
   ```bash
   pip install pyannote.audio onnx onnxruntime torch torchaudio
   ```
2. Accept the model EULA at https://huggingface.co/pyannote/speech-separation-ami-1.0
3. Set your HF token:
   ```bash
   export HF_TOKEN=hf_your_token_here
   ```
4. Run the export:
   ```bash
   python scripts/export-pyannote-sep.py
   ```
5. The output `pyannote_sep.onnx` (~50 MB) lands in the working
   directory. Move it to `core/build/models/pyannote_sep.onnx` (or
   wherever `PYANNOTE_SEP_PATH` points).

## Verifying the export

Quick load test:
```bash
python -c "import onnxruntime as ort; ort.InferenceSession('pyannote_sep.onnx')"
```
Should print no errors.

Run the harness with the model loaded:
```bash
cd core
PYANNOTE_SEP_PATH=$PWD/build/models/pyannote_sep.onnx \
  go test -tags cleanupeval -v -run TestPyannoteSepECAPA_LoadsWhenPresent \
  ./internal/speaker/...
```
Expected: PASS (the load-when-present test runs end-to-end inference).
