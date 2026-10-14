#!/bin/bash
# Makes the hearing bench's audio: each line of cases.tsv said by a synthetic
# voice (Kokoro, or macOS say), clean and degraded like a webcam mic across
# the desk with its AI noise reduction on:
#   clean    as synthesized, over a faint noise floor (a mic with no gate)
#   quiet    reverb, room noise, spectral noise reduction, a hard noise gate
#            (exact zeros between words), about -40 dB, 0.9 s of zeros first
#   gate0.2, gate0.4, gate0.6
#            the same, with the first 0.2 / 0.4 / 0.6 s of speech cut to
#            zero: the gate opening late, as on the real recordings
# The degradation was checked against a real recording from such a mic:
# Parakeet and Whisper both lose the first word and garble the rest the same way.
#
#   tests/hearing/make-audio.sh OUTDIR
# then: earshot-probe hear-bench OUTDIR/manifest.tsv tests/hearing/sessions.txt
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
out=${1:?usage: make-audio.sh OUTDIR}
mkdir -p "$out/raw"
tts=${KOKORO:-$HOME/.config/earshot/kokoro/earshot-tts}
sock=${KOKORO_SOCKET:-/tmp/earshot-bench-tts.sock}
voices=(am_michael af_heart say:Samantha bm_george af_sarah am_adam say:Daniel bf_emma)

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

manifest="$out/manifest.tsv"
printf '# file\tcondition\texpected\ttext\n' > "$manifest"
n=0
while IFS=$'\t' read -r id text expected; do
    [[ -z "$id" || "$id" == \#* ]] && continue
    v=${voices[$((n % ${#voices[@]}))]}
    w=${voices[$(((n + 3) % ${#voices[@]}))]}
    n=$((n + 1))
    synth "$v" "$text" "$out/raw/$id-a.wav"
    synth "$w" "$text" "$out/raw/$id-b.wav"
    # A real mic without a gate never sends exact zeros: a faint noise floor under the clean speech.
    ffmpeg -hide_banner -loglevel error -y -i "$out/raw/$id-a.wav" -f lavfi -i "anoisesrc=color=pink:amplitude=0.0005:seed=3" \
        -filter_complex "[0:a]aresample=16000[s];[1:a]aresample=16000[n];[s][n]amix=inputs=2:duration=first:normalize=0[o]" \
        -map "[o]" -ac 1 -c:a pcm_s16le "$out/$id-clean.wav"
    degrade "$out/raw/$id-b.wav" "$out/$id-quiet.wav" 0
    degrade "$out/raw/$id-a.wav" "$out/$id-gate0.2.wav" 0.2
    degrade "$out/raw/$id-b.wav" "$out/$id-gate0.4.wav" 0.4
    degrade "$out/raw/$id-a.wav" "$out/$id-gate0.6.wav" 0.6
    for c in clean quiet gate0.2 gate0.4 gate0.6; do
        printf '%s\t%s\t%s\t%s\n' "$id-$c.wav" "$c" "$expected" "$text" >> "$manifest"
    done
done < "$here/cases.tsv"
echo "wrote $n cases to $manifest"
