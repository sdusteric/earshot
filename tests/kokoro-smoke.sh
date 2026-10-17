#!/bin/bash
# Checks the real Kokoro helper. Needs it built (setup.sh --engine kokoro) and
# its models downloaded. Not part of the quick suite: it takes about a minute.
TTS=${KOBI_TTS:-$HOME/.config/kobi/kokoro/kobi-tts}
[ -x "$TTS" ] || { echo "Build the helper first: bash plugin/scripts/build-tts.sh"; exit 1; }
D=$(mktemp -d); SOCK=$D/k.sock; pass=0; fail=0
ok() { pass=$((pass + 1)); echo "  ok    $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL  $1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
wav_ok() { [ "$(head -c 4 "$1" 2>/dev/null)" = RIFF ] && afinfo "$1" 2>/dev/null | awk '/duration/ { exit !($3 > 0.5) }'; }
speak() { printf '%s' "$2" | "$TTS" speak --socket "$SOCK" --out "$1" ${3:+--voice "$3"}; }
servers() { pgrep -f "$TTS serve --socket $SOCK" | wc -l | tr -d ' '; }
stop_servers() { pkill -9 -f "$TTS serve --socket $SOCK"; sleep 0.3; }
ms() { perl -MTime::HiRes=time -e 'printf "%d", time * 1000'; }

echo "Kokoro helper"
speak "$D/1.wav" "Heads up, billing service keeps hitting the same error."
check "1. with no server, speak starts one and the line is made" 'wav_ok "$D/1.wav" && [ "$(servers)" = 1 ]'
t=$(ms); for i in 2 3 4; do speak "$D/$i.wav" "Line $i: billing service needs your OK."; done; t=$(( $(ms) - t ))
check "2. three lines through a loaded server, under 3 s in all ($t ms)" 'wav_ok "$D/4.wav" && [ "$t" -lt 3000 ]'
speak "$D/q.wav" $'It\'s "done" & 50% $HOME \\o/\nnaïve café, déjà vu'
check "3. quotes, \$, backslashes, a newline and accents" 'wav_ok "$D/q.wav"'
long="Seven sessions. $(for i in 1 2 3 4 5 6; do printf 'Project %s finished: fixed the broken links and the refund rounding. ' "$i"; done)And 1 more."
speak "$D/long.wav" "$long"
check "4. a long roll call line" 'wav_ok "$D/long.wav"'
speak "$D/m.wav" "Line 2: billing service needs your OK." am_michael
check "5. another voice sounds different" 'wav_ok "$D/m.wav" && [ "$(md5 -q "$D/m.wav")" != "$(md5 -q "$D/2.wav")" ]'
t=$(ms); "$TTS" serve --socket "$SOCK"; t=$(( $(ms) - t ))
check "6. a second server exits at once ($t ms) and the first keeps running" '[ "$t" -lt 2000 ] && [ "$(servers)" = 1 ]'
stop_servers
speak "$D/a.wav" "First at once." & speak "$D/b.wav" "Second at once." & wait; sleep 0.5
check "7. two lines at once with no server: both made, one server" 'wav_ok "$D/a.wav" && wav_ok "$D/b.wav" && [ "$(servers)" = 1 ]'
stop_servers
check "8a. a crashed server leaves its socket file" '[ -S "$SOCK" ]'
speak "$D/s.wav" "After a crash."
check "8b. after a crash the next line still works" 'wav_ok "$D/s.wav"'
speak "$D/k.wav" "$long" & sleep 0.15; stop_servers; wait
check "9. the server dies mid-request: the line is still made" 'wav_ok "$D/k.wav"'
stop_servers
KOBI_KOKORO_IDLE_SECS=3 "$TTS" serve --socket "$SOCK" & sleep 8
check "10. an idle server exits and removes its socket" '[ "$(servers)" = 0 ] && [ ! -e "$SOCK" ]'
check "11. empty text fails" '! printf "" | "$TTS" speak --socket "$SOCK" --out "$D/e.wav" 2>/dev/null'
check "12. an unknown voice fails with a message" '! speak "$D/x.wav" "Hello." no_such_voice 2>"$D/err" && [ -s "$D/err" ]'
speak "$D/t.wav" "Started by speak."; pkill -TERM -f "$TTS serve --socket $SOCK"; sleep 1
check "13. a server started by speak stops on TERM, so rebuilds can replace it" '[ "$(servers)" = 0 ]'
stop_servers; t=$(ms)
printf '%s' "$long" | KOBI_KOKORO_REQUEST_SECS=0.01 "$TTS" speak --socket "$SOCK" --out "$D/h.wav"; t=$(( $(ms) - t ))
check "14. a request over the server's limit: the server quits and the line is still made ($t ms)" 'wav_ok "$D/h.wav" && [ "$t" -lt 20000 ] && grep -q "quitting" "$SOCK.log"'
check "15. prepare loads both runtimes for a voice" '"$TTS" prepare --voice am_michael >/dev/null 2>&1'
stop_servers; lockf -k "$SOCK.lock" sleep 1.5 & sleep 0.2; t=$(ms)
speak "$D/r.wav" "After the old server let go."; t=$(( $(ms) - t )); wait
check "16. a server that still holds the lock: the client starts a new one when it lets go ($t ms)" 'wav_ok "$D/r.wav" && [ "$(servers)" = 1 ]'
stop_servers
LONG=$D/$(printf 'x%.0s' $(seq 90))/k.sock; mkdir -p "${LONG%/*}"
printf 'A long socket path.' | "$TTS" speak --socket "$LONG" --out "$D/p.wav" 2>/dev/null
check "17. a socket path too long for a socket: the line is still made" 'wav_ok "$D/p.wav"'
mkdir -p "$D/a" "$D/b"; ( cd "$D/a" && "$TTS" serve --socket "$SOCK" ) & sleep 3
( cd "$D/b" && printf 'Relative.' | "$TTS" speak --socket "$SOCK" --out rel.wav )
check "18. a relative --out is the client's folder, not the server's" 'wav_ok "$D/b/rel.wav" && [ ! -e "$D/a/rel.wav" ]'
stop_servers
rm -rf "$D"
echo "$pass passed, $fail failed"; [ "$fail" = 0 ]
