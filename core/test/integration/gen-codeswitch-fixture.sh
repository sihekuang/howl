#!/usr/bin/env bash
# Regenerates testdata/codeswitch-en-zh.wav: an English+Chinese code-switch
# utterance synthesized with macOS `say` (per-language voices) and normalized
# to 16 kHz mono 16-bit PCM WAV — whisper's required input format. Commit the
# resulting WAV so the test does not depend on which TTS voices a machine has.
#
# Usage: ./gen-codeswitch-fixture.sh   (override voices with EN_VOICE / ZH_VOICE)
set -euo pipefail
cd "$(dirname "$0")"
OUT="testdata/codeswitch-en-zh.wav"
EN_VOICE="${EN_VOICE:-Samantha}"
ZH_VOICE="${ZH_VOICE:-Meijia}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Segments: English … Chinese … English. Known content asserted by the test.
say -v "$EN_VOICE" -o "$TMP/1.aiff" "Let's schedule the"
say -v "$ZH_VOICE" -o "$TMP/2.aiff" "会议"
say -v "$EN_VOICE" -o "$TMP/3.aiff" "for tomorrow afternoon"

for i in 1 2 3; do
  afconvert "$TMP/$i.aiff" "$TMP/$i.wav" -f WAVE -d LEI16@16000 -c 1
done

# Concatenate with python stdlib `wave` (preinstalled with macOS CLT).
python3 - "$TMP/1.wav" "$TMP/2.wav" "$TMP/3.wav" "$OUT" <<'PY'
import sys, wave
*ins, out = sys.argv[1:]
o = None
for p in ins:
    with wave.open(p, 'rb') as w:
        if o is None:
            o = wave.open(out, 'wb'); o.setparams(w.getparams())
        o.writeframes(w.readframes(w.getnframes()))
o.close()
PY
echo "wrote $OUT"
