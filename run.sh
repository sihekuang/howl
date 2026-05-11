#!/usr/bin/env bash
# run.sh — record N seconds from the mic and run the full Howl pipeline
# end-to-end (mic → denoise → decimate → whisper → dict → LLM cleanup).
#
# Post-refactor (audio capture moved to Swift in production), this
# script drives the Go CLI's --live mode directly. The CLI still owns
# its own MalgoCapture for the test path so we can verify the Go side
# in isolation from the Mac app.
#
# Usage:
#   ./run.sh             # records 4 seconds (default)
#   ./run.sh 6           # records 6 seconds
#   ./run.sh --keep-wav  # also save the captured audio to /tmp/howl-test.wav
#   HOWL_DICT="MCP,WebRTC,Wispr" ./run.sh   # override custom dict
#
# Reads ANTHROPIC_API_KEY from ./.env (KEY=VALUE format).
# Cleaned text goes to stdout; progress and errors to stderr.
# Pipe stdout safely:  ./run.sh | pbcopy
#
# Tail the Go-side trace while running, in another terminal:
#   tail -f /tmp/howl.log
set -e

KEEP_WAV=0
SECS=4
for arg in "$@"; do
  case "$arg" in
    --keep-wav) KEEP_WAV=1 ;;
    *[0-9]*)    SECS="$arg" ;;
    *)          echo "unknown arg: $arg" >&2; exit 2 ;;
  esac
done

DICT="${HOWL_DICT:-MCP,WebRTC}"

cd "$(dirname "$0")"

# Load API key from .env
if [ -f .env ]; then
  set -a
  . ./.env
  set +a
fi

if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
  echo "ANTHROPIC_API_KEY not set (looked in ./.env)" >&2
  exit 1
fi

# Build CLI if missing
if [ ! -x core/build/howl-cli ]; then
  echo "Building howl-cli..." >&2
  make -C core build-cli >&2
fi

# When --keep-wav is set, capture to a WAV first (two-step flow), so
# the user can replay the same audio against the pipeline later. The
# default path is the simpler one-step --live mode.
if [ "$KEEP_WAV" = "1" ]; then
  WAV="/tmp/howl-test.wav"
  echo "Recording $SECS seconds to $WAV. Speak now." >&2
  core/build/howl-cli capture --secs "$SECS" --out "$WAV"
  echo "" >&2
  echo "Cleaned output:" >&2
  core/build/howl-cli pipe --dict "$DICT" "$WAV"
  exit $?
fi

# One-step live path: pipe --live records from the mic and runs the
# full pipeline; it stops on Enter (newline on stdin). We deliver that
# newline after $SECS seconds so the script honors the duration arg.
echo "Recording $SECS seconds via --live. Speak now." >&2
( sleep "$SECS"; printf '\n' ) | core/build/howl-cli pipe --dict "$DICT" --live
