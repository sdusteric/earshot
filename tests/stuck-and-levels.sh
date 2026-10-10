#!/bin/bash
# Checks stuck detection and EARSHOT_LEVEL with simulated hook input.
# Nothing is spoken: EARSHOT_DRYRUN collects the lines instead.
# Needs a saved key and /voice on, because speak.sh exits early without them.
S="$(cd "$(dirname "$0")/.." && pwd)/scripts/speak.sh"
OUT=$(mktemp); export EARSHOT_DRYRUN=$OUT
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

rm -f "$OUT" /tmp/earshot-{hist,errs,warned,wait}-{s,l-}* /tmp/earshot-{s,l-}*
echo "$pass passed, $fail failed"; [ "$fail" = 0 ]
