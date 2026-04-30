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

# Build tse_model.onnx if missing (requires Python + PyTorch + asteroid)
if [[ ! -f "$MODELS_DIR/tse_model.onnx" ]]; then
  echo "Building tse_model.onnx (requires Python, PyTorch, asteroid-filterbanks)..."
  if ! command -v python3 &>/dev/null; then
    echo "ERROR: python3 not found. Install Python 3.10+ and re-run."
    exit 1
  fi
  VENV="$SCRIPT_DIR/core/build/.venv-tse"
  if [[ ! -d "$VENV" ]]; then
    python3 -m venv "$VENV"
  fi
  "$VENV/bin/pip" install --quiet torch asteroid-filterbanks soundfile numpy
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

echo ""
echo "✓ Voice enrolled. Run ./run-speaker.sh to test."
