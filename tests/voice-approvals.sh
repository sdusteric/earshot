#!/bin/bash
# Checks voice approvals: speak.sh decide with a fake Earshot for Mac.
# The test plays the app: it reads the approval message the fake app logged
# and writes the answer file named there. Nothing is spoken (EARSHOT_DRYRUN).
# Needs /voice on, because speak.sh exits early without it.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; S=$ROOT/scripts/speak.sh
OUT=$(mktemp); export EARSHOT_DRYRUN=$OUT EARSHOT_STATE_DIR=$(mktemp -d) EARSHOT_CONF=$(mktemp)
printf 'EARSHOT_ENGINE=say\n' > "$EARSHOT_CONF"
MICST=$(mktemp); echo 1 > "$MICST"; export EARSHOT_MIC=$(mktemp)
printf '#!/bin/bash\nexit $(cat "%s")\n' "$MICST" > "$EARSHOT_MIC"; chmod +x "$EARSHOT_MIC"
export EARSHOT_MUTE=$EARSHOT_STATE_DIR/mute   # never the real mute file
# Reminders 2 "minutes" after a prompt, one second each, so a test can wait for one.
export EARSHOT_REMIND_MINS=2 EARSHOT_REMIND_UNIT=1
# Approval detection looks for the command among this shell's children.
export EARSHOT_CLAUDE_PID=$$
D=$(mktemp -d /tmp/va.XXXX); SOCK=$D/app.sock; APPLOG=$D/app.log; : > "$APPLOG"
P=$(mktemp -d)/billing-service; mkdir -p "$P"; git -C "$P" init -q
pass=0; fail=0
ok() { pass=$((pass + 1)); echo "  ok    $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL  $1"; }
expect() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got '$2', expected '$3')"; fi; }
input() { jq -nc --arg sid "$1" --arg cwd "$P" --argjson x "$2" '{session_id: $sid, cwd: $cwd} + $x'; }
hook() { input "$2" "$3" | bash "$S" "$1" >/dev/null; }
fake() { pkill -f "fake-app.zsh $SOCK" 2>/dev/null; sleep 0.1; ( zsh -f "$ROOT/tests/fake-app.zsh" "$SOCK" "$APPLOG" "$1" & ); sleep 0.3; }
took() { grep -c -- "$1" "$APPLOG"; }
BASH_PROMPT='{"tool_name":"Bash","tool_input":{"command":"pnpm run db:migrate --env staging","description":"Run the migration"}}'

# prompt <session> [json]: what Claude Code does when a prompt shows: ask and
# decide start together. decide's stdout goes to $D/out-<session>.
prompt() {
  local x=${2:-$BASH_PROMPT}
  hook ask "$1" "$x" &
  ( input "$1" "$x" | bash "$S" decide > "$D/out-$1"; echo $? > "$D/rc-$1" ) &
  sleep 1.2
}
# answer <session> <word>: the app writes the answer file it was given.
answer() {
  local f; f=$(grep -- "\"session\":\"$1\"" "$APPLOG" | grep '"answer"' | tail -1 | jq -r .answer)
  [ -n "$f" ] || { echo "no answer path for $1" >&2; return 1; }
  printf '%s\n' "$2" > "$f.tmp" && mv "$f.tmp" "$f"
}
# done_within <session> <seconds>: decide ended in time.
done_within() { local i; for ((i = 0; i < $2 * 10; i++)); do [ -f "$D/rc-$1" ] && return 0; sleep 0.1; done; return 1; }
decision() { jq -r '.hookSpecificOutput.decision.behavior // empty' "$D/out-$1" 2>/dev/null; }
alive() { pgrep -f "speak.sh decide" >/dev/null; }
fakerun() { bash -c "true; eval \"$1\"" >/dev/null 2>&1 & fakecmd=$!; disown "$fakecmd"; sleep 0.3; }

export EARSHOT_APP_SOCK=$SOCK

echo "Without the app"
rm -f "$SOCK"; t0=$(perl -MTime::HiRes=time -e 'print time')
input n1 "$BASH_PROMPT" | bash "$S" decide > "$D/out-n1"
t1=$(perl -MTime::HiRes=time -e 'print time')
awk -v a="$t0" -v b="$t1" 'BEGIN { exit !(b - a < 1) }' && ok "no app: decide ends in under 1 s" || bad "no app: decide ends in under 1 s"
expect "no app: decide prints nothing" "$(wc -c < "$D/out-n1" | tr -d ' ')" 0
fake reject; : > "$APPLOG"
prompt n2; done_within n2 3 && ok "app rejects: decide ends at once" || bad "app rejects: decide ends at once"
expect "app rejects: decide prints nothing" "$(wc -c < "$D/out-n2" | tr -d ' ')" 0

echo "The app answers"
fake ok; : > "$APPLOG"
prompt v1
m=$(grep '"type":"approval"' "$APPLOG" | grep '"session":"v1"' | head -1)
expect "the approval names the session" "$(jq -r .name <<<"$m")" "billing service"
expect "the approval says what it asks" "$(jq -r .what <<<"$m")" "to run the migration"
[ -n "$(jq -r '.id // empty' <<<"$m")" ] && ok "the approval has an id" || bad "the approval has an id"
case "$(jq -r .answer <<<"$m")" in "$EARSHOT_STATE_DIR"/answer-v1-*) ok "the answer file is in Earshot's state folder" ;; *) bad "the answer file is in Earshot's state folder" ;; esac
alive && ok "decide waits while nobody answered" || bad "decide waits while nobody answered"
answer v1 allow; done_within v1 2 && ok "allow ends decide" || bad "allow ends decide"
expect "allow prints the allow decision" "$(decision v1)" allow
expect "the output is one JSON object" "$(jq -s length "$D/out-v1" 2>/dev/null)" 1
sleep 0.3
expect "the app hears the approval closed by voice" "$(took '"session":"v1".*"state":"closed".*"by":"voice"')" 1
expect "the wait file is gone" "$(ls "$EARSHOT_STATE_DIR" | grep -c '^wait-v1$')" 0
expect "the answer file is gone" "$(ls "$EARSHOT_STATE_DIR" | grep -c '^answer-v1')" 0

: > "$APPLOG"; prompt v2; answer v2 deny; done_within v2 2
expect "deny prints the deny decision" "$(decision v2)" deny
expect "deny tells Claude why" "$(jq -r '.hookSpecificOutput.decision.message' "$D/out-v2")" "The user said no by voice."
expect "after a voice answer the status is working" "$(head -1 "$EARSHOT_STATE_DIR/status-v2")" working
sleep 2.5
expect "a voice no stops the reminders" "$(took 'still waiting on you')" 0

: > "$APPLOG"; prompt v3
answer v3 maybe; sleep 1
alive && ok "other words are ignored" || bad "other words are ignored"
expect "and the odd answer file is removed" "$(ls "$EARSHOT_STATE_DIR" | grep -c '^answer-v3')" 0
f=$(grep '"session":"v3"' "$APPLOG" | grep '"answer"' | tail -1 | jq -r .answer)
printf 'allow\n' > "${f%-*}-999-1-1"; sleep 1
alive && ok "an answer for another prompt id is ignored" || bad "an answer for another prompt id is ignored"
rm -f "${f%-*}-999-1-1"
answer v3 allow; done_within v3 2; expect "a later allow still works" "$(decision v3)" allow

echo "Answered some other way"
: > "$APPLOG"; prompt s1
hook tool s1 "$BASH_PROMPT"; done_within s1 2 && ok "the tool ran (clicked yes): decide ends" || bad "the tool ran (clicked yes): decide ends"
expect "and prints nothing" "$(wc -c < "$D/out-s1" | tr -d ' ')" 0
sleep 0.3; expect "the app hears it closed on screen" "$(took '"session":"s1".*"state":"closed".*"by":"screen"')" 1

: > "$APPLOG"; prompt s2
hook ask s2 '{"tool_name":"Edit","tool_input":{"file_path":"/x/a.py"}}'
done_within s2 2 && ok "a newer prompt replaces it: decide ends" || bad "a newer prompt replaces it: decide ends"
expect "and prints nothing" "$(wc -c < "$D/out-s2" | tr -d ' ')" 0
pkill -f "speak.sh decide"; sleep 0.2

T=$(mktemp); : > "$APPLOG"
prompt s3 "$(jq -nc --arg t "$T" --argjson b "$BASH_PROMPT" '$b + {transcript_path: $t}')"
touch -t "$(date -v+10S +%Y%m%d%H%M.%S)" "$T"
done_within s3 2 && ok "the transcript moved on (Esc): decide ends" || bad "the transcript moved on (Esc): decide ends"
expect "and prints nothing" "$(wc -c < "$D/out-s3" | tr -d ' ')" 0

: > "$APPLOG"; prompt s4
fakerun "sleep 30 # pnpm run db:migrate --env staging"
done_within s4 3 && ok "the command runs (clicked yes on a long one): decide ends" || bad "the command runs (clicked yes on a long one): decide ends"
expect "and prints nothing" "$(wc -c < "$D/out-s4" | tr -d ' ')" 0
kill "$fakecmd" 2>/dev/null

: > "$APPLOG"; EARSHOT_DECIDE_SECS=1 prompt s5
done_within s5 3 && ok "the deadline ends decide" || bad "the deadline ends decide"
expect "and prints nothing" "$(wc -c < "$D/out-s5" | tr -d ' ')" 0
sleep 0.3; expect "the app hears it timed out" "$(took '"session":"s5".*"state":"closed".*"by":"timeout"')" 1

echo "Not for questions, and today's lines stay"
: > "$APPLOG"; prompt q1 '{"tool_name":"AskUserQuestion","tool_input":{}}'
done_within q1 2 && ok "a question: decide ends at once" || bad "a question: decide ends at once"
expect "a question sends no approval" "$(took '"type":"approval"')" 0
: > "$APPLOG"; prompt l1
hook notify l1 '{"notification_type":"permission_prompt"}'; sleep 0.3
expect "the needs your OK line is still said once" "$(took 'billing service needs your OK to run the migration')" 1
answer l1 allow; done_within l1 2

pkill -f "speak.sh decide"; pkill -f "fake-app.zsh $SOCK"
rm -rf "$D" "$EARSHOT_STATE_DIR"; rm -f "$OUT" "$EARSHOT_CONF" "$MICST" "$EARSHOT_MIC"
echo "$pass passed, $fail failed"; [ "$fail" = 0 ]
