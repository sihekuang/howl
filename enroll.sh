#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MODELS_DIR="$SCRIPT_DIR/core/build/models"
PROFILE_DIR="${HOME}/.config/voice-keyboard"
ONNX_LIB="${ONNXRUNTIME_LIB_PATH:-/opt/homebrew/lib/libonnxruntime.dylib}"
SILERO_URL="https://github.com/snakers4/silero-vad/raw/master/files/silero_vad.onnx"

mkdir -p "$MODELS_DIR" "$PROFILE_DIR"

# Download Silero VAD model if missing
if [[ ! -f "$MODELS_DIR/silero_vad.onnx" ]]; then
  echo "Downloading silero_vad.onnx..."
  curl -L -o "$MODELS_DIR/silero_vad.onnx" "$SILERO_URL"
fi

# Build tse_model.onnx + speaker_encoder.onnx if missing
if [[ ! -f "$MODELS_DIR/tse_model.onnx" ]] || [[ ! -f "$MODELS_DIR/speaker_encoder.onnx" ]]; then
  echo "Building tse_model.onnx (requires Python 3.12, PyTorch, asteroid)..."
  PYTHON312="${PYTHON312:-$(command -v python3.12 2>/dev/null)}"
  if [[ -z "$PYTHON312" ]]; then
    echo "ERROR: python3.12 not found. Install with: brew install python@3.12"
    exit 1
  fi
  VENV="$SCRIPT_DIR/core/build/.venv-tse"
  # Recreate venv if it's not running Python 3.12
  if [[ -d "$VENV" ]] && ! "$VENV/bin/python" --version 2>&1 | grep -q "3\.12"; then
    echo "Recreating venv (wrong Python version)..."
    rm -rf "$VENV"
  fi
  if [[ ! -d "$VENV" ]]; then
    "$PYTHON312" -m venv "$VENV"
  fi
  "$VENV/bin/pip" install --quiet torch asteroid requests onnxscript onnxruntime onnx onnx2torch soundfile numpy
  "$VENV/bin/python" "$SCRIPT_DIR/scripts/export_tse_model.py" --out "$MODELS_DIR/tse_model.onnx"
fi

# Build vkb-enroll
echo "Building vkb-enroll..."
(cd "$SCRIPT_DIR/core" && go build -o build/vkb-enroll ./cmd/enroll/)

echo ""
echo "🎙  Speak naturally for 10 seconds — press Ctrl+C to stop early."
echo ""

ONNXRUNTIME_LIB_PATH="$ONNX_LIB" \
  "$SCRIPT_DIR/core/build/vkb-enroll" \
  --duration=10s \
  --out="$PROFILE_DIR"

# Compute and save the speaker embedding from the just-recorded WAV
echo "Computing speaker embedding..."
VENV="$SCRIPT_DIR/core/build/.venv-tse"
"$VENV/bin/python" "$SCRIPT_DIR/scripts/compute_enrollment_embedding.py" \
  --model "$MODELS_DIR/speaker_encoder.onnx" \
  --wav   "$PROFILE_DIR/enrollment.wav" \
  --out   "$PROFILE_DIR/enrollment.emb"

echo ""
echo "✓ Voice enrolled. Run ./run-speaker.sh to test."
