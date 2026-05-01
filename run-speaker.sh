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

# LLM provider + model selection (env vars only — keep flag space simple).
# LLM_PROVIDER empty → vkb-cli default ("anthropic").
# LLM_MODEL    empty → provider's default (anthropic: claude-sonnet-4-6;
#                                          ollama: must specify).
# LLM_BASE_URL empty → provider's default (e.g. http://localhost:11434 for ollama).
# Examples:
#   LLM_PROVIDER=ollama LLM_MODEL=llama3.2 ./run-speaker.sh
#   LLM_PROVIDER=ollama LLM_MODEL=qwen2.5 LLM_BASE_URL=http://10.0.0.5:11434 ./run-speaker.sh
LLM_PROVIDER="${LLM_PROVIDER:-}"
LLM_MODEL="${LLM_MODEL:-}"
LLM_BASE_URL="${LLM_BASE_URL:-}"

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
  ${LLM_PROVIDER:+--llm-provider "$LLM_PROVIDER"} \
  ${LLM_MODEL:+--llm-model "$LLM_MODEL"} \
  ${LLM_BASE_URL:+--llm-base-url "$LLM_BASE_URL"} \
  < "$FIFO" &
PID=$!
exec 3>"$FIFO"

echo ""
echo "🎙  Recording (TSE backend=$TSE_BACKEND, LLM provider=${LLM_PROVIDER:-default}, model=${LLM_MODEL:-default}) — press any key to stop, 'q' to cancel."
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
