#!/usr/bin/env bash
# One-time fetch of two LibriSpeech dev-clean utterances for the TSE
# integration test fixtures. Run once; the resulting WAVs get
# committed. Reproducibility lives in this script.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="$REPO_ROOT/core/test/integration/testdata/voices"
mkdir -p "$OUT_DIR"

WORK_DIR="$(mktemp -d -t tse-fixtures.XXXXXX)"
trap 'rm -rf "$WORK_DIR"' EXIT

echo "Downloading LibriSpeech dev-clean (~337 MB)..."
curl -L --progress-bar \
  https://www.openslr.org/resources/12/dev-clean.tar.gz \
  -o "$WORK_DIR/dev-clean.tar.gz"

# Two clearly distinct dev-clean speakers (one M, one F) for max
# acoustic distance: 1272 (M), 1462 (F). Both well-attested in
# LibriSpeech dev-clean.
for SPEAKER in 1272 1462; do
  echo "Extracting speaker $SPEAKER..."
  FLAC_PATH=$(tar -tzf "$WORK_DIR/dev-clean.tar.gz" \
    | grep "LibriSpeech/dev-clean/$SPEAKER/" \
    | grep '\.flac$' \
    | head -n 1)
  if [ -z "$FLAC_PATH" ]; then
    echo "ERROR: no flac found for speaker $SPEAKER" >&2
    exit 1
  fi
  echo "  picked: $FLAC_PATH"
  tar -xzf "$WORK_DIR/dev-clean.tar.gz" -C "$WORK_DIR" "$FLAC_PATH"

  ffmpeg -y -loglevel error \
    -i "$WORK_DIR/$FLAC_PATH" \
    -ac 1 -ar 16000 -sample_fmt s16 -t 5 \
    "$OUT_DIR/libri_${SPEAKER}.wav"
  echo "  wrote: $OUT_DIR/libri_${SPEAKER}.wav"
done

echo "Done. Fixture sizes:"
ls -la "$OUT_DIR"/libri_*.wav
