#!/usr/bin/env bash
# run-whisper.sh — record and transcribe with Whisper only (no LLM cleanup).
# Useful for measuring raw Whisper latency and output quality.
#
# Press any key to stop recording.
# Press 'q' to cancel.
#
# Usage:
#   ./run-whisper.sh
#   VKB_LANGUAGE=fr ./run-whisper.sh
set -e

cd "$(dirname "$0")"

echo "Building vkb-cli..." >&2
make -C core build-cli >&2

DICT="${VKB_DICT:-}"

FIFO="$(mktemp -u /tmp/vkb-whisper.XXXXXX.fifo)"
mkfifo "$FIFO"
cleanup() { rm -f "$FIFO"; }
trap cleanup EXIT

ARGS="--live --no-llm --latency-report"
[ -n "$DICT" ] && ARGS="$ARGS --dict $DICT"

# shellcheck disable=SC2086
core/build/vkb-cli pipe $ARGS < "$FIFO" &
PID=$!
exec 3>"$FIFO"

echo "🎙  Recording (Whisper only) — press any key to stop, 'q' to cancel." >&2

IFS= read -rsn1 key

if [[ "$key" == "q" ]]; then
  echo "cancel" >&3
else
  echo "" >&3
  echo "✓ Stopping..." >&2
fi

exec 3>&-
wait "$PID"
