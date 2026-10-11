#!/bin/bash
# eval-listener.sh [record]: wake word and transcription on recordings of
# your own voice. "record" walks you through making them (they stay in
# tests/eval/listener, which git ignores: it is your voice). Then it scores
# them. Includes Earshot's own lines played through the speakers, which
# must never wake it.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; D="$ROOT/tests/eval/listener"
P() { swift run --package-path "$ROOT/app/EarshotKit" -c release earshot-probe "$@"; }
mkdir -p "$D"
if [ "$1" = record ]; then
  : > "$D/manifest.tsv"
  rec() {   # rec <file> <wake 0|1> <words> <what to do>
    read -r -p "$4 Press Return, then speak within 4 s." _
    P record 4 "$D/$1" >/dev/null || { echo "recording $1 failed"; exit 1; }
    printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$D/manifest.tsv"
  }
  rec quiet-1.wav 1 everyone 'Quiet room: say "Hey Earshot, what is everyone doing?"'
  rec quiet-2.wav 1 "billing" 'Say "Hey Earshot, tell billing service to run the tests."'
  rec quiet-3.wav 1 finebrief 'Say "Hey Earshot, what is finebrief doing?"'
  rec music-1.wav 1 everyone 'Play music out loud, then say "Hey Earshot, what is everyone doing?"'
  rec music-2.wav 0 "" 'Keep the music playing. Say nothing.'
  rec talk-1.wav 0 "" 'Have someone talk, or play a podcast. Say nothing to Earshot.'
  rec talk-2.wav 0 "" 'Say "Hey, are you there? I will be right back."'
  rec silence.wav 0 "" 'Stay silent.'
  echo "Recording the listening chime played through the speakers"
  ( sleep 0.5; afplay /System/Library/Sounds/Tink.aiff ) & P record 4 "$D/own-chime.wav" >/dev/null || { echo "recording own-chime.wav failed"; exit 1; }; wait
  printf 'own-chime.wav\t0\t\n' >> "$D/manifest.tsv"
  for line in "Hey, billing service needs your OK to run the migration." "Still on blog, about six minutes in." "Three sessions. Billing service is working."; do
    f="own-$((++n)).wav"
    echo "Recording Earshot's own line: $line"
    ( sleep 0.5; say "$line" ) & P record 4 "$D/$f" >/dev/null || { echo "recording $f failed"; exit 1; }; wait
    printf '%s\t0\t\n' "$f" >> "$D/manifest.tsv"
  done
fi
P wake-eval "$D"
