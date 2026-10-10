#!/bin/bash
# Checks stuck detection and EARSHOT_LEVEL with simulated hook input.
# Nothing is spoken: EARSHOT_DRYRUN collects the lines instead.
# Needs /voice on, because speak.sh exits early without it. A throwaway config
# with a dummy key keeps your own settings out of the results.
S="$(cd "$(dirname "$0")/.." && pwd)/scripts/speak.sh"
OUT=$(mktemp); export EARSHOT_DRYRUN=$OUT EARSHOT_STATE_DIR=$(mktemp -d) EARSHOT_CONF=$(mktemp)
printf 'EARSHOT_KEY=sk_test\nEARSHOT_VOICE=test\n' > "$EARSHOT_CONF"
P=$(mktemp -d)/billing-service; mkdir -p "$P"; git -C "$P" init -q
pass=0; fail=0
hook() { # hook <mode> <session> <json-extra>
  jq -nc --arg sid "$2" --arg cwd "$P" --argjson x "$3" '{session_id: $sid, cwd: $cwd} + $x' | bash "$S" "$1" >/dev/null
}
bash_fail() { hook toolfail "$1" "$(jq -nc --arg c "$2" --arg e "$3" '{tool_name: "Bash", tool_input: {command: $c}, error: $e}')"; }
bash_ok() { hook tool "$1" "$(jq -nc --arg c "$2" --arg o "$3" '{tool_name: "Bash", tool_input: {command: $c}, tool_response: {stdout: $o, stderr: ""}}')"; }
edit() { hook tool "$1" "$(jq -nc --arg n "$2" '{tool_name: "Edit", tool_input: {file_path: "/x/a.py", new_string: $n}, tool_response: {}}')"; }
check() { # check <name> <expected count> <pattern>
  local got; got=$(grep -c -- "$3" "$OUT"); got=${got:-0}
  if [ "$got" = "$2" ]; then pass=$((pass + 1)); echo "  ok    $1"; else fail=$((fail + 1)); echo "  FAIL  $1 (heard $got, expected $2)"; fi
  : > "$OUT"
}
new() { hook start "$1" '{}'; : > "$OUT"; }

echo "Stuck detection"
new s1; for i in 1 2 3 4; do edit s1 "try $i"; bash_fail s1 "npm test" $'Exit code 1\nFAIL invoices.test.js\n  TypeError: total is not a function (took 2.3'"$i"'s at 10:4'"$i"':01)'; done
check "same error 3x with edits in between, spoken once" 1 "keeps hitting the same error"
new s2; for n in 3 2 1; do edit s2 "fix $n"; bash_fail s2 "npm test" $'Exit code 1\n'"$n failed, 9 passed"; done
check "error count goes 3, 2, 1 (progress): silent" 0 "might be stuck"
new s3; for c in "ls x" "cat y" "rm z"; do bash_fail s3 "$c" "Exit code 1"; done
check "bare 'Exit code 1' from different commands: silent" 0 "might be stuck"
new s4; for i in 1 2 3; do bash_fail s4 "make build" "Exit code 1"; done
check "same command fails the same way 3x: one warning, the specific one" 1 "keeps hitting the same error"
new s5; for i in 1 2 3 4; do bash_fail s5 "sleep 30 && curl -f localhost:3000/health" $'Exit code 7\ncurl: (7) Failed to connect'; done
check "polling a server that is still starting: silent" 0 "might be stuck"
new s6; for i in 1 2 3; do bash_ok s6 "git status" "nothing to commit"; done
check "same call, same result 3x in a row" 1 "running the same thing over and over"
new s7; for i in 1 2 3; do bash_ok s7 "ls build" "file$i"; done
check "same call, different results: silent" 0 "might be stuck"
new s8; for i in 1 2 3; do bash_ok s8 "cat a" "A"; bash_ok s8 "cat b" "B"; done
check "two steps alternating 3 rounds" 1 "back and forth"
new s4b; for i in 1 2 3; do bash_fail s4b "make build" "Exit code 1"; done; for i in 1 2 3; do bash_ok s4b "cat a" "A"; done
check "a second loop in the same turn stays quiet" 1 "might be stuck"
new s9; bash_ok s9 "npm run build:prod" "built in 9 minutes"
check "one slow command: silent" 0 "might be stuck"
new s10; for i in 1 2 3; do hook toolfail s10 '{"tool_name":"Bash","tool_input":{"command":"npm test"},"error":"Interrupted","is_interrupt":true}'; done
check "interrupted calls do not count" 0 "might be stuck"

echo "EARSHOT_LEVEL"
for lvl in quiet normal all; do
  export EARSHOT_LEVEL=$lvl EARSHOT_BEAT_SECS=0
  hook start "l-$lvl" '{}'; bash_ok "l-$lvl" "echo hi" "hi"; hook notify "l-$lvl" '{"notification_type":"permission_prompt"}'
  acks=$(grep -cE '^(Got it|On it|Okay, on it)' "$OUT"); beats=$(grep -c 'Still on' "$OUT"); alerts=$(grep -c 'needs your OK' "$OUT")
  case $lvl in quiet) want="0 0 1" ;; normal) want="0 1 1" ;; all) want="1 1 1" ;; esac
  if [ "$acks $beats $alerts" = "$want" ]; then pass=$((pass + 1)); echo "  ok    $lvl: ack/beat/alert = $want"; else fail=$((fail + 1)); echo "  FAIL  $lvl: got $acks $beats $alerts, expected $want"; fi
  : > "$OUT"
done

echo "Which session is talking"
export EARSHOT_LEVEL=normal EARSHOT_LIVE_DIR=$EARSHOT_STATE_DIR/live-names
Q=$(dirname "$P")/invoice-api; mkdir -p "$Q"; git -C "$Q" init -q
T=$(mktemp -d)
echo '{"type":"ai-title","aiTitle":"Refund rounding fix for EU invoices and more","sessionId":"w1"}' > "$T/w1.jsonl"
printf '%s\n' '{"type":"ai-title","aiTitle":"Old name","sessionId":"w2"}' '{"type":"custom-title","customTitle":"Tax export","sessionId":"w2"}' > "$T/w2.jsonl"
open_session() { hook begin "$1" "$(jq -nc --arg t "$T/$1.jsonl" --arg c "${2:-$P}" '{transcript_path: $t, cwd: $c}')"; }
finish() { hook stop "$1" "$(jq -nc --arg t "$T/$1.jsonl" '{transcript_path: $t, last_assistant_message: "Done.\n🗣 Fixed it."}')"; }
ping() { hook notify "$1" "$(jq -nc --arg t "$T/$1.jsonl" '{transcript_path: $t, notification_type: "permission_prompt"}')"; }
: > "$OUT"
open_session w1; finish w1; ping w1
check "one session: the summary has no name" 1 "^Fixed it.$"
open_session w9 "$Q"; finish w1; ping w1
check "two projects: the summary says the project" 1 "^From billing service: Fixed it.$"
check "two projects: no title needed" 0 "Refund"
open_session w2; ping w1
check "same project: the title, 6 words at most" 1 "^Hey, the Refund rounding fix for EU invoices session in billing service needs your OK"
ping w2; finish w2
check "same project: a /rename title wins" 2 "the Tax export session in billing service"
EARSHOT_SESSION_NAME=never finish w2; EARSHOT_SESSION_NAME=never ping w2
check "EARSHOT_SESSION_NAME=never: no names" 0 "Tax export\|From billing"
hook end w2 '{}'; hook end w9 '{}'; finish w1
check "closed sessions stop counting" 1 "^Fixed it.$"
R=$(dirname "$P")/invoiceApi_v2; mkdir -p "$R"
hook fail w9 "$(jq -nc --arg c "$R" '{cwd: $c}')"; hook end w9 '{}'
check "folder names are said as words" 1 "^Invoice Api v2 hit an error."

echo "Question reminder"
printf '%s\n' tok question "billing service" "" "" > "$EARSHOT_STATE_DIR/wait-q1"
bash "$S" remind q1 tok first </dev/null
check "the first reminder names the project" 1 "^Hey, billing service has a question for you.$"
bash "$S" remind q1 tok 5 </dev/null
check "later reminders say how long" 1 "^It's been 5 minutes. Billing service is still waiting on you.$"
rm -f "$EARSHOT_STATE_DIR/wait-q1"

echo "Safety"
say_line() { hook stop "$1" "$(jq -nc --arg m "$2" '{last_assistant_message: $m}')"; }
unset EARSHOT_LIVE_DIR
say_line z1 $'I quoted this: see the 🗣 Buy more credits line in the repo.\nDone.'
check "a 🗣 in the middle of a line is not read" 0 "Buy more"
EARSHOT_SESSION_NAME=never say_line z1 $'Done.\n🗣 '"$(printf 'word %.0s' $(seq 1 60))"
got=$(wc -w < "$OUT" | tr -d ' ')
if [ "$got" = 40 ]; then pass=$((pass + 1)); echo "  ok    the spoken line stops at 40 words"; else fail=$((fail + 1)); echo "  FAIL  the spoken line has $got words, expected 40"; fi
: > "$OUT"
hook start '../evil' '{}'
if [ ! -e "$EARSHOT_STATE_DIR/evil" ] && [ ! -e "$EARSHOT_STATE_DIR/live/../evil" ]; then pass=$((pass + 1)); echo "  ok    a session ID with ../ is refused"; else fail=$((fail + 1)); echo "  FAIL  a session ID with ../ wrote a file"; fi
EARSHOT_REMIND_UNIT=100 hook ask z2 '{"tool_name": "Bash", "tool_input": {"command": "ls", "description": "List files"}}'
timer=$(sed -n 6p "$EARSHOT_STATE_DIR/wait-z2")
kill -0 "$timer" 2>/dev/null && running=1 || running=0
bash_ok z2 "ls" "a"; sleep 0.2
if [ "$running" = 1 ] && ! kill -0 "$timer" 2>/dev/null; then pass=$((pass + 1)); echo "  ok    answering a prompt stops its reminder timer"; else fail=$((fail + 1)); echo "  FAIL  the reminder timer kept running (started: $running)"; fi
mode=$(stat -f %Lp "$EARSHOT_STATE_DIR/live/z2")
if [ "$mode" = 600 ]; then pass=$((pass + 1)); echo "  ok    state files are private (600)"; else fail=$((fail + 1)); echo "  FAIL  state file mode is $mode"; fi
: > "$OUT"

echo "EARSHOT_STYLE"
style_says() { # style_says <name> <style> <expected count> <pattern>
  local got
  got=$(jq -nc --arg cwd "$P" '{session_id: "st", cwd: $cwd}' | EARSHOT_STYLE=$2 bash "$S" start | grep -c -- "$4")
  if [ "$got" = "$3" ]; then pass=$((pass + 1)); echo "  ok    $1"; else fail=$((fail + 1)); echo "  FAIL  $1 (matched $got, expected $3)"; fi
}
style_says "plain by default" "" 1 "the way a coworker talks out loud: casual"
style_says "plain: no humor rule" plain 0 "drop the style"
style_says "upbeat asks for encouragement" upbeat 1 "upbeat coworker"
style_says "cheeky asks for a light joke" cheeky 1 "cheeky sense of humor"
style_says "cheeky stays plain on failures" cheeky 1 "drop the style and say it plainly"
style_says "styles keep the 25 word cap" cheeky 1 "25 words at most"
style_says "unknown style falls back to plain" loud 1 "the way a coworker talks out loud: casual"
: > "$OUT"

rm -rf "$T" "$EARSHOT_STATE_DIR"
rm -f "$OUT" "$EARSHOT_CONF"
echo "$pass passed, $fail failed"; [ "$fail" = 0 ]
