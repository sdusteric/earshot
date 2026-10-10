#!/bin/bash
# Checks stuck detection and EARSHOT_LEVEL with simulated hook input.
# Nothing is spoken: EARSHOT_DRYRUN collects the lines instead.
# Needs /voice on, because speak.sh exits early without it. A throwaway config
# with a dummy key keeps your own settings out of the results.
S="$(cd "$(dirname "$0")/.." && pwd)/scripts/speak.sh"
OUT=$(mktemp); export EARSHOT_DRYRUN=$OUT EARSHOT_STATE_DIR=$(mktemp -d) EARSHOT_CONF=$(mktemp)
printf 'EARSHOT_ENGINE=elevenlabs\nEARSHOT_KEY=sk_test\nEARSHOT_VOICE=test\n' > "$EARSHOT_CONF"
# A fake mic helper, so a real call on this Mac cannot change the results.
# mic 0 = an app is capturing, mic 1 = free, mic 2 = busy but the app is unknown.
MICST=$(mktemp); echo 1 > "$MICST"
export EARSHOT_MIC=$(mktemp) EARSHOT_POLL_SECS=0.1
printf '#!/bin/bash\nexit $(cat "%s")\n' "$MICST" > "$EARSHOT_MIC"; chmod +x "$EARSHOT_MIC"
mic() { echo "$1" > "$MICST"; }
HELD=$EARSHOT_STATE_DIR/held
held_count() { cat "$HELD" 2>/dev/null | grep -c -- "$1"; }   # 0 when nothing is held
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

echo "Permission prompts say what they ask for"
hook ask pp1 '{"tool_name":"Bash","tool_input":{"command":"x","description":"Run the invoice tests"}}'
hook notify pp1 '{"notification_type":"permission_prompt"}'
check "a permission line names the command" 1 "needs your OK to run the invoice tests\.$"
hook end pp1 '{}'

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

echo "Holding lines while the mic is busy"
done_line() { hook stop "$1" "$(jq -nc --arg m "$2" '{last_assistant_message: ("Done.\n🗣 " + $m)}')"; }
held_check() { # held_check <name> <expected count> <pattern>
  local got; got=$(held_count "$3")
  if [ "$got" = "$2" ]; then pass=$((pass + 1)); echo "  ok    $1"; else fail=$((fail + 1)); echo "  FAIL  $1 (held $got, expected $2)"; fi
}
rm -f "$HELD"; mic 0
done_line h1 "Fixed the rounding bug."
check "mic busy: the finished line is not spoken yet" 0 "rounding"
held_check "mic busy: the finished line waits in the queue" 1 "rounding"
hook notify h2 '{"notification_type":"permission_prompt"}'
held_check "mic busy: needs-your-OK is held as need" 1 $'\037need\037'
EARSHOT_BEAT_SECS=0 bash_ok h3 "echo hi" "hi"
held_check "mic busy: progress updates are dropped, not held" 0 "Still on"
check "mic busy: progress updates are not spoken either" 0 "Still on"
mic 1; done_line h4 "Shipped the export."
check "mic free: the line is spoken right away" 1 "Shipped the export"
mic 2; done_line h5 "Old Mac line."
check "mic busy but the app is unknown: spoken, not held" 1 "Old Mac line"
mic 0; EARSHOT_HOLD_ON_MIC=off done_line h6 "Hold is off."
check "EARSHOT_HOLD_ON_MIC=off: spoken while the mic is busy" 1 "Hold is off"
mic 1; rm -f "$HELD"; : > "$OUT"

echo "Catch-up after the call"
held_add() { printf '%s\037%s\037%s\037%s\n' "$1" "$2" "$3" "$4" >> "$HELD"; }
held_now() { held_add "$(date +%s)" "$@"; }   # held just now: no intro
# waiting <session> [transcript]: a permission prompt that still waits for you.
waiting() { printf '%s\n' tok permission "billing service" "" "${2:-}" > "$EARSHOT_STATE_DIR/wait-$1"; }
release() { bash "$S" release </dev/null; }
order_check() { # order_check <name> <expected lines joined by |>
  local got; got=$(tr '\n' '|' < "$OUT")
  if [ "$got" = "$2" ]; then pass=$((pass + 1)); echo "  ok    $1"; else fail=$((fail + 1)); echo "  FAIL  $1 (heard: $got)"; fi
  : > "$OUT"
}
rm -f "$HELD"; mic 1
waiting c; held_now a done "Done A."; held_now b alert "Stuck B."; held_now c need "Need C."
release
order_check "needs you first, then alerts, then finished lines" "Need C.|Stuck B.|Done A.|"
waiting d; held_now d need "Waiting 2."; held_now d need "Waiting 5."; held_now d need "Waiting 10."
release
order_check "three lines for one prompt keep the first, most specific one" "Waiting 2.|"
held_add $(( $(date +%s) - 60 )) e done "Old enough."
release
order_check "a hold of 30 seconds or more gets the intro" "While you were on the mic:|Old enough.|"
held_add $(( $(date +%s) - 20000 )) f done "Too old."; held_now g done "Fresh."
release
order_check "lines older than 4 hours are dropped" "Fresh.|"
for s in 1 2 3 4 5 6; do held_now "x$s" done "Line $s."; done
release
order_check "at most 4 lines, then how many more" "Line 1.|Line 2.|Line 3.|Line 4.|And 2 more.|"
held_now q done "It's \"done\" & 50% \$HOME \\o/"
release
order_check "quotes, \$ and backslashes survive the queue" "It's \"done\" & 50% \$HOME \\o/|"
mic 0; done_line r1 "Round trip."; mic 1
release
check "a held finished line is spoken after the call" 1 "Round trip."
held_now k done "Once K."; held_now l done "Once L."
release & release; wait
check "two catch-ups at once: each line is spoken once" 2 "Once [KL]\."
mic 0; held_now m done "Never free."
EARSHOT_HOLD_MAX_SECS=1 release
if [ ! -s "$HELD" ]; then pass=$((pass + 1)); echo "  ok    a mic that never frees up: the watcher gives up"; else fail=$((fail + 1)); echo "  FAIL  the queue is still there after the cap"; fi
check "a mic that never frees up: nothing is spoken" 0 "Never free"
mic 1; rm -f "$HELD"; : > "$OUT"

echo "Answered during the call"
rm -f "$HELD"; mic 0
hook notify a1 '{"notification_type":"permission_prompt"}'
hook notify a2 '{"notification_type":"permission_prompt"}'
done_line a3 "Finished a3."
bash_ok a1 "ls" "x"
held_check "a tool call drops that session's need line" 0 $'^[0-9]*\037a1\037need'
held_check "another session's need line stays" 1 $'^[0-9]*\037a2\037need'
bash_ok a3 "ls" "x"
held_check "a session's finished line stays" 1 "Finished a3"
hook start a2 '{}'
held_check "a new prompt drops that session's need line" 0 $'^[0-9]*\037a2\037need'
mic 1; rm -f "$HELD"; : > "$OUT"

echo "Prompts answered without a hook"
rm -f "$HELD"; mic 1
held_now e1 need "Esc answered."
waiting e2; held_now e2 need "Still asking."
release
order_check "a need line whose prompt is gone is not read" "Still asking.|"
TR=$(mktemp); waiting e3 "$TR"; touch -t 202601010000 "$EARSHOT_STATE_DIR/wait-e3"; held_now e3 need "Answered by Esc."
release
order_check "a need line whose transcript moved on is not read" ""
TQ=$(mktemp); echo '{"type":"assistant","message":{"content":[{"type":"text","text":"Should I ship it?"}]}}' > "$TQ"
mic 0; hook idle e4 "$(jq -nc --arg t "$TQ" '{transcript_path: $t, notification_type: "idle_prompt"}')"
held_check "a question at the end of a turn is held as reply" 1 $'\037reply\037'
mic 1; release
check "a question at the end of a turn is read after the call" 1 "still waiting on your answer"
rm -f "$EARSHOT_STATE_DIR"/wait-e* "$TR" "$TQ"

echo "A helper that could not be rebuilt"
mic 0; touch "$EARSHOT_MIC.stale"
done_line st1 "Stale helper line."
check "a stale helper does not hold lines" 1 "Stale helper line"
held_check "a stale helper does not hold lines (queue)" 0 "Stale helper line"
rm -f "$EARSHOT_MIC.stale"; mic 1; rm -f "$HELD"; : > "$OUT"

echo "A queue with only expired lines"
rm -f "$HELD"; mic 1
held_add $(( $(date +%s) - 20000 )) old1 done "Expired."
errs=$(bash "$S" release </dev/null 2>&1)
if [ -z "$errs" ]; then pass=$((pass + 1)); echo "  ok    an expired-only queue ends quietly"; else fail=$((fail + 1)); echo "  FAIL  an expired-only queue printed: $errs"; fi
check "an expired-only queue says nothing" 0 "."
rm -f "$HELD"; : > "$OUT"

echo "MCP input dialogs"
hook elicit m1 '{"mcp_server_name":"claude_ai_Linear","message":"Pick a project"}'
hook inputnotify m1 '{"notification_type":"elicitation_dialog"}'
check "an MCP input dialog names the server" 1 "needs your input for Linear\.$"
hook inputnotify m0 '{"notification_type":"elicitation_dialog"}'
check "an input dialog with no server name" 1 "needs your input\.$"
EARSHOT_REMIND_UNIT=100 hook elicit m2 '{"mcp_server_name":"github"}'
timer=$(sed -n 6p "$EARSHOT_STATE_DIR/wait-m2")
kill -0 "$timer" 2>/dev/null && running=1 || running=0
hook answered m2 '{"mcp_server_name":"github","action":"accept"}'; sleep 0.2
if [ "$running" = 1 ] && ! kill -0 "$timer" 2>/dev/null && [ ! -e "$EARSHOT_STATE_DIR/wait-m2" ]; then pass=$((pass + 1)); echo "  ok    answering an input dialog stops its reminders"; else fail=$((fail + 1)); echo "  FAIL  the input dialog timer kept running (started: $running)"; fi
printed=$(jq -nc --arg cwd "$P" '{session_id: "m3", cwd: $cwd, mcp_server_name: "github"}' | EARSHOT_REMIND_UNIT=100 bash "$S" elicit)
if [ -z "$printed" ]; then pass=$((pass + 1)); echo "  ok    the Elicitation hook prints nothing, so the dialog opens"; else fail=$((fail + 1)); echo "  FAIL  the Elicitation hook printed: $printed"; fi
hook end m1 '{}'; hook end m0 '{}'; hook end m2 '{}'; hook end m3 '{}'; : > "$OUT"

echo "Updates during one long command"
pre() { hook pretool "$1" "$(jq -nc --arg id "$2" --argjson bg "${3:-false}" '{tool_name: "Bash", tool_use_id: $id, tool_input: {command: "npm test", description: "Run the invoice tests", run_in_background: $bg}}')"; }
at_least() { # at_least <name> <min> <pattern>
  local got; got=$(grep -c -- "$3" "$OUT")
  if [ "$got" -ge "$2" ]; then pass=$((pass + 1)); echo "  ok    $1"; else fail=$((fail + 1)); echo "  FAIL  $1 (heard $got, expected at least $2)"; fi
  : > "$OUT"
}
export EARSHOT_BEAT_SECS=1
new lc1; pre lc1 t1; sleep 2.5
at_least "a long command gets an update while it runs" 1 "Latest step: run the invoice tests"
bash_ok lc1 "npm test" "ok"; : > "$OUT"; sleep 2
check "after the command ends, the updates stop" 0 "Latest step: run the invoice tests"
new lc2; pre lc2 t2 true; sleep 2
check "a background command gets no updates" 0 "Latest step: run the invoice tests"
new lc3; EARSHOT_LEVEL=quiet pre lc3 t3; sleep 2
check "quiet level: no updates during a long command" 0 "Latest step"
new lc4; bash_ok lc4 "npm test" "ok"; pre lc4 t4; hook stop lc4 '{}'; : > "$OUT"; sleep 2.5
check "a timer that started after its command ended is stopped by stop" 0 "Latest step"
export EARSHOT_BEAT_SECS=0
new lc5; pre lc5 t5; sleep 2.5
got=$(grep -c "Latest step" "$OUT")
if [ "$got" -le 3 ]; then pass=$((pass + 1)); echo "  ok    EARSHOT_BEAT_SECS=0: at most one update a second"; else fail=$((fail + 1)); echo "  FAIL  EARSHOT_BEAT_SECS=0: $got updates in 2.5 s"; fi
for s in lc1 lc2 lc3 lc4 lc5; do hook end "$s" '{}'; done; : > "$OUT"
export EARSHOT_BEAT_SECS=1
new lc6; hook stop lc6 '{}'; : > "$OUT"; pre lc6 t6; sleep 2.5
check "a command that starts after the turn ended gets no updates" 0 "Latest step"
[ -e "$EARSHOT_STATE_DIR/turn-lc6" ] && { fail=$((fail + 1)); echo "  FAIL  pretool recreated the turn file"; } || { pass=$((pass + 1)); echo "  ok    pretool does not recreate an ended turn"; }
TL=$(mktemp); new lc7
hook pretool lc7 "$(jq -nc --arg t "$TL" '{tool_name: "Bash", tool_use_id: "t7", transcript_path: $t, tool_input: {command: "rm -rf build", description: "Delete build"}}')"
echo '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t7","content":"The user doesn'"'"'t want to proceed"}]}}' >> "$TL"; sleep 2.5
check "a rejected command (result in the transcript, no hook) gets no updates" 0 "Latest step"
new lc8; pre lc8 t8; EARSHOT_REMIND_UNIT=100 hook ask lc8 '{"tool_name":"Bash","tool_input":{"command":"x","description":"Delete build"}}'; : > "$OUT"; sleep 2.5
check "no updates while the command waits for your OK" 0 "Latest step"
new lc9; EARSHOT_LONG_MAX_SECS=2 pre lc9 t9; sleep 4.5; : > "$OUT"; sleep 2
check "updates stop after the cap" 0 "Latest step"
new lc10; hook pretool lc10 '{"tool_name":"Bash","tool_use_id":"t10","tool_input":{"command":"x","description":"Line one\nline two"}}'
pidline=$(sed -n 4p "$EARSHOT_STATE_DIR/running-lc10")
case "$pidline" in ''|*[!0-9]*) fail=$((fail + 1)); echo "  FAIL  a two-line description moved the timer PID: $pidline" ;; *) pass=$((pass + 1)); echo "  ok    a two-line description keeps the timer PID on line 4" ;; esac
export EARSHOT_BEAT_SECS=0
for s in lc1 lc2 lc3 lc4 lc5 lc6 lc7 lc8 lc9 lc10; do hook end "$s" '{}'; done; rm -f "$TL"; : > "$OUT"

echo "The log"
LOGF=$EARSHOT_STATE_DIR/earshot.log; rm -f "$LOGF" "$HELD"
mic 0; done_line lg1 "Logged line."; mic 1
log_check() { # log_check <name> <pattern>
  if grep -q -- "$2" "$LOGF" 2>/dev/null; then pass=$((pass + 1)); echo "  ok    $1"; else fail=$((fail + 1)); echo "  FAIL  $1 (log: $(tail -2 "$LOGF" 2>/dev/null))"; fi
}
log_check "a held line is logged" "held (done): .*Logged line"
rm -f "$HELD"; held_now lg2 need "Esc in the log."
release
log_check "a skipped answered prompt is logged" "skipped (answered): Esc in the log"
mic 0; held_now lg3 done "Capped."
EARSHOT_HOLD_MAX_SECS=1 release
log_check "lines dropped at the cap are logged" "dropped 1 held line"
mic 1; rm -f "$HELD"; : > "$OUT"

echo "Roll call"
export EARSHOT_LIVE_DIR=$EARSHOT_STATE_DIR/live-roll; mkdir -p "$EARSHOT_LIVE_DIR"
R=$(dirname "$P")/docs-site; mkdir -p "$R"; git -C "$R" init -q
G=$(dirname "$P")/api-gateway; mkdir -p "$G"; git -C "$G" init -q
at() { # at <mode> <session> <cwd> <json-extra>
  jq -nc --arg sid "$2" --arg cwd "$3" --argjson x "$4" '{session_id: $sid, cwd: $cwd} + $x' | bash "$S" "$1" >/dev/null
}
roll() { bash "$S" rollcall </dev/null; }
at start r1 "$P" '{}'; at ask r1 "$P" '{"tool_name":"Bash","tool_input":{"command":"x","description":"Run the database migration"}}'
at start r2 "$Q" '{}'
at start r3 "$R" '{}'; at stop r3 "$R" '{"last_assistant_message":"Done.\n🗣 Fixed the broken links."}'
at start r4 "$G" '{}'; for i in 1 2 3; do at toolfail r4 "$G" '{"tool_name":"Bash","tool_input":{"command":"make"},"error":"Exit code 2\nmake: *** [all] Error 2"}'; done
: > "$OUT"; roll
order_check "roll call: needs you, stuck, working, finished" "Four sessions. Billing service needs your OK to run the database migration. Api gateway might be stuck. Invoice api is working, just started. Docs site finished: fixed the broken links.|"
at tool r1 "$P" '{"tool_name":"Bash","tool_input":{"command":"x"},"tool_response":{}}'
st=$(head -1 "$EARSHOT_STATE_DIR/status-r1")
if [ "$st" = working ]; then pass=$((pass + 1)); echo "  ok    answering a prompt sets the session back to working"; else fail=$((fail + 1)); echo "  FAIL  status after answering: $st"; fi
at stop r2 "$Q" '{"last_assistant_message":"No voice line here."}'
at start r3 "$R" '{"prompt":"/earshot:rollcall"}'; at stop r3 "$R" '{"last_assistant_message":"Here it is."}'
: > "$OUT"; roll
order_check "no 🗣 line: working becomes done, done keeps its line" "Four sessions. Api gateway might be stuck. Billing service is working, just started. Docs site finished: fixed the broken links. Invoice api finished.|"
printf '%s\n%s\n' "old project" "" > "$EARSHOT_LIVE_DIR/r5"
: > "$OUT"; roll
at_least "a session without a status file is open" 1 "Old project is open\."
mic 0; : > "$OUT"; roll; mic 1
at_least "roll call plays while the mic is busy" 1 "^Five sessions"
held_check "roll call is never held" 0 "sessions"
printed=$(bash "$S" rollcall --print </dev/null)
case "$printed" in "Five sessions."*) pass=$((pass + 1)); echo "  ok    --print prints the roll call" ;; *) fail=$((fail + 1)); echo "  FAIL  --print printed: $printed" ;; esac
out=$(jq -nc --arg cwd "$P" '{session_id: "r1", cwd: $cwd, prompt: "/earshot:rollcall"}' | bash "$S" start)
case "$out" in *🗣*) fail=$((fail + 1)); echo "  FAIL  /earshot:rollcall still asks for a 🗣 line" ;; *) pass=$((pass + 1)); echo "  ok    /earshot:rollcall does not ask for a 🗣 line" ;; esac
for s in r1 r2 r3 r4 r5; do at end "$s" "$P" '{}'; done; rm -f "$EARSHOT_LIVE_DIR"/*
: > "$OUT"; roll
order_check "no sessions" "No Claude sessions are open.|"
for i in 1 2 3 4 5 6 7; do printf '%s\n%s\n' "project $i" "" > "$EARSHOT_LIVE_DIR/c$i"; printf '%s\n%s\n%s\n%s\n' done "$i" "project $i" "" > "$EARSHOT_STATE_DIR/status-c$i"; done
: > "$OUT"; roll
order_check "seven sessions: six, then how many more" "Seven sessions. Project 1 finished. Project 2 finished. Project 3 finished. Project 4 finished. Project 5 finished. Project 6 finished. And 1 more.|"
rm -f "$EARSHOT_LIVE_DIR"/* "$EARSHOT_STATE_DIR"/status-c*
printf '%s\n%s\n' "billing service" "Tax export" > "$EARSHOT_LIVE_DIR/n1"
printf '%s\n%s\n' "billing service" "Refund rounding" > "$EARSHOT_LIVE_DIR/n2"
printf '%s\n%s\n' "docs site" "Broken links" > "$EARSHOT_LIVE_DIR/n3"
: > "$OUT"; roll
order_check "two sessions in one project are told apart by title" "Three sessions. Docs site is open. The refund rounding session in billing service is open. The tax export session in billing service is open.|"
printf '%s\n%s\n%s\n%s\n' working "" "docs site" "" > "$EARSHOT_STATE_DIR/status-n3"
: > "$OUT"; roll
at_least "a damaged status file reads as just started" 1 "Docs site is working, just started"
rm -f "$EARSHOT_LIVE_DIR"/* "$EARSHOT_STATE_DIR/status-n3"
at start b1 "$P" '{}'; at begin b1 "$P" '{"source":"compact"}'
st=$(head -1 "$EARSHOT_STATE_DIR/status-b1")
[ "$st" = working ] && { pass=$((pass + 1)); echo "  ok    compacting a working session keeps it working"; } || { fail=$((fail + 1)); echo "  FAIL  after compact the status is $st"; }
at start b2 "$P" '{}'; for i in 1 2 3; do at toolfail b2 "$P" '{"tool_name":"Bash","tool_input":{"command":"make"},"error":"Exit code 2\nmake: *** [all] Error 2"}'; done
EARSHOT_REMIND_UNIT=100 at ask b2 "$P" '{"tool_name":"Bash","tool_input":{"command":"x"}}'; at tool b2 "$P" '{"tool_name":"Bash","tool_input":{"command":"x"},"tool_response":{}}'
st=$(head -1 "$EARSHOT_STATE_DIR/status-b2")
[ "$st" = stuck ] && { pass=$((pass + 1)); echo "  ok    stuck lasts until the turn ends"; } || { fail=$((fail + 1)); echo "  FAIL  stuck became $st"; }
out=$(jq -nc --arg cwd "$P" '{session_id: "b1", cwd: $cwd, prompt: "/rollcall"}' | bash "$S" start)
case "$out" in *🗣*) fail=$((fail + 1)); echo "  FAIL  bare /rollcall still asks for a 🗣 line" ;; *) pass=$((pass + 1)); echo "  ok    bare /rollcall does not ask for a 🗣 line" ;; esac
printf 'x\n' > "$EARSHOT_STATE_DIR/status-gone"; touch -t 202601010000 "$EARSHOT_STATE_DIR/status-gone"
at stop b1 "$P" '{}'
[ -e "$EARSHOT_STATE_DIR/status-gone" ] && { fail=$((fail + 1)); echo "  FAIL  an old status file was kept"; } || { pass=$((pass + 1)); echo "  ok    status files of sessions gone for 6 hours are removed"; }
at end b1 "$P" '{}'; at end b2 "$P" '{}'
SK="$(dirname "$S")/../skills/rollcall/SKILL.md"
rule=$(sed -n 's/^allowed-tools: Bash(\(.*\))$/\1/p' "$SK"); body=$(sed -n 's/^!`\(.*\)`$/\1/p' "$SK")
[ -n "$rule" ] && [ "$rule" = "$body" ] && { pass=$((pass + 1)); echo "  ok    the rollcall command is pre-approved by its own allowed-tools rule"; } || { fail=$((fail + 1)); echo "  FAIL  allowed-tools ($rule) does not match the command ($body)"; }
rm -f "$EARSHOT_LIVE_DIR"/*; unset EARSHOT_LIVE_DIR; : > "$OUT"

echo "Approved commands and other long calls"
approves() { # approves <name> <expected: working|waiting> <session>: asks the session's reminder
  local got; : > "$OUT"
  bash "$S" remind "$3" "$(head -1 "$EARSHOT_STATE_DIR/wait-$3")" 5 </dev/null
  if grep -q "still waiting on you" "$OUT"; then got=waiting; else got=working; fi
  if [ "$got" = "$2" ]; then pass=$((pass + 1)); echo "  ok    $1"; else fail=$((fail + 1)); echo "  FAIL  $1 (roll call: $(cat "$OUT"))"; fi
  at end "$3" "$P" '{}'; : > "$OUT"
}
fakerun() { bash -c "true; eval \"$1\"" >/dev/null 2>&1 & fakecmd=$!; disown "$fakecmd"; sleep 0.3; }   # a child of this shell
# The test shell plays Claude Code: an approved command is a child process
# whose arguments hold the command text.
export EARSHOT_CLAUDE_PID=$$ EARSHOT_BEAT_SECS=1 EARSHOT_LIVE_DIR=$EARSHOT_STATE_DIR/live-ap; mkdir -p "$EARSHOT_LIVE_DIR"
apcmd='{"tool_name":"Bash","tool_use_id":"ap-t1","tool_input":{"command":"sleep 30 # deploy-the-database-now","description":"Deploy the database"}}'
at start ap1 "$P" '{}'; at pretool ap1 "$P" "$apcmd"
EARSHOT_REMIND_UNIT=100 at ask ap1 "$P" "$apcmd"; : > "$OUT"; sleep 2.5
check "before you approve: no updates" 0 "Latest step"
: > "$OUT"; roll
at_least "before you approve: the roll call says it needs your OK" 1 "needs your OK to deploy the database"
tok=$(head -1 "$EARSHOT_STATE_DIR/wait-ap1")
bash "$S" remind ap1 "$tok" 2 </dev/null
at_least "before you approve: the reminder plays" 1 "still waiting on you"
bash -c 'true; eval "sleep 30 # deploy-the-database-now"' & fakecmd=$!   # like Claude Code's shell: source, then eval
sleep 0.3; : > "$OUT"; roll
at_least "after you approve: the roll call says it is working" 1 "is working"
bash "$S" remind ap1 "$tok" 5 </dev/null
check "after you approve: no reminder" 0 "still waiting on you"
[ -e "$EARSHOT_STATE_DIR/wait-ap1" ] && { fail=$((fail + 1)); echo "  FAIL  the wait file is still there after approval"; } || { pass=$((pass + 1)); echo "  ok    after you approve: the prompt is forgotten"; }
kill "$fakecmd" 2>/dev/null; wait "$fakecmd" 2>/dev/null
EARSHOT_REMIND_UNIT=100 at ask ap1 "$P" "$apcmd"
fakerun "sleep 30 # deploy-the-database-now"; : > "$OUT"; sleep 2.5
at_least "after you approve: updates come during the command" 1 "Latest step: deploy the database"
kill "$fakecmd" 2>/dev/null
at tool ap1 "$P" "$apcmd"
at start ap2 "$P" '{}'; at pretool ap2 "$P" '{"tool_name":"Bash","tool_use_id":"ap-t2","tool_input":{"command":"ls"}}'
EARSHOT_REMIND_UNIT=100 at ask ap2 "$P" '{"tool_name":"Bash","tool_input":{"command":"ls"}}'
bash -c 'true; eval "ls; sleep 30"' >/dev/null & fakecmd=$!; sleep 0.3; : > "$OUT"; roll
at_least "a command too short to recognize still reads as waiting" 1 "needs your OK"
kill "$fakecmd" 2>/dev/null; wait "$fakecmd" 2>/dev/null
at start ap3 "$P" '{}'; EARSHOT_LEVEL=quiet EARSHOT_REMIND_UNIT=100 at ask ap3 "$P" '{"tool_name":"Bash","tool_input":{"command":"sleep 30 # quiet-level-command"}}'
fakerun "sleep 30 # quiet-level-command"; approves "quiet level: approval is still noticed" working ap3; kill "$fakecmd" 2>/dev/null
at start ap6 "$P" '{}'; EARSHOT_REMIND_UNIT=100 at ask ap6 "$P" '{"tool_name":"Bash","tool_input":{"command":"cd /tmp/proj && sleep 30 # migrate-the-tables"}}'
fakerun "sleep 30 # migrate-the-tables"; approves "a leading cd that Claude Code strips still matches" working ap6; kill "$fakecmd" 2>/dev/null
fakerun "python3 -c 'print(1)'; sleep 30 # poll-loop"
at start ap7 "$P" '{}'; EARSHOT_REMIND_UNIT=100 at ask ap7 "$P" '{"tool_name":"Bash","tool_input":{"command":"python3 -c '"'"'import shutil; shutil.rmtree(\"build-dir\")'"'"'"}}'
approves "a background job that shares only the start does not count" waiting ap7; kill "$fakecmd" 2>/dev/null
fakerun "sleep 30 # same-command-already-running"
at start ap8 "$P" '{}'; EARSHOT_REMIND_UNIT=100 at ask ap8 "$P" '{"tool_name":"Bash","tool_input":{"command":"sleep 30 # same-command-already-running"}}'
approves "the same command already running before the prompt does not count" waiting ap8; kill "$fakecmd" 2>/dev/null
at start ap9 "$P" '{}'; EARSHOT_REMIND_UNIT=100 at ask ap9 "$P" '{"tool_name":"Bash","tool_input":{"command":"sleep 30 # an-earlier-bash-step"}}'
at tool ap9 "$P" '{"tool_name":"Bash","tool_input":{"command":"x"},"tool_response":{}}'
fakerun "sleep 30 # an-earlier-bash-step"
EARSHOT_REMIND_UNIT=100 at ask ap9 "$P" '{"tool_name":"Edit","tool_input":{"file_path":"/x/a.py"}}'
approves "an Edit prompt is never approved by an earlier command" waiting ap9; kill "$fakecmd" 2>/dev/null
at start ap10 "$P" '{}'; EARSHOT_REMIND_UNIT=100 at ask ap10 "$P" '{"tool_name":"Bash","tool_input":{"command":"sleep 30 # café-deploy-step"}}'
fakerun "sleep 30 # café-deploy-step"; approves "accented text in the command still matches" working ap10; kill "$fakecmd" 2>/dev/null
wait 2>/dev/null
: > "$OUT"
at start ap4 "$P" '{}'; at pretool ap4 "$P" '{"tool_name":"mcp__claude_ai_Linear__create_issue","tool_use_id":"ap-t4","tool_input":{}}'; sleep 2.5
at_least "a long MCP call gets updates" 1 "Latest step: use Linear"
at tool ap4 "$P" '{"tool_name":"mcp__claude_ai_Linear__create_issue","tool_input":{},"tool_response":{}}'; : > "$OUT"
at start ap5 "$P" '{}'; at pretool ap5 "$P" '{"tool_name":"WebFetch","tool_use_id":"ap-t5","tool_input":{"url":"https://example.com/docs"}}'; sleep 2.5
at_least "a long web fetch gets updates" 1 "Latest step: open example.com"
for s in ap1 ap2 ap3 ap4 ap5; do at end "$s" "$P" '{}'; done
unset EARSHOT_CLAUDE_PID EARSHOT_LIVE_DIR; export EARSHOT_BEAT_SECS=0; : > "$OUT"

rm -rf "$T" "$EARSHOT_STATE_DIR"
rm -f "$OUT" "$EARSHOT_CONF" "$MICST" "$EARSHOT_MIC"
echo "$pass passed, $fail failed"; [ "$fail" = 0 ]
