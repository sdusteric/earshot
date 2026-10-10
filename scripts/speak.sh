#!/bin/bash
# Earshot: spoken updates for Claude Code via ElevenLabs.
# Modes: start | tool | toolfail | ask | question | notify | idle | stop | fail (hooks),
# remind (internal timer), say "<text>" (manual test)
CONF=~/.config/earshot/config
[ -f "$CONF" ] && . "$CONF"
# The saved config wins, so a generic ELEVENLABS_API_KEY set for other tools
# does not replace the key you chose for Earshot.
KEY=${EARSHOT_KEY:-$ELEVENLABS_API_KEY}
VOICE=${EARSHOT_VOICE:-$ELEVENLABS_VOICE_ID}
[ -n "$KEY" ] && [ -n "$VOICE" ] || exit 0
# Talks only while /voice is on. Hooks get no signal that a prompt was
# dictated, so typed prompts get spoken updates too.
[ "$(jq -r '.voice.enabled // .voiceEnabled // false' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json" 2>/dev/null)" = true ] || exit 0
[ -e ~/.config/earshot/mute ] && exit 0

MODEL=${EARSHOT_MODEL:-eleven_v4_turbo}
BEAT_SECS=${EARSHOT_BEAT_SECS:-180}       # how often to say "still working"
LOOP_REPEATS=${EARSHOT_LOOP_REPEATS:-3}   # repeats that count as stuck (see Stuck detection)
LEVEL=${EARSHOT_LEVEL:-normal}            # quiet | normal | all (see tell)
CACHE=/tmp/earshot-cache
LOG=/tmp/earshot.log
MIC=~/.config/earshot/mic-in-use

mic_on() { [ -x "$MIC" ] && "$MIC"; }

# tell <tier> "<line>": speak only if EARSHOT_LEVEL includes the tier.
#   alert  needs you, might be stuck, failures, the final summary   every level
#   beat   "still on it" progress updates                           normal, all
#   ack    "On it" when your prompt arrives                         all
tell() {
  case "$1:$LEVEL" in
    alert:*|beat:normal|beat:all|ack:all) say "$2" ;;
  esac
}

say() {
  # Tests set EARSHOT_DRYRUN to a file: lines go there instead of the speaker.
  [ -n "$EARSHOT_DRYRUN" ] && { echo "$1" >> "$EARSHOT_DRYRUN"; return; }
  # A new line stops the line that is still playing, in every session.
  pkill -f "afplay $CACHE" 2>/dev/null
  (
    mkdir -p "$CACHE"
    out="$CACHE/$(printf '%s' "$MODEL $VOICE $1" | md5 -q).mp3"
    if [ ! -s "$out" ]; then
      # The key goes in through stdin so it never shows up in the process list.
      code=$(printf 'xi-api-key: %s\n' "$KEY" | curl -s -w '%{http_code}' -o "$out.part" \
        "https://api.elevenlabs.io/v1/text-to-speech/$VOICE" \
        -H @- -H 'Content-Type: application/json' \
        -d "$(jq -n --arg t "$1" --arg m "$MODEL" '{text: $t, model_id: $m}')")
      if [ "$code" != 200 ]; then
        echo "$(date '+%F %T') HTTP $code: $(head -c 300 "$out.part" 2>/dev/null)" >> "$LOG"
        rm -f "$out.part"
        afplay /System/Library/Sounds/Basso.aiff
        exit
      fi
      mv "$out.part" "$out"
    fi
    # Stop when you start talking. A mic that was already on (e.g. Voice
    # Control listening for a wake word) does not count.
    mic_on && mic_was_on=1
    afplay "$out" & pid=$!
    while kill -0 $pid 2>/dev/null; do
      sleep 0.5
      [ -z "$mic_was_on" ] && mic_on && kill $pid
    done
  ) >/dev/null 2>&1 &
}

[ "$1" = say ] && { say "$2"; exit 0; }

# --- Waiting on you: permission prompts and questions -------------------------
# A wait file per session holds: token, kind (permission|question), project,
# what is being asked, and the transcript path. Any later hook activity deletes
# it, which cancels reminders.
REMIND_MINS=${EARSHOT_REMIND_MINS:-2 5 10}   # minutes after a prompt to remind you
UNIT=${EARSHOT_REMIND_UNIT:-60}               # seconds per "minute"; tests set it lower
wait_file() { echo "/tmp/earshot-wait-$1"; }

# remind <session> <token> <step>: a timer step. It runs this script again, so
# the /voice and mute checks above apply at the moment it speaks.
if [ "$1" = remind ]; then
  wf=$(wait_file "$2")
  { read -r token; read -r kind; read -r proj; read -r what; read -r transcript; } 2>/dev/null < "$wf" || exit 0
  [ "$token" = "$3" ] || exit 0
  # While a prompt waits, the agent is blocked and its transcript does not
  # change. A newer transcript means you answered it, for example with Esc,
  # which fires no hook. (2s grace: the tool call itself may land just after.)
  if [ -f "$transcript" ] && [ "$(stat -f %m "$transcript")" -gt $(( $(stat -f %m "$wf") + 2 )) ]; then
    rm -f "$wf"; exit 0
  fi
  if [ "$4" = first ]; then
    tell alert "Hey, $proj has a question for you."
  else
    tell alert "Still waiting on you in $proj, $4 minute$([ "$4" = 1 ] || echo s) now."
  fi
  exit 0
fi

# start_timer <session> <token> [first]: speaks the reminders in the background.
# With "first", it also speaks the opening line after a 6 second grace period.
start_timer() {
  local sid=$1 token=$2 first=$3 self=$0
  (
    t=0
    if [ -n "$first" ]; then sleep 6; t=6; bash "$self" remind "$sid" "$token" first; fi
    for m in $REMIND_MINS; do
      sleep $((m * UNIT - t)); t=$((m * UNIT))
      [ "$(head -1 "$(wait_file "$sid")" 2>/dev/null)" = "$token" ] || exit 0
      bash "$self" remind "$sid" "$token" "$m"
    done
  ) </dev/null >/dev/null 2>&1 &
}

lower_first() { printf '%s%s' "$(tr '[:upper:]' '[:lower:]' <<<"${1:0:1}")" "${1:1}"; }

# Plain words for what a permission prompt asks for, e.g. "to run the invoice tests".
asks_for() {
  local tool desc
  tool=$(jq -r '.tool_name // empty' <<<"$input")
  case "$tool" in
    Bash)
      desc=$(jq -r '.tool_input.description // empty' <<<"$input" | tr '_' ' ' | awk '{for (i = 1; i <= NF && i <= 12; i++) printf "%s%s", $i, (i < NF && i < 12 ? " " : "")}' | sed 's/[.]*$//')
      if [ -n "$desc" ]; then echo "to $(lower_first "$desc")"; else echo "to run a command"; fi ;;
    Edit|MultiEdit|Write|NotebookEdit)
      desc=$(jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' <<<"$input")
      echo "to edit ${desc##*/}" ;;
    WebFetch) echo "to open $(jq -r '.tool_input.url // empty' <<<"$input" | sed -E 's#^[a-z]+://([^/:]+).*#\1#')" ;;
    mcp__*) echo "to use $(awk -F'__' '{print $2}' <<<"$tool" | sed 's/^claude_ai_//' | tr '_-' '  ')" ;;
    "") echo "" ;;
    *) echo "to use $tool" ;;
  esac
}

input=$(cat)
now=$(date +%s)
sid=$(jq -r '.session_id' <<<"$input")
cwd=$(jq -r '.cwd // empty' <<<"$input")
proj=$(basename "$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null || echo "$cwd")" | tr '_-' '  ')
state="/tmp/earshot-$sid"
clear_wait() { rm -f "$(wait_file "$sid")"; }
new_wait() {
  token="$now-$$-$RANDOM"
  printf '%s\n%s\n%s\n%s\n%s\n' "$token" "$1" "$proj" "$2" "$(jq -r '.transcript_path // empty' <<<"$input")" > "$(wait_file "$sid")"
}

# --- Stuck detection ------------------------------------------------------------
# Modeled on OpenHands' stuck detector. Three signals; at most one warning per
# turn, so a loop that trips two signals is announced once:
#   1. the same error 3 times this turn, even with edits in between
#   2. the same call with the same result 3 times in a row
#   3. two steps alternating for 3 rounds (A B A B A B)
# A slow command repeats nothing, and a changed error means progress, so
# neither counts. Polling a long job repeats on purpose and is skipped.
hist="/tmp/earshot-hist-$sid"; errs="/tmp/earshot-errs-$sid"; warned="/tmp/earshot-warned-$sid"

warn_once() { [ -s "$warned" ] && return; echo "$1" > "$warned"; tell alert "$2"; }

polling() {
  case "$(jq -r '.tool_name // empty' <<<"$input")" in BashOutput|TaskOutput|Monitor) return 0 ;; esac
  jq -r '.tool_input.command // empty' <<<"$input" \
    | grep -Eq '(^|[^[:alnum:]_])(sleep|watch|wait|until)([^[:alnum:]_]|$)|gh run (view|watch)|gh pr checks|rollout status'
}

# The error with run-to-run noise removed: colors, dates, times, hex ids,
# durations, pids, temp paths and line:col numbers. Counts like "3 failed"
# stay, because a changed count is progress. Keeps the last 400 characters.
norm_error() {
  sed -E -e $'s/\x1b\\[[0-9;]*[a-zA-Z]//g' \
    -e 's/[0-9]{4}-[0-9]{2}-[0-9]{2}T?//g' -e 's/[0-9]{1,2}:[0-9]{2}(:[0-9]{2})?([.,][0-9]+)?//g' \
    -e 's/0x[0-9a-fA-F]+//g' -e 's/[0-9a-f]{8,}//g' \
    -e 's/[0-9]+([.][0-9]+)? ?(ms|s|sec)([^[:alpha:]]|$)/\3/g' \
    -e 's/(pid|PID)[ =:]*[0-9]+//g' -e 's#(/private)?/tmp/[^ ]*##g' -e 's#/var/folders/[^ ]*##g' \
    -e 's/:[0-9]+(:[0-9]+)?//g' | tail -c 400
}

# step <signature>: keep the last 6 steps and check signals 2 and 3.
step() {
  echo "$1" >> "$hist"; tail -6 "$hist" > "$hist.t" && mv "$hist.t" "$hist"
  local h n i same=1
  h=($(cat "$hist")); n=${#h[@]}
  if [ "$n" -ge "$LOOP_REPEATS" ]; then
    for ((i = n - LOOP_REPEATS; i < n; i++)); do [ "${h[i]}" = "${h[n-1]}" ] || same=0; done
    [ "$same" = 1 ] && ! polling && warn_once loop "Heads up, $proj keeps running the same thing over and over. It might be stuck."
  fi
  if [ "$n" -eq 6 ] && [ "${h[0]}" != "${h[1]}" ] && [ "${h[0]}" = "${h[2]}" ] && [ "${h[2]}" = "${h[4]}" ] \
     && [ "${h[1]}" = "${h[3]}" ] && [ "${h[3]}" = "${h[5]}" ]; then
    warn_once pingpong "Heads up, $proj keeps going back and forth between the same two steps. It might be stuck."
  fi
}

# progress: the "still on it" heartbeat.
progress() {
  [ -f "$state" ] || echo "$now $now" > "$state"
  read -r start beat _ < "$state"
  if [ $((now - beat)) -ge "$BEAT_SECS" ]; then
    line="Still on $proj, about $(( (now - start) / 60 )) minutes in."
    desc=$(jq -r '.tool_input.description // empty' <<<"$input")
    [ -n "$desc" ] && line="$line Latest step: $(lower_first "$desc")."
    tell beat "$line"
    beat=$now
  fi
  echo "$start $beat" > "$state"
}

case "$1" in
start)
  clear_wait
  # Few fixed phrases, so all of them come from the cache after the first use.
  acks=("Got it." "On it." "Okay, on it.")
  tell ack "${acks[RANDOM % 3]}"
  echo "$now $now" > "$state"
  rm -f "$hist" "$errs" "$warned"
  # Plain stdout from UserPromptSubmit is added to Claude's context.
  cat <<'EOF'
Earshot voice is on. End your final reply with one line that starts with "🗣 " (the speaking-head emoji and a space). A hook reads that line aloud when you finish.
Write it the way a coworker talks out loud: casual, with contractions. Say the result. If there is a question or blocker for the user, say it first; if there is a real risk, say it last. When there is none, leave it out: never say that there is no blocker or no risk. One or two short sentences, 25 words at most; for a small task a few words are enough. No code, file paths, markdown, emotion tags or stage directions.
The prompt was probably dictated: read misheard code terms as the closest name in this repo, and ask if unsure.
EOF
  ;;
tool)
  clear_wait
  progress
  step "$(jq -c '[.tool_name, .tool_input, .tool_response]' <<<"$input" | md5 -q)"
  ;;
toolfail)
  # PostToolUseFailure: a Bash command that exits non-zero lands here, not in tool.
  clear_wait
  [ "$(jq -r '.is_interrupt // false' <<<"$input")" = true ] && exit 0
  progress
  call=$(jq -c '[.tool_name, .tool_input]' <<<"$input")
  err=$(jq -r '.error // empty' <<<"$input" | norm_error)
  # Signal 1 first: "the same error" says more than "the same thing".
  # A bare "Exit code 1" says little, so it only matches the same call.
  if ! polling; then
    body=$(printf '%s\n' "$err" | sed '1{/^Exit code [0-9]*$/d;}' | tr -d '[:space:]')
    if [ ${#body} -ge 8 ]; then fp=$(printf '%s' "$err" | md5 -q); else fp=$(printf '%s %s' "$call" "$err" | md5 -q); fi
    echo "$fp" >> "$errs"
    [ "$(grep -cx "$fp" "$errs")" -ge "$LOOP_REPEATS" ] \
      && warn_once error "Heads up, $proj keeps hitting the same error. It might be stuck."
  fi
  step "$(printf '%s %s' "$call" "$err" | md5 -q)"
  ;;
ask)
  # PermissionRequest: fires as soon as the prompt shows. Record what it asks
  # and start the reminders; the Notification below speaks first, after ~6s.
  if [ "$(jq -r '.tool_name' <<<"$input")" = AskUserQuestion ]; then
    grep -qx question <(sed -n 2p "$(wait_file "$sid")" 2>/dev/null) && exit 0
    new_wait question ""; start_timer "$sid" "$token" first
  else
    new_wait permission "$(asks_for)"; start_timer "$sid" "$token"
  fi
  ;;
question)
  # PreToolUse for AskUserQuestion: the same grace period, then reminders.
  new_wait question ""; start_timer "$sid" "$token" first
  ;;
notify)
  # Notification permission_prompt: the prompt has waited about 6 seconds.
  { read -r _; read -r kind; read -r _; read -r what; } 2>/dev/null < "$(wait_file "$sid")"
  [ "$kind" = question ] && exit 0
  if [ -n "$what" ]; then tell alert "Hey, $proj needs your OK $what."
  else tell alert "Hey, $proj needs your OK before it keeps going."
  fi
  ;;
idle)
  # Notification idle_prompt: 60s after a turn ended with no typing. Speak only
  # when the last reply asked the user something.
  transcript=$(jq -r '.transcript_path // empty' <<<"$input")
  [ -f "$transcript" ] || exit 0
  last=$(jq -rs '[.[] | select(.type=="assistant") | .message.content[]? | select(.type=="text") | .text] | last // empty' "$transcript" \
    | sed -e 's/[[:space:]]*$//' | grep -v '^$' | tail -1)
  case "$last" in *'?') tell alert "Hey, $proj is still waiting on your answer." ;; esac
  ;;
stop)
  clear_wait
  rm -f "$state" "$hist" "$errs" "$warned"
  msg=$(jq -r '.last_assistant_message // empty' <<<"$input")
  if [ -z "$msg" ]; then
    transcript=$(jq -r '.transcript_path // empty' <<<"$input")
    [ -f "$transcript" ] && msg=$(jq -rs '[.[] | select(.type=="assistant") | .message.content[]? | select(.type=="text") | .text] | last // empty' "$transcript")
  fi
  # Take the text after the last 🗣 (with or without the emoji variation
  # selector), and drop markdown marks so they are not read aloud.
  line=$(printf '%s\n' "$msg" | LC_ALL=C grep '🗣' | tail -1 \
    | LC_ALL=C sed -e 's/.*🗣//' -e $'s/^\xef\xb8\x8f//' -e 's/[*_`]//g' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
  [ -n "$line" ] && tell alert "$line"
  ;;
fail)
  clear_wait
  rm -f "$state" "$hist" "$errs" "$warned"
  tell alert "Something broke in $proj. Take a look when you can."
  ;;
esac
exit 0
