#!/bin/bash
# Checks the handoff to Earshot for Mac with a fake app on a socket.
# Nothing is spoken: EARSHOT_DRYRUN collects the lines the plugin says itself.
# Needs /voice on, because speak.sh exits early without it.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; S=$ROOT/plugin/scripts/speak.sh
OUT=$(mktemp); export EARSHOT_DRYRUN=$OUT EARSHOT_STATE_DIR=$(mktemp -d) EARSHOT_CONF=$(mktemp)
printf 'EARSHOT_ENGINE=say\n' > "$EARSHOT_CONF"
MICST=$(mktemp); echo 1 > "$MICST"; export EARSHOT_MIC=$(mktemp)
printf '#!/bin/bash\nexit $(cat "%s")\n' "$MICST" > "$EARSHOT_MIC"; chmod +x "$EARSHOT_MIC"
export EARSHOT_MUTE=$EARSHOT_STATE_DIR/mute   # never the real mute file
D=$(mktemp -d /tmp/eh.XXXX); SOCK=$D/app.sock; APPLOG=$D/app.log; : > "$APPLOG"
P=$(mktemp -d)/billing-service; mkdir -p "$P"; git -C "$P" init -q
pass=0; fail=0
ok() { pass=$((pass + 1)); echo "  ok    $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL  $1"; }
expect() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got $2, expected $3)"; fi; }
hook() { jq -nc --arg sid "$2" --arg cwd "$P" --argjson x "$3" '{session_id: $sid, cwd: $cwd} + $x' | bash "$S" "$1" >/dev/null; }
fake() { pkill -f "fake-app.pl $SOCK" 2>/dev/null; sleep 0.1; ( /usr/bin/perl "$ROOT/tests/fake-app.pl" "$SOCK" "$APPLOG" "$1" & ); sleep 0.3; }
said() { grep -c -- "$1" "$OUT"; }
took() { grep -c -- "$1" "$APPLOG"; }

export EARSHOT_APP_SOCK=$SOCK
fake ok
hook start a1 '{}'; sleep 0.3; : > "$OUT"; : > "$APPLOG"
hook stop a1 '{"last_assistant_message":"Done.\n🗣 Fixed the rounding bug."}'
sleep 0.3
expect "the app takes the finished line" "$(took '"type":"say".*Fixed the rounding bug')" 1
expect "the plugin stays silent when the app took it" "$(said 'Fixed the rounding bug')" 0
expect "the line carries its kind" "$(took '"kind":"done"')" 1
expect "a line said while not muted is not marked muted" "$(took '"muted"')" 0
expect "the line carries the time it was sent, in ms" "$(took '^{"sent":[0-9]\{13\},"v":1,"type":"say"')" 1
[ "$(took '"type":"status".*"state":"done"')" -ge 1 ] && ok "status changes reach the app" || bad "status changes reach the app"

fake reject; : > "$OUT"; : > "$APPLOG"
hook start a2 '{}'; hook stop a2 '{"last_assistant_message":"🗣 Rejected line."}'
expect "a rejected line is said by the plugin" "$(said 'Rejected line')" 1

now_ms() { perl -MTime::HiRes=time -e 'printf "%d", time * 1000'; }
# The same hook with no app at all, for comparison.
hook start a0 '{}'; t0=$(now_ms)
EARSHOT_APP_SOCK=$D/none.sock hook stop a0 '{"last_assistant_message":"🗣 Baseline line."}'
base=$(( $(now_ms) - t0 ))
fake silent; : > "$OUT"
hook start a3 '{}'; t0=$(now_ms)
hook stop a3 '{"last_assistant_message":"🗣 Slow app line."}'
slow=$(( $(now_ms) - t0 ))
expect "a silent app: the plugin says it, once" "$(said 'Slow app line')" 1
[ $(( slow - base )) -lt 450 ] && ok "a silent app adds about the 0.2 s wait (${base} ms without, ${slow} ms with)" \
  || bad "a silent app adds about the 0.2 s wait (${base} ms without, ${slow} ms with)"

pkill -9 -f "fake-app.pl $SOCK"; sleep 0.2; : > "$OUT"
[ -S "$SOCK" ] && ok "a crashed app leaves its socket file (test setup)" || bad "a crashed app leaves its socket file (test setup)"
hook start a6 '{}'; hook stop a6 '{"last_assistant_message":"🗣 Crashed app line."}'
expect "a crashed app's socket: the plugin says it" "$(said 'Crashed app line')" 1

rm -f "$SOCK"; : > "$OUT"
hook start a4 '{}'; hook stop a4 '{"last_assistant_message":"🗣 No app line."}'
expect "no app: the plugin says it" "$(said 'No app line')" 1

unset EARSHOT_APP_SOCK; fake ok; : > "$APPLOG"; : > "$OUT"
hook start a5 '{}'; hook stop a5 '{"last_assistant_message":"🗣 Test only line."}'
expect "tests without EARSHOT_APP_SOCK never reach a real app" "$(said 'Test only line')" 1
expect "and nothing reaches the socket" "$(took 'Test only line')" 0

export EARSHOT_APP_SOCK=$SOCK; fake ok; : > "$APPLOG"
hook end a1 '{}'; sleep 0.3
expect "a closed session tells the app" "$(took '"state":"closed"')" 1

echo $(( $(date +%s) + 3600 )) > "$EARSHOT_MUTE"; : > "$OUT"
EARSHOT_APP_SOCK= bash "$S" say "Muted line" >/dev/null
expect "a mute with an end time in the future mutes" "$(said 'Muted line')" 0
echo $(( $(date +%s) - 10 )) > "$EARSHOT_MUTE"
EARSHOT_APP_SOCK= bash "$S" say "After mute line" >/dev/null
expect "a mute that ended does not mute" "$(said 'After mute line')" 1
: > "$EARSHOT_MUTE"
EARSHOT_APP_SOCK= bash "$S" say "Plain mute line" >/dev/null
expect "an empty mute file still mutes" "$(said 'Plain mute line')" 0
# Muted with the app running: the hooks still run, so the app can show a banner.
fake ok; : > "$APPLOG"; : > "$OUT"
hook start m1 '{}'; hook stop m1 '{"last_assistant_message":"🗣 Muted app line?"}'; sleep 0.3
expect "muted with the app: the app gets the line, marked muted" "$(took '"type":"say".*Muted app line.*"muted":true')" 1
expect "muted with the app: the plugin says nothing" "$(said 'Muted app line')" 0
[ "$(took '"type":"status".*"session":"m1"')" -ge 1 ] && ok "muted with the app: statuses still reach the app" \
  || bad "muted with the app: statuses still reach the app"
fake reject; : > "$OUT"
hook start m2 '{}'; hook stop m2 '{"last_assistant_message":"🗣 Muted refused line."}'
expect "muted: a line the app refuses is not said" "$(said 'Muted refused line')" 0
fake ok
rm -f "$EARSHOT_MUTE"

pkill -f "fake-app.pl $SOCK"
rm -rf "$D" "$EARSHOT_STATE_DIR"; rm -f "$OUT" "$EARSHOT_CONF" "$MICST" "$EARSHOT_MIC"
echo "$pass passed, $fail failed"; [ "$fail" = 0 ]
