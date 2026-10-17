#!/bin/bash
# Makes the wake bench's audio: every line of phrases.tsv said by every English
# Kokoro voice (names starting with a or b) and the say voices Samantha and
# Daniel, in 5 mic conditions (clean, quiet, gate0.2, gate0.4, gate0.6; see
# tests/hearing/make-audio.sh for what each one is).
#
#   tests/wake/make-wake-audio.sh OUTDIR
# Writes OUTDIR/raw/*.wav, OUTDIR/*.wav and OUTDIR/manifest.tsv:
#   file, label (1 positive, else 0), class, voice, condition, split, text
# Split is by voice: every third voice in sorted order is "holdout", the rest "tune".
# Resumable: files that exist are skipped. Env: JOBS (parallel jobs, default 10),
# KOKORO, KOKORO_SOCKET.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
out=${1:?usage: make-wake-audio.sh OUTDIR}
mkdir -p "$out/raw"
out=$(cd "$out" && pwd)
export tts=${KOKORO:-$HOME/.config/kobi/kokoro/kobi-tts}
export sock=${KOKORO_SOCKET:-/tmp/kobi-bench-tts.sock}
jobs=${JOBS:-10}

# synth and degrade are copied from tests/hearing/make-audio.sh and must stay
# the same as there, so the conditions mean the same thing in both benches.
synth() { # voice text out
    if [[ $1 == say:* ]]; then
        say -v "${1#say:}" -o "$3" --data-format=LEF32@24000 "$2"
    else
        echo "$2" | "$tts" speak --socket "$sock" --out "$3" --voice "$1" >/dev/null
    fi
}

degrade() { # in out clip-seconds
    ffmpeg -hide_banner -loglevel error -y -i "$1" -f lavfi -i "anoisesrc=color=pink:amplitude=0.006:seed=7" \
        -filter_complex "
[0:a]aresample=48000,silenceremove=start_periods=1:start_threshold=-45dB,atrim=start=$3,asetpts=PTS-STARTPTS,aecho=0.8:0.6:23|41|67:0.25|0.18|0.12,apad=pad_dur=0.4[s];
[1:a]aresample=48000[n];
[s][n]amix=inputs=2:duration=first:normalize=0,afftdn=nr=45:nf=-40,agate=threshold=0.02:range=0:attack=8:release=60:ratio=9000,volume=-12dB,adelay=900:all=1,aresample=16000[o]" \
        -map "[o]" -ac 1 -c:a pcm_s16le "$2"
}

clean() { # in out: a faint noise floor under the speech (a mic with no gate)
    ffmpeg -hide_banner -loglevel error -y -i "$1" -f lavfi -i "anoisesrc=color=pink:amplitude=0.0005:seed=3" \
        -filter_complex "[0:a]aresample=16000[s];[1:a]aresample=16000[n];[s][n]amix=inputs=2:duration=first:normalize=0[o]" \
        -map "[o]" -ac 1 -c:a pcm_s16le "$2"
}

# One job: one voice, one phrase id. Writes to a temp name, then renames, so a
# killed run never leaves a half file that a rerun would skip.
one() { # voice id text
    local v=$1 id=$2 text=$3 tag=${1//:/_}
    local raw="$out/raw/$tag-$id.wav" t
    if [[ ! -s $raw ]]; then
        synth "$v" "$text" "$raw.tmp.wav" && mv "$raw.tmp.wav" "$raw"
    fi
    for c in clean quiet gate0.2 gate0.4 gate0.6; do
        local f="$out/$tag-$id-$c.wav"
        [[ -s $f ]] && continue
        case $c in
            clean) clean "$raw" "$f.tmp.wav" ;;
            quiet) degrade "$raw" "$f.tmp.wav" 0 ;;
            *) degrade "$raw" "$f.tmp.wav" "${c#gate}" ;;
        esac
        mv "$f.tmp.wav" "$f"
    done
}
export -f synth degrade clean one
export out

kokoro=$("$tts" voices | grep -E '^[ab]' )
voices=$( { echo "$kokoro"; echo say:Samantha; echo say:Daniel; } | LC_ALL=C sort)

# ids: p001.. in phrases.tsv order, with the class and text beside them.
ids="$out/phrases.ids.tsv"
awk -F'\t' 'BEGIN{OFS="\t"} /^#/||NF<2{next} {printf "p%03d\t%s\t%s\n", ++n, $1, $2}' "$here/phrases.tsv" > "$ids"

start=$SECONDS
jobfile=$(mktemp)
while read -r v; do
    while IFS=$'\t' read -r id cls text; do
        printf '%s\t%s\t%s\n' "$v" "$id" "$text"
    done < "$ids"
done <<< "$voices" > "$jobfile"
# NUL-free, tab-separated: xargs reads one job per line.
tr '\n' '\0' < "$jobfile" | xargs -0 -P "$jobs" -I{} bash -c 'IFS=$'"'"'\t'"'"' read -r v id text <<< "$1"; one "$v" "$id" "$text"' _ {}
rm -f "$jobfile"

manifest="$out/manifest.tsv"
printf '# file\tlabel\tclass\tvoice\tcondition\tsplit\ttext\n' > "$manifest"
i=0
while read -r v; do
    split=tune; (( i % 3 == 2 )) && split=holdout
    i=$((i + 1))
    tag=${v//:/_}
    while IFS=$'\t' read -r id cls text; do
        label=0; [[ $cls == positive ]] && label=1
        for c in clean quiet gate0.2 gate0.4 gate0.6; do
            f="$tag-$id-$c.wav"
            [[ -s $out/$f ]] || { echo "missing $f" >&2; continue; }
            printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$f" "$label" "$cls" "$v" "$c" "$split" "$text" >> "$manifest"
        done
    done < "$ids"
done <<< "$voices"
echo "wrote $(($(wc -l < "$manifest") - 1)) rows to $manifest in $((SECONDS - start)) s"
