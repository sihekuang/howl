"""Export pyannote/segmentation-3.0 to ONNX.

Output names + shapes MUST match core/internal/speaker/diarmask_pyannote.go:
  input  "waveform"     [1, 1, 160000]   (10 s @ 16 kHz mono)
  output "segmentation" [1, num_frames, 7]  (powerset, 7 classes)

Auth: reads the cached HuggingFace token (~/.cache/huggingface/token) written
by `huggingface-cli login`. The token is never passed on the command line.

Usage: python export-pyannote-seg.py OUTPUT.onnx
"""
import sys
import torch
from pyannote.audio import Model

OUT = sys.argv[1] if len(sys.argv) > 1 else "pyannote_seg.onnx"


def load_model():
    # huggingface_hub renamed the auth kwarg across versions; try the known
    # forms, then fall back to the cached-token default (no kwarg).
    last = None
    for kwargs in ({"use_auth_token": True}, {"token": True}, {}):
        try:
            return Model.from_pretrained("pyannote/segmentation-3.0", **kwargs)
        except TypeError as e:  # unexpected kwarg for this version
            last = e
            continue
    raise last


def main():
    model = load_model()
    model.eval()
    dummy = torch.zeros(1, 1, 160000)
    torch.onnx.export(
        model, dummy, OUT,
        input_names=["waveform"], output_names=["segmentation"],
        dynamic_axes={"segmentation": {1: "num_frames"}},
        opset_version=17,
        # torch 2.12's default "dynamo" exporter fails on SincNet's learnable
        # filterbank (aten::clamp with a FakeTensor min). Force the legacy
        # TorchScript exporter, which traces concretely and handles SincNet.
        dynamo=False,
    )
    print("wrote", OUT)

    # Shape-contract self-check.
    import onnx
    m = onnx.load(OUT)
    onnx.checker.check_model(m)
    g = m.graph

    def shape(t):
        return [d.dim_value or d.dim_param for d in t.type.tensor_type.shape.dim]

    print("inputs: ", [(i.name, shape(i)) for i in g.input])
    print("outputs:", [(o.name, shape(o)) for o in g.output])


if __name__ == "__main__":
    main()
