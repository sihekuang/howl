#!/usr/bin/env bash
# Fetches the ground-truth transcripts that match the committed
# LibriSpeech voice fixtures (libri_1272.wav, libri_1462.wav).
#
# Idempotent: re-running overwrites the .txt files with the same
# content. Commit the .txt files; this script is committed but only
# run when bumping fixtures.
#
# Utterance IDs were determined by running fetch-tse-test-voices.sh
# and observing which FLAC came first in the dev-clean tar listing:
#   libri_1272.wav <- 1272-128104-0001 (first FLAC in tar order for speaker 1272)
#   libri_1462.wav <- 1462-170138-0027 (first FLAC in tar order for speaker 1462)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$REPO_ROOT/core/test/integration/testdata/voices"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cd "$TMP"
echo ">> downloading LibriSpeech dev-clean (~300 MB) — this may take a moment"
curl -L -o dev-clean.tar.gz https://www.openslr.org/resources/12/dev-clean.tar.gz

echo ">> extracting transcript files"
tar -xzf dev-clean.tar.gz \
  "LibriSpeech/dev-clean/1272/128104/1272-128104.trans.txt" \
  "LibriSpeech/dev-clean/1462/170138/1462-170138.trans.txt"

# Speaker / chapter / utterance picks must match scripts/fetch-tse-test-voices.sh.
# That script picks the first FLAC in tar order (alphabetical) for each speaker.
# Verified by inspecting tar listing: 1272-128104-0001 and 1462-170138-0027 are first.
extract_transcript() {
  local utt="$1"
  local outfile="$2"
  local speaker="${utt%%-*}"
  local rest="${utt#*-}"
  local chapter="${rest%%-*}"
  local trans_path="LibriSpeech/dev-clean/${speaker}/${chapter}/${speaker}-${chapter}.trans.txt"

  if [[ ! -f "$trans_path" ]]; then
    echo "ERROR: transcript file missing at $trans_path" >&2
    exit 1
  fi
  local line
  line="$(grep "^${utt} " "$trans_path" || true)"
  if [[ -z "$line" ]]; then
    echo "ERROR: utterance $utt not found in $trans_path" >&2
    exit 1
  fi
  local text="${line#${utt} }"
  echo "$text" > "$OUT_DIR/$outfile"
  echo ">> wrote $OUT_DIR/$outfile: $text"
}

extract_transcript "1272-128104-0001" "libri_1272.txt"
extract_transcript "1462-170138-0027" "libri_1462.txt"

echo ">> done"
