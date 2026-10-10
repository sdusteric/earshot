#!/bin/bash
# Checks engine choice, caching and fallbacks with a fake Kokoro helper, a fake
# `say` and a fake player. Needs /voice on, like stuck-and-levels.sh.
S="$(cd "$(dirname "$0")/.." && pwd)/scripts/speak.sh"
T=$(mktemp -d)
export EARSHOT_STATE_DIR=$T/state EARSHOT_CACHE_DIR=$T/cache EARSHOT_CONF=$T/config
export EARSHOT_TTS=$T/tts EARSHOT_SAY=$T/say EARSHOT_PLAYER=$T/player EARSHOT_MIC=$T/mic
PLAYED=$T/played; CALLS=$T/calls
printf '#!/bin/bash\nexit 1\n' > "$EARSHOT_MIC"
# Fake helper: "speak" writes KOKORO(voice):text to --out, or fails when $T/tts-fail exists.
cat > "$EARSHOT_TTS" <<EOF
#!/bin/bash
echo "\$*" >> "$CALLS"
[ "\$1" = voices ] && { printf "af_heart\\naf_bella\\n"; exit 0; }
[ "\$1" = speak ] || exit 0
[ -e "$T/tts-fail" ] && { echo "model exploded" >&2; exit 1; }
while [ \$# -gt 0 ]; do case "\$1" in --out) out=\$2; shift ;; --voice) v=\$2; shift ;; esac; shift; done
printf 'KOKORO(%s):%s' "\$v" "\$(cat)" > "\$out"
EOF
# Fake say: -f FILE -o OUT writes SAY:text, or fails when $T/say-fail exists.
cat > "$EARSHOT_SAY" <<EOF
#!/bin/bash
[ -e "$T/say-fail" ] && exit 1
while [ \$# -gt 0 ]; do case "\$1" in -f) f=\$2; shift ;; -o) o=\$2; shift ;; esac; shift; done
printf 'SAY:%s' "\$(cat "\$f")" > "\$o"
EOF
cat > "$EARSHOT_PLAYER" <<EOF
#!/bin/bash
case "\$1" in *Basso*) echo BASSO ;; *) cat "\$1"; echo ;; esac >> "$PLAYED"
EOF
chmod +x "$EARSHOT_TTS" "$EARSHOT_SAY" "$EARSHOT_PLAYER"
pass=0; fail=0
conf() { printf '%s\n' "$@" > "$EARSHOT_CONF"; }
# heard <line>: speaks the line, waits up to 5 s, prints what played.
heard() {
  : > "$PLAYED"; bash "$S" say "$1"
  for _ in $(seq 50); do [ -s "$PLAYED" ] && break; sleep 0.1; done; sleep 0.2
  cat "$PLAYED"
}
is() { # is <name> <got> <want>
  if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "  ok    $1"; else fail=$((fail + 1)); echo "  FAIL  $1 (got: $2, want: $3)"; fi
}
log_has() { grep -q -- "$2" "$EARSHOT_STATE_DIR/earshot.log" 2>/dev/null && is "$1" yes yes || is "$1" no yes; }

echo "Engine choice"
conf; is "no key, no engine: kokoro" "$(bash "$S" engine </dev/null)" kokoro
conf 'EARSHOT_KEY=sk_x' 'EARSHOT_VOICE=v'; is "a key and no engine: elevenlabs" "$(bash "$S" engine </dev/null)" elevenlabs
conf 'EARSHOT_KEY=sk_x' 'EARSHOT_ENGINE=kokoro'; is "the engine line wins over the key" "$(bash "$S" engine </dev/null)" kokoro
conf 'EARSHOT_ENGINE=loud'; is "an unknown engine: kokoro" "$(bash "$S" engine </dev/null)" kokoro
conf 'EARSHOT_ENGINE=elevenlabs'; is "elevenlabs without a key stays silent" "$(heard "No key.")" ""

echo "Kokoro"
conf 'EARSHOT_ENGINE=kokoro'
is "a line is made by the helper" "$(heard "Hello one.")" "KOKORO(af_heart):Hello one."
: > "$CALLS"; heard "Hello one." >/dev/null
is "a repeated line comes from the cache" "$(grep -c speak "$CALLS")" 0
f="$EARSHOT_CACHE_DIR/$(printf '%s' "kokoro af_heart Hello one." | md5 -q).wav"
is "the cache name has the engine and voice" "$([ -s "$f" ] && echo yes)" yes
conf 'EARSHOT_ENGINE=kokoro' 'EARSHOT_KOKORO_VOICE=am_michael'
is "EARSHOT_KOKORO_VOICE picks the voice" "$(heard "Hello two.")" "KOKORO(am_michael):Hello two."
odd=$'It\'s "done" & 50% $HOME \\o/ café'
is "text arrives exactly" "$(heard "$odd")" "KOKORO(am_michael):$odd"
is "the text is not on the helper's command line" "$(grep -c 'café' "$CALLS")" 0

echo "Fallbacks"
conf 'EARSHOT_ENGINE=kokoro'; touch "$T/tts-fail"
is "kokoro fails: the line is said with say" "$(heard "Fallback one.")" "SAY:Fallback one."
log_has "the log names kokoro and its reason" "kokoro: model exploded"
rm "$T/tts-fail"
is "a say fallback is not cached" "$(heard "Fallback one.")" "KOKORO(af_heart):Fallback one."
touch "$T/tts-fail" "$T/say-fail"
is "kokoro and say both fail: the error tone" "$(heard "Fallback two.")" BASSO
rm "$T/tts-fail" "$T/say-fail"
is "no fallback files are left" "$(ls "$EARSHOT_STATE_DIR" | grep -c '^fallback')" 0
conf 'EARSHOT_ENGINE=say'
is "the say engine" "$(heard "Plain voice.")" "SAY:Plain voice."

echo "ElevenLabs users after the update"
conf 'EARSHOT_KEY=sk_x' 'EARSHOT_VOICE=v1'
printf 'OLD CACHE' > "$EARSHOT_CACHE_DIR/$(printf '%s' "eleven_v4_turbo v1 Cached line." | md5 -q).mp3"
is "old cache: an ElevenLabs line already cached is played as before" "$(heard "Cached line.")" "OLD CACHE"

echo "Session start"
conf 'EARSHOT_ENGINE=kokoro'; : > "$CALLS"
jq -nc --arg cwd "$T" '{session_id: "e1", cwd: $cwd}' | bash "$S" begin >/dev/null; sleep 0.5
is "a new session loads Kokoro" "$(grep -c "^serve --socket $EARSHOT_STATE_DIR/kokoro.sock" "$CALLS")" 1
conf 'EARSHOT_KEY=sk_x' 'EARSHOT_VOICE=v1'; : > "$CALLS"
jq -nc --arg cwd "$T" '{session_id: "e2", cwd: $cwd}' | bash "$S" begin >/dev/null; sleep 0.5
is "an ElevenLabs session does not" "$(grep -c serve "$CALLS")" 0

echo "Setup"
SETUP="$(dirname "$S")/setup.sh"
conf 'EARSHOT_KEY=sk_x' 'EARSHOT_VOICE=v1' 'EARSHOT_LEVEL=quiet'
st=$(bash "$SETUP" --status 2>&1)
is "status names the engine" "$(grep -c 'Engine: elevenlabs' <<<"$st")" 1
is "an unknown engine is refused" "$(bash "$SETUP" --engine loud 2>&1 | grep -c 'Engine must be')" 1
is "kokoro voices are listed without a key" "$(bash "$SETUP" --engine kokoro --list-voices | grep -cx af_heart)" 1

# A full setup run against a fake home and a fake, current Kokoro helper.
K=$T/kokoro; mkdir -p "$K" "$T/bin" "$T/home"; cp "$EARSHOT_TTS" "$K/earshot-tts"
printf '#!/bin/bash\nexit 0\n' > "$T/bin/afplay"; chmod +x "$T/bin/afplay"
setup_run() { HOME=$T/home PATH=$T/bin:$PATH EARSHOT_KOKORO_DIR=$K bash "$SETUP" "$@" </dev/null 2>&1; }
conf
out=$(setup_run --engine kokoro --voice af_bella)
is "a current helper is not rebuilt" "$(grep -c 'Building' <<<"$out")" 0
is "the Kokoro voice is saved" "$(grep -c '^EARSHOT_KOKORO_VOICE=af_bella$' "$EARSHOT_CONF")" 1
out=$(setup_run --engine kokoro --voice af_nobody); code=$?
is "an unknown voice fails without a build" "$code $(grep -c 'Building' <<<"$out") $(grep -c 'no voice called af_nobody' <<<"$out")" "1 0 1"

printf '#!/bin/bash\necho "Error: AudioQueueStart failed (-66681)" >&2; exit 1\n' > "$T/bin/afplay"
out=$(setup_run --engine kokoro --voice af_heart); code=$?
is "no sound output: setup still says it saved, and why it was silent" "$code $(grep -c "couldn't play the test line" <<<"$out")" "0 1"

rm -rf "$T"
echo "$pass passed, $fail failed"; [ "$fail" = 0 ]
