#!/usr/bin/env bash
# Automated synthesized-audio evaluation for diar_mask.
#
# Synthesizes two distinct speakers with macOS `say`, mixes them on a known
# timeline (target solo / overlap / interferer solo / target solo), and runs
# diar_mask (oracle segmenter + real ECAPA cosine selection) head-to-head with
# the TSE baseline. Produces:
#   - a metrics table in the console (retention / interferer-leak / cosine),
#   - per-stage WAVs you can listen to (mixed/diar_mask/tse/cleanA),
#   - a self-contained stage-by-stage comparison HTML (opened at the end).
#
# Requirements (already present on a dev Mac): `say`, `ffmpeg`, the onnxruntime
# dylib, and speaker_encoder.onnx + tse_model.onnx resolvable via
# ~/Library/Application Support/Howl/models (or the *_PATH env vars). The tests
# skip cleanly if any are missing.
#
# Usage: scripts/diar-synth-eval.sh [OUT_DIR]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-${TMPDIR:-/tmp}/diar-synth-out}"
mkdir -p "$OUT"
HTML="$OUT/diar-compare.html"
echo "diar_mask synthesized-audio eval — output -> $OUT"
cd "$ROOT/core"

# Metrics table + WAV dump.
DIAR_SYNTH_DUMP_DIR="$OUT" go test -tags cleanupeval ./internal/speaker/ \
  -run TestDiarMask_SynthEndToEnd -v -count=1

# Stage-by-stage comparison HTML.
DIAR_SYNTH_HTML="$HTML" go test -tags cleanupeval ./internal/speaker/ \
  -run TestDiarMask_SynthHTML -count=1

# WER sweep (SNR + multi-voice) — the decisive transcription metric. Needs the
# whispercpp build + a whisper model (WHISPER_MODEL_PATH or ggml-small.en.bin).
# Emits an HTML results dashboard alongside the console table.
WER_HTML="$OUT/diar-wer.html"
DIAR_WER_HTML="$WER_HTML" go test -tags 'cleanupeval whispercpp' ./internal/speaker/ \
  -run TestDiarMask_WERSweep -v -count=1 2>&1 | grep -E 'WER sweep|condition|----|clean|overlap|intermittent|heard|lower WER' || \
  echo "(WER sweep skipped — set WHISPER_MODEL_PATH / build whispercpp)"

echo
echo "WAVs:           $OUT  (mixed.wav, diar_mask.wav, tse.wav, cleanA.wav)"
echo "Stage compare:  $HTML"
echo "WER results:    $WER_HTML"
if command -v open >/dev/null 2>&1; then
  open "$HTML"; [ -f "$WER_HTML" ] && open "$WER_HTML"
else
  echo "Open the HTML files above in a browser."
fi
