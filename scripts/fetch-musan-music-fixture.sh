#!/usr/bin/env bash
# Fetches (or synthesises) a single ~10 s 16 kHz mono clip for use as
# the harness's first non-speech music noise fixture.
#
# Strategy (in priority order):
#   1. If the MUSAN tarball is already cached locally, extract from it.
#   2. If network is available and the user opts in (FETCH_MUSAN=1),
#      download music-fma-0000.wav from openslr.org/17 (~11 GB total —
#      not attempted by default due to bandwidth).
#   3. Otherwise synthesise a deterministic 10 s harmonic signal
#      (three-tone chord at A4/E5/A5) using ffmpeg lavfi. This is the
#      default and is what is committed in the repo. It is sufficient
#      to exercise the harness pipeline against harmonic / music-like
#      content; a real MUSAN clip can replace it later.
#
# Idempotent: re-running overwrites musan_music_excerpt.wav.
# Bundled clip stays small (~320 KB) — same approach as the
# LibriSpeech voice fixtures.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$REPO_ROOT/core/test/integration/testdata/noise"
OUT_FILE="$OUT_DIR/musan_music_excerpt.wav"

mkdir -p "$OUT_DIR"

if ! command -v ffmpeg >/dev/null 2>&1; then
  echo "ERROR: ffmpeg required (brew install ffmpeg)" >&2
  exit 1
fi

# ── Option 1: Real MUSAN clip (opt-in, requires ~11 GB download) ──────────────
if [[ "${FETCH_MUSAN:-0}" == "1" ]]; then
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT
  cd "$TMP"

  echo ">> downloading MUSAN music subset index"
  curl -L -o musan.tar.gz https://www.openslr.org/resources/17/musan.tar.gz
  echo ">> extracting one music clip"
  tar -xzf musan.tar.gz musan/music/fma/music-fma-0000.wav
  SOURCE="musan/music/fma/music-fma-0000.wav"
  if [[ ! -f "$SOURCE" ]]; then
    echo "ERROR: expected MUSAN clip not found in archive: $SOURCE" >&2
    exit 1
  fi

  echo ">> trimming + transcoding to 10 s 16 kHz mono LE 16-bit PCM"
  ffmpeg -y -i "$SOURCE" -ss 0 -t 10 -ac 1 -ar 16000 -sample_fmt s16 "$OUT_FILE"
  echo ">> wrote real MUSAN clip to $OUT_FILE ($(du -h "$OUT_FILE" | cut -f1))"
  exit 0
fi

# ── Option 2 (default): Synthetic music-like signal ──────────────────────────
# Three sustained tones: A4 (440 Hz), E5 (660 Hz), A5 (880 Hz).
# Amplitude-weighted to resemble a simple chord. Fully deterministic,
# no download required, ~320 KB output.
echo ">> synthesising 10 s harmonic music-like clip (synthetic stand-in)"
ffmpeg -y \
  -f lavfi \
  -i "aevalsrc=0.3*sin(2*PI*440*t)+0.2*sin(2*PI*660*t)+0.15*sin(2*PI*880*t):s=16000:c=mono" \
  -t 10 \
  -ar 16000 \
  -ac 1 \
  -sample_fmt s16 \
  "$OUT_FILE"

echo ">> wrote synthetic music fixture to $OUT_FILE ($(du -h "$OUT_FILE" | cut -f1))"
echo "   To replace with a real MUSAN clip, re-run with FETCH_MUSAN=1"
