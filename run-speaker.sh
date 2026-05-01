#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MODELS_DIR="$SCRIPT_DIR/core/build/models"
PROFILE_DIR="${HOME}/.config/voice-keyboard"
DICT="${DICT_PATH:-}"
ONNX_LIB="${ONNXRUNTIME_LIB_PATH:-/opt/homebrew/lib/libonnxruntime.dylib}"

# TSE backend selection. Precedence: env var TSE_BACKEND > positional arg > default.
# Examples:
#   ./run-speaker.sh                  → uses default (ecapa)
#   ./run-speaker.sh ecapa            → ecapa
#   TSE_BACKEND=ecapa ./run-speaker.sh
TSE_BACKEND="${TSE_BACKEND:-${1:-ecapa}}"

if [ -f "$SCRIPT_DIR/.env" ]; then
  set -a; . "$SCRIPT_DIR/.env"; set +a
fi

# Check enrollment
if [[ ! -f "$PROFILE_DIR/speaker.json" ]]; then
  echo "No voice enrollment found. Run ./enroll.sh first."
  exit 1
fi

# Build vkb-cli
echo "Building vkb-cli..."
(cd "$SCRIPT_DIR/core" && go build -tags whispercpp -o build/vkb-cli ./cmd/vkb-cli/)

FIFO=$(mktemp -t vkb-speaker-XXXXX)
rm -f "$FIFO"
mkfifo "$FIFO"
trap 'rm -f "$FIFO"' EXIT

ONNXRUNTIME_LIB_PATH="$ONNX_LIB" \
VKB_PROFILE_DIR="$PROFILE_DIR" \
VKB_MODELS_DIR="$MODELS_DIR" \
  "$SCRIPT_DIR/core/build/vkb-cli" pipe \
  ${DICT:+--dict "$DICT"} \
  --live \
  --latency-report \
  --speaker \
  --tse-backend "$TSE_BACKEND" \
  < "$FIFO" &
PID=$!
exec 3>"$FIFO"

echo ""
echo "🎙  Recording (TSE active: backend=$TSE_BACKEND) — press any key to stop, 'q' to cancel."
echo ""

while IFS= read -rsn1 key; do
  if [[ "$key" == "q" ]]; then
    echo "cancel" >&3
  else
    echo "" >&3
  fi
  break
done
exec 3>&-
wait "$PID"
