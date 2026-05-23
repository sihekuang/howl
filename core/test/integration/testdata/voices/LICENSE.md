# Voice fixtures

These WAV files are derived from the LibriSpeech ASR corpus
(http://www.openslr.org/12/), originally distributed under the
Creative Commons Attribution 4.0 International license
(https://creativecommons.org/licenses/by/4.0/).

Source files:
- `libri_1272.wav`: derived from LibriSpeech dev-clean speaker 1272
  (male), first utterance of the first chapter as ordered in the
  dev-clean tar archive. Trimmed to 5 s, transcoded to 16 kHz mono
  LE 16-bit PCM via ffmpeg.
- `libri_1462.wav`: derived from LibriSpeech dev-clean speaker 1462
  (female), same selection method.

LibriSpeech citation:
  V. Panayotov, G. Chen, D. Povey, S. Khudanpur, "Librispeech: An
  ASR Corpus Based on Public Domain Audio Books," ICASSP 2015.

Regenerate via `scripts/fetch-tse-test-voices.sh`.

## Transcripts

Files: libri_1272.txt, libri_1462.txt
Source: LibriSpeech dev-clean (CC BY 4.0)
Utterance IDs:
- `libri_1272.txt`: 1272-128104-0001 (first FLAC in tar order for speaker 1272)
- `libri_1462.txt`: 1462-170138-0027 (first FLAC in tar order for speaker 1462)
Provenance: extracted from <speaker>/<chapter>/<speaker>-<chapter>.trans.txt
            via scripts/fetch-libri-transcripts.sh
