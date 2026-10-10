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
[ "\$1" = prepare ] && { [ -e "$T/legacy-fail" ] && { echo "legacy download failed" >&2; exit 3; }; echo ready; exit 0; }
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
ps -o command= -p \$PPID >> "$T/player-parent"
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
is "the text is not on the player's parent command line" "$(grep -c '50%' "$T/player-parent")" 0

echo "Fallbacks"
conf 'EARSHOT_ENGINE=kokoro'; touch "$T/tts-fail"
is "kokoro fails: the line is said with say" "$(heard "Fallback one.")" "SAY:Fallback one."
log_has "the log names kokoro and its reason" "kokoro: model exploded"
rm "$T/tts-fail"
is "a say fallback is not cached" "$(heard "Fallback one.")" "KOKORO(af_heart):Fallback one."
touch "$T/tts-fail" "$T/say-fail"
is "kokoro and say both fail: the error tone" "$(heard "Fallback two.")" BASSO
rm "$T/tts-fail" "$T/say-fail"
chmod a-w "$EARSHOT_CACHE_DIR"
is "no room for a download file: the line is still said with say" "$(heard "Read-only cache.")" "SAY:Read-only cache."
chmod u+w "$EARSHOT_CACHE_DIR"
sleep 1; is "no fallback files are left" "$(ls "$EARSHOT_STATE_DIR" | grep -c "^fallback")" 0
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

echo "The real say command"
# With EARSHOT_SAY unset, the fallback must run the say program, not speak.sh's
# own say function. A copy of speak.sh keeps a runaway easy to stop.
cp "$S" "$T/speak-copy.sh"
conf 'EARSHOT_ENGINE=say'; : > "$PLAYED"
( unset EARSHOT_SAY; bash "$T/speak-copy.sh" say "Real say." )
for _ in $(seq 50); do [ -s "$PLAYED" ] && break; sleep 0.1; done; sleep 0.5
got=$(head -c 4 "$PLAYED"); runaway=$(pgrep -f "$T/speak-copy.sh" | wc -l | tr -d ' ')
pkill -9 -f "$T/speak-copy.sh"
is "the say fallback runs the say program (an AIFF file), once" "$got $runaway" "FORM 0"

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
SRC=$(dirname "$S")/../tts
src_hash() { cat "$SRC/Package.swift" "$SRC/Package.resolved" "$SRC/Sources/earshot-tts/main.swift" | md5 -q; }
src_hash > "$K/source.md5"
# A fake build: records the call and leaves a current helper.
printf '#!/bin/bash\necho STUB BUILD >> "%s"\nrm -f "%s.stale"\n' "$T/builds" "$K/earshot-tts" > "$T/build-tts"
chmod +x "$T/build-tts"
setup_run() { HOME=$T/home PATH=$T/bin:$PATH EARSHOT_KOKORO_DIR=$K EARSHOT_BUILD_TTS=$T/build-tts bash "$SETUP" "$@" </dev/null 2>&1; }
conf
out=$(setup_run --engine kokoro --voice af_bella)
is "a current helper is not rebuilt" "$(grep -c 'Building' <<<"$out")" 0
is "the Kokoro voice is saved" "$(grep -c '^EARSHOT_KOKORO_VOICE=af_bella$' "$EARSHOT_CONF")" 1
out=$(setup_run --engine kokoro --voice af_nobody); code=$?
is "an unknown voice fails without a build" "$code $(grep -c 'Building' <<<"$out") $(grep -c 'no voice called af_nobody' <<<"$out")" "1 0 1"

printf '#!/bin/bash\necho "Error: AudioQueueStart failed (-66681)" >&2; exit 1\n' > "$T/bin/afplay"
out=$(setup_run --engine kokoro --voice af_heart); code=$?
is "no sound output: setup still says it saved, and why it was silent" "$code $(grep -c "couldn't play the test line" <<<"$out")" "0 1"

echo "Helper rebuilds"
touch -t 202001010000 "$K/earshot-tts"
setup_run --engine kokoro --voice af_heart >/dev/null
is "setup: a helper older than its sources but built from them is not rebuilt" "$(cat "$T/builds" 2>/dev/null | wc -l | tr -d ' ')" 0
echo old > "$K/source.md5"; out=$(setup_run --engine kokoro --voice af_heart)
is "setup: a helper built from other sources is rebuilt" "$(cat "$T/builds" | wc -l | tr -d ' ')" 1
src_hash > "$K/source.md5"; touch "$K/earshot-tts.stale"; : > "$T/builds"
st=$(HOME=$T/home EARSHOT_KOKORO_DIR=$K bash "$SETUP" --engine kokoro --status 2>&1)
is "status says when the helper is out of date" "$(grep -c 'Kokoro helper: out of date' <<<"$st")" 1
setup_run --engine kokoro --voice af_heart >/dev/null
is "setup rebuilds a helper whose last rebuild failed" "$(wc -l < "$T/builds" | tr -d ' ')" 1
# speak.sh rebuilds in the background after an update, for Kokoro only.
hook_once() { jq -nc --arg cwd "$T" '{session_id: "rb", cwd: $cwd}' | EARSHOT_TTS=$K/earshot-tts EARSHOT_BUILD_TTS=$T/build-tts bash "$S" stop >/dev/null; sleep 0.5; }
rm -f "$K/earshot-tts.stale"; : > "$T/builds"; touch -t 202001010000 "$K/earshot-tts"; : > "$CALLS"
conf 'EARSHOT_ENGINE=kokoro'; hook_once
is "hooks: same sources, only newer times: no rebuild" "$(wc -l < "$T/builds" | tr -d ' ')" 0
echo old > "$K/source.md5"; touch -t 202001010000 "$K/earshot-tts"
conf 'EARSHOT_KEY=sk_x' 'EARSHOT_VOICE=v1'; hook_once
is "hooks: an ElevenLabs user is never rebuilt" "$(wc -l < "$T/builds" | tr -d ' ')" 0
conf 'EARSHOT_ENGINE=kokoro'; hook_once
is "hooks: changed sources: one rebuild" "$(wc -l < "$T/builds" | tr -d ' ')" 1
is "hooks: after a rebuild the voice is prepared, so a retry never downloads" "$(grep -c '^prepare --voice af_heart' "$CALLS")" 1
printf '#!/bin/bash\necho FAILED BUILD >> "%s"\nexit 1\n' "$T/builds" > "$T/build-tts"; : > "$T/builds"; touch -t 202001010000 "$K/earshot-tts"
hook_once; hook_once
is "hooks: a failed rebuild marks the helper and is not retried" "$(wc -l < "$T/builds" | tr -d ' ') $([ -e "$K/earshot-tts.stale" ] && echo marked)" "1 marked"

echo "Setup and the build lock"
: > "$CALLS"; echo old > "$K/source.md5"; : > "$T/builds"
printf '#!/bin/bash\necho STUB BUILD >> "%s"\nrm -f "%s.stale"\n' "$T/builds" "$K/earshot-tts" > "$T/build-tts"
( lockf -k "$EARSHOT_STATE_DIR/tts-build.lock" sleep 2 ) & sleep 0.2
t0=$(date +%s); setup_run --engine kokoro --voice af_heart >/dev/null; t1=$(date +%s); wait
is "setup waits for a background build before building" "$([ $((t1 - t0)) -ge 2 ] && echo waited) $(wc -l < "$T/builds" | tr -d ' ')" "waited 1"
is "setup prepares both Kokoro runtimes for the chosen voice" "$(grep -c '^prepare --voice af_heart' "$CALLS")" 1
out=$(setup_run --engine kokoro --voice af_heart)
is "setup does not print the helper's ready" "$(grep -cx ready <<<"$out")" 0
touch "$T/legacy-fail"; out=$(setup_run --engine kokoro --voice af_bella); code=$?; rm "$T/legacy-fail"
is "only the backup runtime failed: setup still finishes, with a note" "$code $(grep -c 'backup' <<<"$out") $(grep -c '^EARSHOT_KOKORO_VOICE=af_bella$' "$EARSHOT_CONF")" "0 1 1"
B=$(dirname "$S")/build-tts.sh
mkdir -p "$T/current"; cp "$EARSHOT_TTS" "$T/current/earshot-tts"; src_hash > "$T/current/source.md5"
out=$(EARSHOT_KOKORO_DIR=$T/current bash "$B" 2>&1)
is "build-tts.sh skips a helper that is already current" "$(grep -c 'up to date' <<<"$out")" 1

echo "Can this Mac run Kokoro"
mkdir -p "$T/fake"
fake() { printf '#!/bin/bash\n%s\n' "$2" > "$T/fake/$1"; chmod +x "$T/fake/$1"; }
support() { PATH=$T/fake:$PATH bash "$SETUP" --status 2>/dev/null | sed -n 's/^  Kokoro on this Mac: //p'; }
rm -f "$T"/fake/*
is "an Apple Silicon Mac on macOS 15+ with the tools: yes" "$(support)" "yes"
conf; is "status says when nothing is set up yet" "$(bash "$SETUP" --status 2>/dev/null | grep -c 'Engine: kokoro (not set up yet)')" 1
fake sysctl '[ "$2" = hw.optional.arm64 ] && exit 1; exec /usr/sbin/sysctl "$@"'
is "an Intel Mac: no" "$(support)" "no, it needs a Mac with Apple Silicon"
rm -f "$T"/fake/*; fake uname 'echo x86_64'
is "an Apple Silicon Mac in a Rosetta terminal: yes" "$(support)" "yes"
rm -f "$T"/fake/*; fake sw_vers 'echo 14.6'
is "macOS 14: no" "$(support)" "no, it needs macOS 15 or later"
rm -f "$T"/fake/*; fake xcode-select 'exit 2'
is "no Command Line Tools: not yet" "$(support)" "not yet, it needs the Command Line Tools (run xcode-select --install)"
rm -f "$T"/fake/*; fake sysctl '[ "$2" = hw.optional.arm64 ] && exit 1; exec /usr/sbin/sysctl "$@"'; out=$(PATH=$T/fake:$PATH setup_run --engine kokoro --voice af_heart); code=$?
is "Kokoro setup on an Intel Mac stops before building, and says why" "$code $(grep -c 'Building' <<<"$out") $(grep -c 'Apple Silicon' <<<"$out")" "1 0 1"
is "that message reads cleanly" "$(grep -c "Kokoro can't run on this Mac: it needs a Mac with Apple Silicon" <<<"$out")" 1
st=$(PATH=$T/fake:$PATH EARSHOT_KOKORO_DIR=$T/none bash "$SETUP" --status 2>/dev/null)
is "status on an Intel Mac does not suggest building Kokoro" "$(grep -c 'run setup.sh --engine kokoro' <<<"$st") $(grep -c 'Kokoro helper: not available on this Mac' <<<"$st")" "0 1"
rm -f "$T"/fake/*
mkdir -p "$T/k2"; cp "$EARSHOT_TTS" "$T/k2/earshot-tts"; fake xcode-select 'exit 2'
out=$(HOME=$T/home PATH=$T/fake:$T/bin:$PATH EARSHOT_KOKORO_DIR=$T/k2 bash "$(dirname "$S")/build-tts.sh" 2>&1)
is "build-tts.sh notices missing Command Line Tools (the swift shim always exists)" "$(grep -c 'Command Line Tools' <<<"$out")" 1
rm -f "$T"/fake/*; fake uname 'echo x86_64'; fake xcode-select 'exit 2'
fake arch 'echo "$1" >> "'"$T"'/arch.log"; shift; exec "$@"'
out=$(HOME=$T/home PATH=$T/fake:$T/bin:$PATH EARSHOT_KOKORO_DIR=$T/k2 bash "$(dirname "$S")/build-tts.sh" 2>&1)
is "build-tts.sh in a Rosetta terminal builds for Apple Silicon, once" "$(cat "$T/arch.log" 2>/dev/null | tr '\n' ' ')$(grep -c 'Apple Silicon' <<<"$out")" "-arm64 0"
rm -f "$T"/fake/*

rm -rf "$T"
echo "$pass passed, $fail failed"; [ "$fail" = 0 ]
