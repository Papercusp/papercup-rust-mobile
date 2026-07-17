#!/bin/bash
# Generate injected-voice soak fixtures (see PapercupUITests/VoiceParityUITests.swift).
# Runs on macOS (uses `say`/`afconvert`).
# Output: ~/voice-fixtures/turn-NN.pcm (raw 16kHz mono PCM16) + .wav siblings.
set -euo pipefail
DIR="${1:-$HOME/voice-fixtures}"
rm -rf "$DIR"
mkdir -p "$DIR"
QUESTIONS=(
  "What is two plus two?"
  "What is the capital of France?"
  "Say the word banana."
  "How many days are in a week?"
  "What color is the sky on a clear day?"
  "What is three times three?"
  "Name the planet we live on."
  "What is the opposite of hot?"
  "How many legs does a spider have?"
  "What is ten minus four?"
)
i=1
for q in "${QUESTIONS[@]}"; do
  n=$(printf "turn-%02d" "$i")
  say -o "$DIR/$n.aiff" "$q"
  afconvert -f WAVE -d LEI16@16000 -c 1 "$DIR/$n.aiff" "$DIR/$n.wav"
  # Extract raw PCM via the wave module (robust to non-44-byte headers).
  python3 - "$DIR/$n.wav" "$DIR/$n.pcm" <<'PY'
import sys, wave
w = wave.open(sys.argv[1], "rb")
assert w.getframerate() == 16000 and w.getnchannels() == 1 and w.getsampwidth() == 2, \
    (w.getframerate(), w.getnchannels(), w.getsampwidth())
open(sys.argv[2], "wb").write(w.readframes(w.getnframes()))
PY
  rm "$DIR/$n.aiff"
  i=$((i+1))
done
ls -la "$DIR"
