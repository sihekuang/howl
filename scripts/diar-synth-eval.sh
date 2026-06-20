#!/usr/bin/env bash
# Automated synthesized-audio evaluation for diar_mask.
#
# Synthesizes two distinct speakers with macOS `say`, mixes them on a known
# timeline (target solo / overlap / interferer solo / target solo), and runs
# diar_mask (oracle segmenter + real ECAPA cosine selection) head-to-head with
# the TSE baseline — printing a retention / interferer-leakage / cosine table.
# Also writes mixed/diar_mask/tse/cleanA WAVs you can listen to.
#
# Requirements (all already present on a dev Mac): `say`, `ffmpeg`, the
# onnxruntime dylib, and speaker_encoder.onnx + tse_model.onnx resolvable via
# ~/Library/Application Support/Howl/models (or the *_PATH env vars). The test
# skips cleanly if any are missing.
#
# Usage: scripts/diar-synth-eval.sh [DUMP_DIR]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DUMP="${1:-${TMPDIR:-/tmp}/diar-synth-out}"
mkdir -p "$DUMP"
echo "diar_mask synthesized-audio eval — WAV dump -> $DUMP"
cd "$ROOT/core"
DIAR_SYNTH_DUMP_DIR="$DUMP" go test -tags cleanupeval ./internal/speaker/ \
  -run TestDiarMask_SynthEndToEnd -v -count=1
echo
echo "Listen: open \"$DUMP\"   (mixed.wav, diar_mask.wav, tse.wav, cleanA.wav)"
