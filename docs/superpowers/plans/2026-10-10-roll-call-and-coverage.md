# Roll call and coverage Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ignore Voice Control's dictation process, speak MCP input dialogs, give updates during one long command, polish the catch-up, and add a roll call of every open session.

**Architecture:** Everything stays in `scripts/speak.sh` plus `hooks/hooks.json`, following its pattern: hook modes in the final `case`, internal modes (`remind`, `release`, new `longbeat`, `rollcall`) dispatched before the hook input is read. A per-session status file feeds the roll call. A new skill `skills/rollcall/SKILL.md` gives the `/earshot:rollcall` command.

**Tech Stack:** bash 3.2 (`/bin/bash`), BSD userland, `jq`, `lockf`, Swift helper, Claude Code hooks (`Elicitation`, `ElicitationResult`, `Notification`, `PreToolUse` with `async`).

**Spec:** `docs/superpowers/specs/2026-10-10-roll-call-and-coverage-design.md`

## Global Constraints

- bash 3.2: no associative arrays, no `mapfile`, no `${var,,}`.
- Synchronous hooks return in about 50 ms. The new `PreToolUse` Bash hook is `"async": true`.
- New state files live in `$STATE` and are private (`umask 077` already).
- `beat` lines (progress) speak only at levels `normal` and `all`.
- Roll call kind is `roll`: never held, plays when muted or `/voice` is off.
- Roll call: order `needs`/`reply`, `stuck`/`failed`, `working`, `done`, other; at most 6 sessions then "And N more."; empty: "No Claude sessions are open."
- Spoken copy and README: plain words, no em dashes.
- Work in a worktree on branch `roll-call`.

## Review Focus

1. **A long command whose timer never stops.** If `PreToolUse` (async) finishes after its own `PostToolUse`, the running file outlives the command. Expected: the next tool call, `stop`, `fail` or `end` cleans it up, and no update is spoken for a command that ended. Test: in Task 3, `pretool` after `tool` for the same id, then `stop`; no update within 3 s.
2. **`EARSHOT_BEAT_SECS=0` or tiny.** Expected: the long-command timer never spins faster than once a second. Test: Task 3 runs with the suite's `EARSHOT_BEAT_SECS=0` export for one case and counts at most 3 updates in 2.5 s.
3. **Roll call while muted, `/voice` off, or on a call.** Expected: it still plays. Test: Task 5 checks the mic-busy case; the mute and `/voice` checks need the real `~/.config` and `settings.json`, so they are covered by reading the guard and by the manual hotkey check.
4. **A session with a live file but no status file** (opened before this update). Expected: roll call says "<project> is open." Test in Task 5.
5. **A turn that ends with no 🗣 line.** Expected: a `working` session becomes `done` with no detail, and a `done` session keeps its last line. Test in Task 5.

---

### Task 1: Ignore Voice Control's dictation process

**Files:**
- Modify: `scripts/mic-in-use.swift` (the `ignored` list)
- Modify: `README.md` (Limits)

- [ ] **Step 1: Create the worktree**

```bash
git worktree add -q .claude/worktrees/roll-call -b roll-call main
cd .claude/worktrees/roll-call
```

- [ ] **Step 2: Extend the ignore list**

In `scripts/mic-in-use.swift`, replace:

```swift
let ignored = ["com.apple.corespeechd", "com.apple.SpeechRecognitionCore", "com.apple.speech."]
```

with:

```swift
// Voice Control listens through the dictation input method (ironwood) and
// the speech recognizer, both all day. macOS dictation uses ironwood too.
let ignored = ["com.apple.corespeechd", "com.apple.SpeechRecognitionCore", "com.apple.speech.",
               "com.apple.inputmethod.ironwood"]
```

- [ ] **Step 3: Build and check**

```bash
swiftc -O scripts/mic-in-use.swift -o /tmp/mic-in-use && /tmp/mic-in-use --list; echo "exit $?"
```

Expected: `exit 1` with nothing capturing. The Voice Control run on 2026-10-10 showed `com.apple.inputmethod.ironwood counts`; with this list it reads `ignored`.

- [ ] **Step 4: README Limits**

In `README.md`, replace:

```markdown
- Earshot cannot tell a call from other apps that use the microphone, such as a voice recorder. It waits for any of them. Siri and Voice Control do not count.
```

with:

```markdown
- Earshot cannot tell a call from other apps that use the microphone, such as a voice recorder. It waits for any of them. Siri and Voice Control do not count, and neither does macOS dictation (Fn Fn), because Voice Control uses the same process. Claude Code's `/voice` does count.
```

- [ ] **Step 5: Run tests and commit**

```bash
bash tests/stuck-and-levels.sh | tail -1
git add scripts/mic-in-use.swift README.md
git commit -m "Ignore Voice Control's dictation process in the mic check"
```

Expected: `66 passed, 0 failed`.

---

### Task 2: MCP input dialogs

**Files:**
- Modify: `hooks/hooks.json`
- Modify: `scripts/speak.sh` (`clear_wait`, new modes `elicit`, `answered`, `inputnotify`, header comment)
- Test: `tests/stuck-and-levels.sh`

**Interfaces:**
- Produces: wait file kind `input` with `what` = "for <server>" (or empty). Modes `elicit`, `answered`, `inputnotify`.

- [ ] **Step 1: Write the failing tests**

Add before the cleanup lines (`rm -rf "$T" "$EARSHOT_STATE_DIR"`):

```bash
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
hook end m1 '{}'; hook end m0 '{}'; hook end m2 '{}'; : > "$OUT"
```

- [ ] **Step 2: Run to see them fail**

`bash tests/stuck-and-levels.sh | sed -n '/MCP input/,$p'`. Expected: the three checks FAIL (unknown modes say nothing).

- [ ] **Step 3: Hooks**

In `hooks/hooks.json`, add these entries to the top-level `hooks` object:

```json
    "Elicitation": [{ "hooks": [{ "type": "command", "command": "bash \"${CLAUDE_PLUGIN_ROOT}/scripts/speak.sh\" elicit" }] }],
    "ElicitationResult": [{ "hooks": [{ "type": "command", "command": "bash \"${CLAUDE_PLUGIN_ROOT}/scripts/speak.sh\" answered" }] }],
```

and add to the `Notification` array:

```json
      { "matcher": "elicitation_dialog|elicitation_url_dialog", "hooks": [{ "type": "command", "command": "bash \"${CLAUDE_PLUGIN_ROOT}/scripts/speak.sh\" inputnotify" }] }
```

- [ ] **Step 4: Modes**

In `scripts/speak.sh`, header comment line 3: add `elicit | answered | inputnotify | pretool` to the hook mode list (pretool is Task 3).

In `clear_wait`, change the timer check regex `'/speak\.sh (ask|question)$'` to `'/speak\.sh (ask|question|elicit)$'`.

Add to the final `case`, after `question)`:

```bash
elicit)
  # Elicitation: an MCP server asks you for input. Record it and start the
  # reminders; inputnotify speaks first, after about 6 seconds. Printing
  # nothing lets the dialog open as usual.
  server=$(jq -r '.mcp_server_name // empty' <<<"$input" | sed 's/^claude_ai_//' | tr '_-' '  ')
  new_wait input "${server:+for $server}"; start_timer "$sid" "$token"
  ;;
answered)
  # ElicitationResult: you answered the MCP server.
  clear_wait
  ;;
inputnotify)
  # Notification elicitation_dialog: the input dialog has waited about 6 seconds.
  { read -r _; read -r _; read -r _; read -r what; } 2>/dev/null < "$(wait_file "$sid")"
  tell need "Hey, $who needs your input${what:+ $what}."
  ;;
```

- [ ] **Step 5: Run tests and commit**

`bash tests/stuck-and-levels.sh | tail -1` → all pass. Validate the JSON: `jq . hooks/hooks.json >/dev/null && echo ok`.

```bash
git add hooks/hooks.json scripts/speak.sh tests/stuck-and-levels.sh
git commit -m "Say when an MCP server is waiting for your input"
```

---

### Task 3: Updates during one long command

**Files:**
- Modify: `hooks/hooks.json` (PreToolUse Bash, async)
- Modify: `scripts/speak.sh` (`running` path, `watch_command`, `stop_watch`, `longbeat` and `pretool` modes, calls in `start`, `tool`, `toolfail`, `stop`, `fail`, `end`)
- Test: `tests/stuck-and-levels.sh`

**Interfaces:**
- Produces: `$STATE/running-$sid`: token, spoken name (`$on`), description, timer PID. `stop_watch` (no args).

- [ ] **Step 1: Write the failing tests**

```bash
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
```

- [ ] **Step 2: Run to see them fail**

Expected: "gets an update while it runs" FAIL; the zero-update checks pass trivially (the mode does not exist yet). That is fine: they guard the implementation.

- [ ] **Step 3: Hook**

In `hooks/hooks.json`, add to the `PreToolUse` array:

```json
      { "matcher": "Bash", "hooks": [{ "type": "command", "command": "bash \"${CLAUDE_PLUGIN_ROOT}/scripts/speak.sh\" pretool", "async": true }] }
```

- [ ] **Step 4: The timer and its stop**

In `scripts/speak.sh`, directly after the `remind` block's closing `fi`, add:

```bash
# longbeat <session> <token> <seconds>: one update while a long command runs.
# It runs this script again, so the /voice and mute checks apply.
if [ "$1" = longbeat ]; then
  sid=$2
  { read -r token; read -r on; read -r desc; } 2>/dev/null < "$STATE/running-$2" || exit 0
  [ "$token" = "$3" ] || exit 0
  line="Still on $on, about $(( $4 / 60 )) minutes in."
  [ -n "$desc" ] && line="$line Latest step: $(lower_first "$desc")."
  tell beat "$line"
  exit 0
fi

# watch_command <session> <token>: while the same command runs, says an update
# each time one is due, at most once a second. The command's PostToolUse
# removes the running file and stops it.
watch_command() {
  local sid=$1 token=$2 self=$0
  (
    while :; do
      read -r start beat _ < "$STATE/turn-$sid" 2>/dev/null || exit 0
      wait=$((beat + BEAT_SECS - $(date +%s))); [ "$wait" -lt 1 ] && wait=1
      sleep "$wait"
      [ "$(head -1 "$STATE/running-$sid" 2>/dev/null)" = "$token" ] || exit 0
      t=$(date +%s)
      bash "$self" longbeat "$sid" "$token" $((t - start))
      [ -f "$STATE/turn-$sid" ] && echo "$start $t" > "$STATE/turn-$sid"
    done
  ) </dev/null >/dev/null 2>&1 &
  echo $! >> "$STATE/running-$sid"   # line 4, so the end of the command can stop it
}
```

After the line `hist="$STATE/hist-$sid"; errs=...` add:

```bash
running="$STATE/running-$sid"   # a long command in progress: token, name, step, timer PID

# stop_watch: the command ended (or the turn did), so stop its update timer.
stop_watch() {
  local pid
  [ -f "$running" ] || return 0
  pid=$(sed -n 4p "$running")
  [ -n "$pid" ] && ps -o command= -p "$pid" 2>/dev/null | grep -q '/speak\.sh pretool$' && { pkill -P "$pid" 2>/dev/null; kill "$pid" 2>/dev/null; }
  rm -f "$running"
}
```

- [ ] **Step 5: The mode and the stop calls**

Add to the final `case`:

```bash
pretool)
  # PreToolUse for Bash (async): one long command fires no other hook until it
  # ends, so a timer gives the "still on it" updates while it runs.
  [ "$(jq -r '.tool_input.run_in_background // false' <<<"$input")" = true ] && exit 0
  case "$LEVEL" in normal|all) ;; *) exit 0 ;; esac
  stop_watch
  [ -f "$state" ] || echo "$now $now" > "$state"
  token=$(jq -r '.tool_use_id // empty' <<<"$input"); [ -n "$token" ] || token="$now-$$"
  printf '%s\n%s\n%s\n' "$token" "$on" "$(jq -r '.tool_input.description // empty' <<<"$input")" > "$running"
  watch_command "$sid" "$token"
  ;;
```

Call `stop_watch` as the first line of the `start)`, `tool)`, `toolfail)` (before the `is_interrupt` exit), `stop)`, `fail)` and `end)` branches.

- [ ] **Step 6: Run tests and commit**

`bash tests/stuck-and-levels.sh | tail -1` → all pass; `jq . hooks/hooks.json >/dev/null`.

```bash
git add hooks/hooks.json scripts/speak.sh tests/stuck-and-levels.sh
git commit -m "Give progress updates while one long command runs"
```

---

### Task 4: Catch-up polish

**Files:**
- Modify: `scripts/speak.sh` (`hold`, `catch_up`, `release`)
- Test: `tests/stuck-and-levels.sh`

- [ ] **Step 1: Change and add tests**

Replace the existing check:

```bash
order_check "three reminders for one prompt become the newest one" "Waiting 10.|"
```

with:

```bash
order_check "three lines for one prompt keep the first, most specific one" "Waiting 2.|"
```

Add after the "Prompts answered without a hook" section:

```bash
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
```

- [ ] **Step 2: Run to see them fail**

Expected: the "keep the first" check and the three log checks FAIL.

- [ ] **Step 3: Implement**

In `hold`, after the `printf ... | lockf ...` pipeline, add:

```bash
  echo "$(date '+%F %T') held ($1): $2" >> "$LOG"
```

and change the watcher start from `lockf -t 0 -k` to `lockf -t 5 -k`, with the comment `# One watcher at a time. Waiting 5 s covers a watcher that is just exiting.`

In `catch_up`, replace the awk program's first rule:

```awk
$1 >= min { last[$2 FS $3] = $0 }
```

with:

```awk
$1 >= min { k = $2 FS $3; if ($3 != "need" || !(k in last)) last[k] = $0 }
```

and update the comment above `catch_up` to: `# catch_up: says the held lines: per session, the first "needs you" line (the
# most specific one) and the newest line of every other kind; lines that need
# you first, then alerts, then finished lines, oldest first.`

In the `kept` loop, change:

```bash
    [ "$kind" = need ] && ! still_waiting "$s" && continue
```

to:

```bash
    if [ "$kind" = need ] && ! still_waiting "$s"; then
      echo "$(date '+%F %T') skipped (answered): $text" >> "$LOG"; continue
    fi
```

In the `release` block, replace:

```bash
    [ $(( $(date +%s) - began )) -ge "$HOLD_MAX" ] && { rm -f "$HELD"; break; }
```

with:

```bash
    if [ $(( $(date +%s) - began )) -ge "$HOLD_MAX" ]; then
      n=$(wc -l < "$HELD" | tr -d ' ')
      lockf -k "$HELD.lock" rm -f "$HELD"
      echo "$(date '+%F %T') dropped $n held line$([ "$n" = 1 ] || echo s) after $((HOLD_MAX / 3600)) hours" >> "$LOG"
      break
    fi
```

- [ ] **Step 4: Run tests and commit**

```bash
bash tests/stuck-and-levels.sh | tail -1
git add scripts/speak.sh tests/stuck-and-levels.sh
git commit -m "Catch-up keeps the specific line, logs what it holds and drops"
```

---

### Task 5: Roll call

**Files:**
- Modify: `scripts/speak.sh` (PATH, check guard, `speak`/`play` roll bypass, `status` path, `set_status`, calls in hook modes, `rollcall` mode, `start` skip)
- Create: `skills/rollcall/SKILL.md`
- Test: `tests/stuck-and-levels.sh`

**Interfaces:**
- Produces: `$STATE/status-$sid`: state, since, spoken name, detail. `set_status <state> [detail]`. Mode `rollcall [--print]`.

- [ ] **Step 1: Write the failing tests**

```bash
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
rm -f "$EARSHOT_LIVE_DIR"/* "$EARSHOT_STATE_DIR"/status-c*; unset EARSHOT_LIVE_DIR; : > "$OUT"
```

(`Q` is the `invoice-api` project made in the "Which session is talking" section; `order_check`, `at_least`, `held_check` and `mic` come from earlier sections.)

- [ ] **Step 2: Run to see them fail**

Expected: every roll call check FAILs (no `rollcall` mode yet).

- [ ] **Step 3: Script top**

In `scripts/speak.sh`, after `umask 077`, add:

```bash
# Shortcuts and other launchers run scripts with a short PATH; jq is usually here.
PATH=$PATH:/opt/homebrew/bin:/usr/local/bin
```

Replace the two lines:

```bash
[ "$(jq -r '.voice.enabled // .voiceEnabled // false' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json" 2>/dev/null)" = true ] || exit 0
[ -e ~/.config/earshot/mute ] && exit 0
```

with:

```bash
# A roll call is something you asked for, so it plays even when muted or with
# /voice off. ($4 is the kind when play runs a line.)
if [ "$1" != rollcall ] && ! { [ "$1" = play ] && [ "$4" = roll ]; }; then
  [ "$(jq -r '.voice.enabled // .voiceEnabled // false' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json" 2>/dev/null)" = true ] || exit 0
  [ -e ~/.config/earshot/mute ] && exit 0
fi
```

In `speak`, change the hold line to:

```bash
  if [ "$2" != roll ] && [ "$HOLD" = on ] && mic_state; then hold "$2" "$1" "$3"; return; fi
```

In `play`, change the re-hold line to:

```bash
  if [ "$3" != roll ] && [ "$HOLD" = on ] && mic_state; then hold "$3" "$4" "$5"; return; fi
```

- [ ] **Step 4: The roll call mode**

After the `longbeat` block, add:

```bash
# --- Roll call --------------------------------------------------------------------
# rollcall [--print]: says what every open session is doing, the ones that need
# you first. From a hotkey or /earshot:rollcall; --print also prints the line.
count_words=(No One Two Three Four Five Six Seven Eight Nine)
if [ "$1" = rollcall ]; then
  LIVE=${EARSHOT_LIVE_DIR:-$STATE/live}
  find "$LIVE" -type f -mmin +360 -delete 2>/dev/null
  now=$(date +%s); rows=""
  for f in "$LIVE"/*; do
    [ -f "$f" ] || continue
    s=${f##*/}
    st=open; since=0; name=""; detail=""
    { read -r st; read -r since; read -r name; read -r detail; } 2>/dev/null < "$STATE/status-$s"
    [ -n "$name" ] || name=$(head -1 "$f")
    Name=$(upper_first "$name")
    case "$st" in
      needs) r=0; text="$Name $detail." ;;
      reply) r=0; text="$Name is waiting on your answer." ;;
      stuck) r=1; text="$Name might be stuck." ;;
      failed) r=1; text="$Name hit an error." ;;
      working)
        r=2; start=$since; read -r start _ 2>/dev/null < "$STATE/turn-$s"
        m=$(( (now - start) / 60 ))
        case "$m" in 0) text="$Name is working, just started." ;; 1) text="$Name is working, 1 minute in." ;; *) text="$Name is working, $m minutes in." ;; esac ;;
      done)
        r=3
        if [ -n "$detail" ]; then
          case "$detail" in *[.!?]) ;; *) detail="$detail." ;; esac
          text="$Name finished: $(lower_first "$detail")"
        else text="$Name finished."
        fi ;;
      *) r=4; text="$Name is open." ;;
    esac
    rows="$rows$r ${since:-0} $text"$'\n'
  done
  total=$(printf '%s' "$rows" | grep -c .)
  if [ "$total" = 0 ]; then line="No Claude sessions are open."
  else
    if [ "$total" -le 9 ]; then line="${count_words[$total]} session$([ "$total" = 1 ] || echo s)."
    else line="$total sessions."; fi
    line="$line $(printf '%s' "$rows" | sort -k1,1n -k2,2n | head -6 | cut -d' ' -f3- | tr '\n' ' ' | sed 's/ $//')"
    [ "$total" -gt 6 ] && line="$line And $((total - 6)) more."
  fi
  [ "$2" = --print ] && { echo "$line"; say "$line" roll ""; exit 0; }
  if [ -n "$EARSHOT_DRYRUN" ]; then speak "$line" roll ""; else speak "$line" roll "" </dev/null >/dev/null 2>&1; fi
  exit 0
fi
```

- [ ] **Step 5: Status from the hooks**

After the line `running="$STATE/running-$sid" ...` add:

```bash
status="$STATE/status-$sid"   # for the roll call: state, since, spoken name, detail

# set_status <state> [detail]: what this session is doing, for the roll call.
set_status() { printf '%s\n%s\n%s\n%s\n' "$1" "$now" "$who" "$2" > "$status"; }
```

`new_wait` gets the status, after its `printf`:

```bash
  case "$1" in
    permission) set_status needs "needs your OK${2:+ $2}" ;;
    question) set_status needs "has a question for you" ;;
    input) set_status needs "needs your input${2:+ $2}" ;;
  esac
```

`warn_once` becomes:

```bash
warn_once() { [ -s "$warned" ] && return; echo "$1" > "$warned"; set_status stuck; tell alert "$2"; }
```

In the hook modes:

- `begin)`: `set_status open`
- `end)`: add `"$status"` to its `rm -f` list.
- `start)`: first lines become:

```bash
start)
  stop_watch
  # /earshot:rollcall speaks for itself, so this turn gets no 🗣 line.
  case "$(jq -r '.prompt // empty' <<<"$input")" in /earshot:rollcall*) exit 0 ;; esac
  clear_wait
  set_status working
```

- `tool)` and `toolfail)`: after `clear_wait`, add `[ "$(head -1 "$status" 2>/dev/null)" = needs ] && set_status working`
- `idle)`: in the `*'?')` branch, call `set_status reply` before `tell reply`.
- `stop)`: before `# With other sessions open, say whose summary it is.`, add:

```bash
  # The roll call keeps the line, at most 15 words. A turn with no line ends a
  # working session but keeps a finished session's last line.
  if [ -n "$line" ]; then set_status done "$(awk '{for (i = 1; i <= NF && i <= 15; i++) printf "%s%s", $i, (i < NF && i < 15 ? " " : "")}' <<<"$line")"
  else case "$(head -1 "$status" 2>/dev/null)" in done|open|reply) ;; *) set_status done ;; esac
  fi
```

- `fail)`: `set_status failed`

- [ ] **Step 6: The command**

Create `skills/rollcall/SKILL.md`:

```markdown
---
name: rollcall
description: Say what every open Claude Code session is doing, the sessions that need you first. Runs when the user types /earshot:rollcall.
disable-model-invocation: true
---

Earshot is reading this roll call aloud:

!`bash "${CLAUDE_PLUGIN_ROOT}/scripts/speak.sh" rollcall --print`

Show the roll call above to the user exactly as written, as one short paragraph, and add nothing else. Do not end with a 🗣 line.
```

- [ ] **Step 7: Run tests and commit**

```bash
bash tests/stuck-and-levels.sh | tail -1
git add scripts/speak.sh skills/rollcall/SKILL.md tests/stuck-and-levels.sh
git commit -m "Roll call: hear what every session is doing, the ones that need you first"
```

---

### Task 6: Docs, validation and release prep

**Files:**
- Modify: `README.md`, `.claude-plugin/plugin.json`, the spec's status line

- [ ] **Step 1: README**

"What you hear" table, add after the "Claude asks you a question" row:

```markdown
| An MCP server asks for input | "Hey, billing service needs your input for Linear." |
```

Change the first row to: `| Every 3 minutes of work, also during one long command | ... |` (example unchanged).

Add a `## Roll call` section after `## Use`:

```markdown
## Roll call

Ask what every open session is doing, and hear the ones that need you first:

> Three sessions. Billing service needs your OK to run the database migration.
> Invoice api is working, 12 minutes in. Docs site finished: fixed the broken links.

The roll call plays even when Earshot is muted, `/voice` is off, or you are on a call, because you asked for it.

- **In a session:** run `/earshot:rollcall`.
- **With a hotkey (no Claude turn, instant):**
  1. Open the Shortcuts app and make a new shortcut.
  2. Add the action **Run Shell Script** with this script:
     `bash ~/.claude/plugins/marketplaces/earshot/scripts/speak.sh rollcall`
  3. In the shortcut's details, click **Add Keyboard Shortcut** and press the keys you want.
```

Limits: replace "Earshot gives "still on it" updates only after a tool call ends. During one long command, Earshot is silent." with "During one long command, Earshot gives "still on it" updates for shell commands only. A long MCP call or web fetch is silent until it ends."

FAQ, add: "**Can I ask what all my sessions are doing?** Yes. Press your roll call hotkey or run `/earshot:rollcall`. See [Roll call](#roll-call)."

- [ ] **Step 2: Version and status**

`.claude-plugin/plugin.json`: `0.7.0` → `0.8.0`. Spec: `Status: implemented in 0.8.0`.

- [ ] **Step 3: Validate**

```bash
bash tests/stuck-and-levels.sh | tail -1
jq . hooks/hooks.json >/dev/null && echo hooks-ok
bash -n scripts/speak.sh scripts/setup.sh && echo syntax-ok
```

Live checks with the real key (the user hears them):
- `bash scripts/speak.sh rollcall` with this session open: a spoken roll call that names this project.
- The Shortcuts path: `env -i HOME=$HOME PATH=/usr/bin:/bin bash scripts/speak.sh rollcall --print` prints and speaks (proves the short PATH works).

- [ ] **Step 4: Commit**

```bash
git add README.md .claude-plugin/plugin.json docs/superpowers
git commit -m "Release 0.8.0: roll call, MCP input dialogs, long command updates"
```
