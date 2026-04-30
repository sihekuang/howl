#!/usr/bin/env bash
# run-streaming.sh — interactive harness for the chunked Whisper
# pipeline. Records from the mic via vkb-cli pipe --live, prints
# per-chunk timing and a post-stop latency report when finished.
#
# Press any key to STOP and transcribe normally.
# Press 'q' to CANCEL (no transcript, no LLM call).
#
# Usage:
#   ./run-streaming.sh                # any key stops, q cancels
#   ./run-streaming.sh --keep-wav     # also save the captured audio
#   VKB_DICT="MCP,WebRTC" ./run-streaming.sh
#
# Reads ANTHROPIC_API_KEY from ./.env. Cleaned text → stdout.
# Live chunk events + latency report → stderr.
set -e

KEEP_WAV=0
for arg in "$@"; do
  case "$arg" in
    --keep-wav) KEEP_WAV=1 ;;
    *)          echo "unknown arg: $arg" >&2; exit 2 ;;
  esac
done

DICT="${VKB_DICT:-MCP,WebRTC}"

cd "$(dirname "$0")"

if [ -f .env ]; then
  set -a; . ./.env; set +a
fi
if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
  echo "ANTHROPIC_API_KEY not set (looked in ./.env)" >&2; exit 1
fi

if [ ! -x core/build/vkb-cli ]; then
  echo "Building vkb-cli..." >&2
  make -C core build-cli >&2
fi

FIFO="$(mktemp -u /tmp/vkb-streaming.XXXXXX.fifo)"
mkfifo "$FIFO"
cleanup() { rm -f "$FIFO"; }
trap cleanup EXIT

# Start the CLI in the background, with stdin from the fifo.
core/build/vkb-cli pipe --dict "$DICT" --live --latency-report < "$FIFO" &
PID=$!
exec 3>"$FIFO"

echo "🎙  Recording — press any key to stop and transcribe, or 'q' to cancel." >&2

# Read a single keypress in raw mode.
IFS= read -rsn1 key

if [[ "$key" == "q" ]]; then
  echo "cancel" >&3
else
  echo "" >&3
  echo "✓ Stopping..." >&2
fi

exec 3>&-
wait "$PID"
