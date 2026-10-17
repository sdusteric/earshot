#!/bin/bash
# Real human negatives for the wake bench: LibriSpeech test-clean as 16 kHz mono wav.
#
#   tests/wake/librispeech.sh SRC OUTDIR
# SRC holds the unpacked LibriSpeech (the folder with LibriSpeech/test-clean in it,
# from https://www.openslr.org/resources/12/test-clean.tar.gz). Writes
# OUTDIR/wav/*.wav and OUTDIR/manifest.tsv with the wake bench's columns:
#   file (wav/ID.wav, relative to OUTDIR), label, class, voice (speaker id), condition, split, text
# An utterance whose transcript has "kobi" or "kobe" is listed in OUTDIR/kobi-hits.txt;
# it gets label 1 only if it starts with the wake, else 0 (test-clean has none).
# Resumable: wavs that exist are skipped. Env: JOBS (default 10).
set -euo pipefail
src=${1:?usage: librispeech.sh SRC OUTDIR}
out=${2:?usage: librispeech.sh SRC OUTDIR}
mkdir -p "$out/wav"
out=$(cd "$out" && pwd)
root=$(find "$src" -type d -name test-clean -print -quit)
[[ -n $root ]] || { echo "no test-clean under $src" >&2; exit 1; }
export out

find "$root" -name '*.flac' | LC_ALL=C sort > "$out/flac.list"
tr '\n' '\0' < "$out/flac.list" | xargs -0 -P "${JOBS:-10}" -I{} bash -c '
    f=$1; w="$out/wav/$(basename "${f%.flac}").wav"
    [[ -s $w ]] && exit 0
    ffmpeg -hide_banner -loglevel error -y -i "$f" -ac 1 -ar 16000 -c:a pcm_s16le "$w.tmp.wav" && mv "$w.tmp.wav" "$w"' _ {}

# Transcripts: one line per utterance, "ID WORDS", in the *.trans.txt files.
find "$root" -name '*.trans.txt' -exec cat {} + | LC_ALL=C sort > "$out/transcripts.txt"
manifest="$out/manifest.tsv"
printf '# file\tlabel\tclass\tvoice\tcondition\tsplit\ttext\n' > "$manifest"
: > "$out/kobi-hits.txt"
n=0
while read -r id words; do
    [[ -s $out/wav/$id.wav ]] || { echo "missing $id.wav" >&2; continue; }
    lower=$(printf '%s' "$words" | tr 'A-Z' 'a-z')
    label=0
    if [[ $lower =~ (^|[^a-z])(kobi|kobe)([^a-z]|$) ]]; then
        echo "$id $words" >> "$out/kobi-hits.txt"
        # Label 1 only when the name starts the utterance, as a wake (the shapes
        # Listener.stripWake accepts); "I asked kobi" mid-sentence stays 0.
        [[ $lower =~ ^((hey|hi|ok|okay|a)[[:space:],.!]*)?(kobi|kobe)([^a-z]|$) ]] && label=1
    fi
    printf '%s\t%s\tlibrispeech\t%s\tclean\tneg\t%s\n' "wav/$id.wav" "$label" "${id%%-*}" "$lower" >> "$manifest"
    n=$((n + 1))
done < "$out/transcripts.txt"
echo "$n utterances in $manifest; $(wc -l < "$out/kobi-hits.txt" | tr -d ' ') mention kobi or kobe"
