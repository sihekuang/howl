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

# Check that tse_model.onnx exists (produced by scripts/export_tse_model.py)
if [[ ! -f "$MODELS_DIR/tse_model.onnx" ]]; then
  echo "ERROR: $MODELS_DIR/tse_model.onnx not found."
  echo "Run: python scripts/export_tse_model.py --out $MODELS_DIR/tse_model.onnx"
  exit 1
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
