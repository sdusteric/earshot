#!/bin/bash
# Earshot: spoken updates for Claude Code, with Kokoro on this Mac, ElevenLabs
# or the Mac's own voice.
# Modes: begin | start | tool | toolfail | ask | question | notify | idle | stop | fail | end |
# elicit | answered | inputnotify | pretool (hooks),
# remind (internal timer), play (internal, one line at a time), engine (prints the engine),
# say "<text>" (manual test)
umask 077   # every file Earshot writes is readable only by you
# Shortcuts and other launchers run scripts with a short PATH: add Homebrew
# (jq) and the system folders that hold md5 and lockf.
PATH=$PATH:/opt/homebrew/bin:/usr/local/bin:/usr/sbin:/sbin
CONF=${EARSHOT_CONF:-$HOME/.config/earshot/config}   # tests point this elsewhere
[ -f "$CONF" ] && . "$CONF"
# The saved config wins, so a generic ELEVENLABS_API_KEY set for other tools
# does not replace the key you chose for Earshot.
KEY=${EARSHOT_KEY:-$ELEVENLABS_API_KEY}
VOICE=${EARSHOT_VOICE:-$ELEVENLABS_VOICE_ID}
# kokoro (on this Mac), elevenlabs or say. Configs from before 0.9.0 have no
# engine line: a saved key means they use ElevenLabs.
if [ -n "$EARSHOT_ENGINE" ]; then ENGINE=$EARSHOT_ENGINE
elif [ -n "$KEY" ]; then ENGINE=elevenlabs
else ENGINE=kokoro
fi
case "$ENGINE" in kokoro|elevenlabs|say) ;; *) ENGINE=kokoro ;; esac
[ "$1" = engine ] && { echo "$ENGINE"; exit 0; }
[ "$ENGINE" != elevenlabs ] || { [ -n "$KEY" ] && [ -n "$VOICE" ]; } || exit 0
# Talks only while /voice is on. Hooks get no signal that a prompt was
# dictated, so typed prompts get spoken updates too.
# A roll call is something you asked for, so it plays even when muted or with
# /voice off. ($4 is the kind when play runs a line.)
if [ "$1" != rollcall ] && ! { [ "$1" = play ] && [ "$4" = roll ]; }; then
  [ "$(jq -r '.voice.enabled // .voiceEnabled // false' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json" 2>/dev/null)" = true ] || exit 0
  # Muted: an empty file mutes until it is removed; a time (epoch seconds)
  # mutes until then. Earshot for Mac writes the time for "Mute for 1 hour".
  MUTE=${EARSHOT_MUTE:-$HOME/.config/earshot/mute}
  if [ -e "$MUTE" ]; then
    until=$(head -c 20 "$MUTE" 2>/dev/null | tr -cd 0-9)
    { [ -z "$until" ] || [ "$until" -gt "$(date +%s)" ]; } && exit 0
  fi
fi

MODEL=${EARSHOT_MODEL:-eleven_v4_turbo}
KOKORO_VOICE=${EARSHOT_KOKORO_VOICE:-af_heart}
SAY_VOICE=${EARSHOT_SAY_VOICE:-}          # empty: the system voice
BEAT_SECS=${EARSHOT_BEAT_SECS:-180}       # how often to say "still working"
LONG_MAX=${EARSHOT_LONG_MAX_SECS:-7200}   # updates during one command stop after 2 hours
DECIDE_SECS=${EARSHOT_DECIDE_SECS:-3500}  # how long a prompt can be answered by voice (hook timeout 3600)
LOOP_REPEATS=${EARSHOT_LOOP_REPEATS:-3}   # repeats that count as stuck (see Stuck detection)
LEVEL=${EARSHOT_LEVEL:-normal}            # quiet | normal | all (see tell)
STYLE=${EARSHOT_STYLE:-plain}             # plain | upbeat | cheeky: tone of the finished line
# Per-user folders (mode 700) instead of /tmp, so other accounts on this Mac
# cannot read the lines or plant files and links there.
STATE=${EARSHOT_STATE_DIR:-$(getconf DARWIN_USER_TEMP_DIR)earshot}
CACHE=${EARSHOT_CACHE_DIR:-$(getconf DARWIN_USER_CACHE_DIR)earshot}
mkdir -p "$STATE" "$CACHE" 2>/dev/null
[ -O "$STATE" ] && [ -O "$CACHE" ] || exit 0
LOG=$STATE/earshot.log
MIC=${EARSHOT_MIC:-$HOME/.config/earshot/mic-in-use}   # tests point this at a stub
HOLD=${EARSHOT_HOLD_ON_MIC:-on}   # on: hold lines while an app uses the mic
# Tests point these at fakes.
TTS=${EARSHOT_TTS:-$HOME/.config/earshot/kokoro/earshot-tts}
SAYCMD=${EARSHOT_SAY:-/usr/bin/say}   # the program: a bare "say" is the function below
PLAYER=${EARSHOT_PLAYER:-afplay}
SOCK=$STATE/kokoro.sock   # the Kokoro server, while it runs
# Earshot for Mac: when it runs, it plays every line. Tests that collect lines
# (EARSHOT_DRYRUN) reach an app only when they name its socket.
APP_SOCK=${EARSHOT_APP_SOCK-$HOME/Library/Application Support/Earshot/earshot.sock}
[ -n "$EARSHOT_DRYRUN" ] && [ -z "${EARSHOT_APP_SOCK+x}" ] && APP_SOCK=
APP_SEND=$(dirname "$0")/app-send.zsh

# app_up: the app's socket is there.
app_up() { [ -n "$APP_SOCK" ] && [ -S "$APP_SOCK" ]; }
# app_send '<json>': hands one message to the app. 0 only when the app took it.
# It waits at most 0.2 s, so a hung app costs a hook little.
app_send() { app_up && /bin/zsh -f "$APP_SEND" "$APP_SOCK" "$1"; }

# mic_state: the helper's answer. 0 an app is capturing (a call, or you
# dictating), 1 free, 2 the device runs but the app is unknown (macOS before 14.2).
# A helper that is not rebuilt yet (MIC.stale) still has the old meaning, where
# 0 includes Siri and Voice Control, so its 0 counts as 2.
mic_state() {
  [ -x "$MIC" ] || return 1
  "$MIC"; local r=$?
  [ "$r" = 0 ] && [ -e "$MIC.stale" ] && return 2
  return "$r"
}
mic_busy() { mic_state; [ $? != 1 ]; }
lower_first() { printf '%s%s' "$(tr '[:upper:]' '[:lower:]' <<<"${1:0:1}")" "${1:1}"; }
upper_first() { printf '%s%s' "$(tr '[:lower:]' '[:upper:]' <<<"${1:0:1}")" "${1:1}"; }

# tell <kind> "<line>": speak only if EARSHOT_LEVEL includes the kind.
#   need   waiting on you: a permission prompt, a question, reminders   every level
#   reply  the last reply asked you something and you did not answer   every level
#   alert  might be stuck, something broke                              every level
#   done   the finished line                                            every level
#   beat   "still on it" progress updates                               normal, all
#   ack    "On it" when your prompt arrives                             all
tell() {
  case "$1:$LEVEL" in
    need:*|reply:*|alert:*|done:*|beat:normal|beat:all|ack:all) say "$2" "$1" "$sid" ;;
  esac
}

# say "<line>" [kind] [session]: speaks in the background, so hooks return at
# once. Tests set EARSHOT_DRYRUN, which makes it wait.
say() {
  if [ -n "$EARSHOT_DRYRUN" ]; then speak "$1" "${2:-alert}" "$3"
  else speak "$1" "${2:-alert}" "$3" </dev/null >/dev/null 2>&1 &
  fi
}

HELD=$STATE/held   # lines held while an app uses the mic: time, session, kind, text

# hold <kind> "<line>" <session>: keeps a line for the catch-up after the call
# and starts the watcher. Progress updates and "On it" are stale by then.
hold() {
  case "$1" in need|reply|alert|done) ;; *) return ;; esac
  printf '%s\037%s\037%s\037%s\n' "$(date +%s)" "$3" "$1" "$(printf '%s' "$2" | tr -d '\037\n')" \
    | lockf -k "$HELD.lock" sh -c 'cat >> "$1"' _ "$HELD"
  echo "$(date '+%F %T') held ($1): $2" >> "$LOG"
  # One watcher at a time. Waiting 5 s covers a watcher that is just exiting.
  [ -n "$EARSHOT_DRYRUN" ] || ( lockf -t 5 -k "$STATE/release.lock" bash "$0" release ) </dev/null >/dev/null 2>&1 &
}

# cache_file <engine> "<line>": where that engine's audio for the line is kept.
# The ElevenLabs name is the one from before 0.9.0, so old caches stay valid.
cache_file() {
  case "$1" in
    elevenlabs) echo "$CACHE/$(printf '%s' "$MODEL $VOICE $2" | md5 -q).mp3" ;;
    kokoro) echo "$CACHE/$(printf '%s' "kokoro $KOKORO_VOICE $2" | md5 -q).wav" ;;
    say) echo "$CACHE/$(printf '%s' "say $SAY_VOICE $2" | md5 -q).aiff" ;;
  esac
}

# synth <engine> "<line>" <file>: makes the audio. Returns non-zero and logs why
# when it fails. The text goes in through stdin or a file, never the command line.
synth() {
  local body code ok err txt
  case "$1" in
    elevenlabs)
      # The key goes in through stdin too.
      body=$(mktemp "$STATE/body.XXXXXX") || return 1
      printf '%s' "$2" | jq -Rs --arg m "$MODEL" '{text: ., model_id: $m}' > "$body"
      code=$(printf 'xi-api-key: %s\n' "$KEY" | curl -s --connect-timeout 5 --max-time 20 -w '%{http_code}' -o "$3" \
        "https://api.elevenlabs.io/v1/text-to-speech/$VOICE" \
        -H @- -H 'Content-Type: application/json' --data-binary @"$body")
      ok=$?
      rm -f "$body"
      # A dropped connection can still report 200, so curl must succeed too.
      if [ "$ok" != 0 ] || [ "$code" != 200 ]; then
        echo "$(date '+%F %T') HTTP $code curl $ok: $(head -c 300 "$3" 2>/dev/null)" >> "$LOG"
        return 1
      fi ;;
    kokoro)
      [ -x "$TTS" ] || { echo "$(date '+%F %T') kokoro: the helper is not built (run setup)" >> "$LOG"; return 1; }
      err=$(printf '%s' "$2" | "$TTS" speak --socket "$SOCK" --voice "$KOKORO_VOICE" --out "$3" 2>&1 >/dev/null)
      if [ $? != 0 ] || [ ! -s "$3" ]; then
        echo "$(date '+%F %T') kokoro: $(tail -1 <<<"$err")" >> "$LOG"
        return 1
      fi ;;
    say)
      txt=$(mktemp "$STATE/line.XXXXXX") || return 1
      printf '%s' "$2" > "$txt"
      "$SAYCMD" ${SAY_VOICE:+-v "$SAY_VOICE"} -f "$txt" -o "$3" 2>/dev/null; ok=$?
      rm -f "$txt"
      [ "$ok" = 0 ] && [ -s "$3" ] || { echo "$(date '+%F %T') say: failed" >> "$LOG"; return 1; } ;;
  esac
}

# speak "<line>" <kind> <session>: holds the line while an app uses the mic,
# or plays it. It returns when the line has played. When Earshot for Mac takes
# the line, the app holds, queues and plays it instead.
speak() {
  local asked out dl tmp fb
  if app_up && app_send "$(jq -nc --arg t "$1" --arg k "$2" --arg s "$3" --arg n "${who:-}" --arg tr "${transcript:-}" \
      '{v: 1, type: "say", text: $t, kind: $k, session: $s} + (if $n != "" then {name: $n} else {} end)
       + (if $tr != "" and ($k == "need" or $k == "reply") then {transcript: $tr} else {} end)')"; then
    echo "$(date '+%F %T') the app took ($2): $1" >> "$LOG"
    return
  fi
  if [ "$2" != roll ] && [ "$HOLD" = on ] && mic_state; then hold "$2" "$1" "$3"; return; fi
  # Tests set EARSHOT_DRYRUN to a file: lines go there instead of the speaker.
  [ -n "$EARSHOT_DRYRUN" ] && { echo "$1" >> "$EARSHOT_DRYRUN"; return; }
  asked=$(date +%s)
  out=$(cache_file "$ENGINE" "$1")
  if [ ! -s "$out" ]; then
    # A unique download file keeps two lines from writing the same file, even
    # from one hook. It keeps the extension, because say picks its format by it.
    tmp=$(mktemp "$CACHE/dl.XXXXXX") || echo "$(date '+%F %T') no room for a download file in $CACHE" >> "$LOG"
    dl=$tmp.${out##*.}
    if [ -n "$tmp" ] && synth "$ENGINE" "$1" "$dl"; then
      mv "$dl" "$out"
    else
      [ -n "$tmp" ] && rm -f "$dl"
      # Say it with the Mac's own voice, uncached, so the next line tries the
      # engine again. The error tone is the last resort, and waits its turn too.
      fb=$(mktemp "$STATE/fallback.XXXXXX") && out=$fb.aiff
      if [ -n "$fb" ] && [ "$ENGINE" != say ] && synth say "$1" "$out"; then
        echo "$(date '+%F %T') $ENGINE failed, said with say: $1" >> "$LOG"
      else
        out=/System/Library/Sounds/Basso.aiff
      fi
    fi
  fi
  # All sessions share one speaker, so lines take turns: a line waits for
  # the one playing to finish, and is dropped after a minute in the queue.
  # -k keeps the lock file, so a new line cannot lock a fresh copy of it.
  # The line goes in the environment, which other accounts cannot see, not the
  # command line, which they can.
  EARSHOT_LINE=$1 lockf -s -k -t 60 "$STATE/speaker.lock" bash "$0" play "$out" "$asked" "$2" "$3"
  rm -f "$tmp" "$fb" "${fb:+$fb.aiff}"
}

# play <file> <asked> <kind> <line> <session>: plays one line while it holds the speaker.
play() {
  # You talked over an earlier line, so the lines queued behind it are dropped too.
  [ "$(stat -f %m "$STATE/hushed" 2>/dev/null || echo 0)" -ge "$2" ] && return
  # A call started while this line waited for the speaker: keep it for later.
  # Its audio is cached, so the catch-up does not download it again.
  if [ "$3" != roll ] && [ "$HOLD" = on ] && mic_state; then hold "$3" "$4" "$5"; return; fi
  # Stop when you start talking. A mic that was already on (an app the helper
  # cannot name, or holding is off) does not count.
  mic_busy && mic_was_on=1
  "$PLAYER" "$1" & pid=$!
  while kill -0 $pid 2>/dev/null; do
    sleep 0.5
    [ -z "$mic_was_on" ] && mic_busy && { kill $pid; touch "$STATE/hushed"; }
  done
}

[ "$1" = say ] && { say "$2"; exit 0; }
[ "$1" = play ] && { play "$2" "$3" "$4" "$EARSHOT_LINE" "$5"; exit 0; }

# --- After the call: the catch-up -------------------------------------------------
POLL=${EARSHOT_POLL_SECS:-2}            # seconds between mic checks
HOLD_MAX=${EARSHOT_HOLD_MAX_SECS:-14400}   # held lines older than 4 hours are dropped

wait_file() { echo "$STATE/wait-$1"; }

# still_waiting <session>: its permission prompt or question still waits. While
# it waits, the transcript does not change, so a newer transcript means you
# answered, for example with Esc, which fires no hook.
still_waiting() {
  local wf tr; wf=$(wait_file "$1")
  [ -f "$wf" ] || return 1
  tr=$(sed -n 5p "$wf")
  ! { [ -f "$tr" ] && [ "$(stat -f %m "$tr")" -gt $(( $(stat -f %m "$wf") + 2 )) ]; }
}

# catch_up: says the held lines: per session, the first "needs you" line (the
# most specific one) and the newest line of every other kind; lines that need
# you first, then alerts, then finished lines, oldest first.
catch_up() {
  local batch now lines kept total n=0 t s kind text
  batch=$(mktemp "$STATE/batch.XXXXXX") || return
  # Taking the whole queue under the lock means a line is spoken once, even
  # when two catch-ups run at the same time.
  lockf -k "$HELD.lock" mv "$HELD" "$batch" 2>/dev/null || { rm -f "$batch"; return; }
  now=$(date +%s)
  lines=$(awk -F'\037' -v min=$((now - HOLD_MAX)) '$1 >= min { k = $2 FS $3; if ($3 != "need" || !(k in last)) last[k] = $0 }
      END { for (k in last) { split(last[k], f, FS); print (f[3] == "need" || f[3] == "reply" ? 0 : f[3] == "alert" ? 1 : 2), f[1], last[k] } }' "$batch" \
    | sort -k1,1n -k2,2n | cut -d' ' -f3-)
  rm -f "$batch"
  [ -n "$lines" ] || return
  # A prompt you answered without a hook firing (Esc) is not read.
  kept=""
  while IFS=$'\037' read -r -u 3 t s kind text; do
    if [ "$kind" = need ] && ! still_waiting "$s"; then
      echo "$(date '+%F %T') skipped (answered): $text" >> "$LOG"; continue
    fi
    kept="$kept$t"$'\037'"$s"$'\037'"$kind"$'\037'"$text"$'\n'
  done 3<<<"$lines"
  lines=${kept%$'\n'}
  [ -n "$lines" ] || return
  total=$(printf '%s\n' "$lines" | wc -l | tr -d ' ')
  [ $((now - $(printf '%s\n' "$lines" | cut -d$'\037' -f1 | sort -n | head -1))) -ge 30 ] && speak "While you were on the mic:" intro
  # Read from fd 3, so nothing that speak runs can eat the list.
  while IFS=$'\037' read -r -u 3 t s kind text; do
    n=$((n + 1))
    [ "$n" -gt 4 ] && { speak "And $((total - 4)) more." intro; break; }
    speak "$text" "$kind" "$s"
  done 3<<<"$lines"
}

# release: the watcher. The first held line starts it. It checks the mic every
# few seconds and says the catch-up once the mic is free on two checks in a
# row, so a short pause in a call does not count as the end.
if [ "$1" = release ]; then
  began=$(date +%s); free=0
  while [ -s "$HELD" ]; do
    if mic_state; then free=0; else free=$((free + 1)); fi
    [ "$free" -ge 2 ] && { catch_up; free=0; continue; }
    # A mic that stays busy for hours: stop watching and drop the queue.
    if [ $(( $(date +%s) - began )) -ge "$HOLD_MAX" ]; then
      n=$(wc -l < "$HELD" | tr -d ' ')
      lockf -k "$HELD.lock" rm -f "$HELD"
      echo "$(date '+%F %T') dropped $n held line$([ "$n" = 1 ] || echo s) after $((HOLD_MAX / 3600)) hours" >> "$LOG"
      break
    fi
    sleep "$POLL"
  done
  exit 0
fi

# --- Waiting on you: permission prompts and questions -------------------------
# A wait file per session holds: token, kind (permission|question), project,
# what is being asked, and the transcript path. Any later hook activity deletes
# it, which cancels reminders.
REMIND_MINS=${EARSHOT_REMIND_MINS:-2 5 10}   # minutes after a prompt to remind you
UNIT=${EARSHOT_REMIND_UNIT:-60}               # seconds per "minute"; tests set it lower

# claude_kids <pid>: Claude Code's child processes: pid, ppid, command. One ps
# over all processes, because pgrep skips its own ancestors.
claude_kids() { ps -ww -A -o pid=,ppid=,command= | awk -v p="$1" '$2 == p'; }

# approved <session>: the Bash command of the session's permission prompt is
# running, so you approved it. No hook fires on approval, but Claude Code runs
# the command in a child shell whose arguments hold the command text.
# cmd-<session> (written with the prompt) has Claude Code's PID, a piece of the
# command, and the matching processes that already ran then, which do not count.
approved() {
  local cpid needle pre
  { read -r cpid; read -r needle; read -r pre; } 2>/dev/null < "$STATE/cmd-$1" || return 1
  [ -n "$cpid" ] && [ ${#needle} -ge 10 ] || return 1
  claude_kids "$cpid" | grep -F -- "$needle" | awk -v pre=" $pre " 'index(pre, " " $1 " ") == 0 { found = 1 } END { exit !found }'
}

# mark_working <session>: an approved prompt no longer needs you.
mark_working() {
  local f="$STATE/status-$1"
  [ "$(head -1 "$f" 2>/dev/null)" = needs ] || return 0
  local t; t=$(mktemp "$f.XXXXXX") || return 0
  { echo working; date +%s; sed -n 3p "$f"; echo; } > "$t" && mv "$t" "$f"
}

# remind <session> <token> <step>: a timer step. It runs this script again, so
# the /voice and mute checks above apply at the moment it speaks.
if [ "$1" = remind ]; then
  sid=$2
  wf=$(wait_file "$2")
  { read -r token; read -r kind; read -r proj; read -r what; read -r transcript; } 2>/dev/null < "$wf" || exit 0
  [ "$token" = "$3" ] || exit 0
  # While a prompt waits, the agent is blocked and its transcript does not
  # change. A newer transcript means you answered it, for example with Esc,
  # which fires no hook. (2s grace: the tool call itself may land just after.)
  if [ -f "$transcript" ] && [ "$(stat -f %m "$transcript")" -gt $(( $(stat -f %m "$wf") + 2 )) ]; then
    rm -f "$wf"; exit 0
  fi
  # A permission prompt you approved: its command is running.
  if [ "$kind" = permission ] && approved "$sid"; then rm -f "$wf"; mark_working "$sid"; exit 0; fi
  if [ "$4" = first ]; then
    tell need "Hey, $proj has a question for you."
  else
    tell need "It's been $4 minute$([ "$4" = 1 ] || echo s). $(upper_first "$proj") is still waiting on you."
  fi
  exit 0
fi

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

# --- Session names ----------------------------------------------------------------
# The folder name tells sessions in different projects apart. When another open
# session shares the folder, a short label from the session's title is added.
# The title is the name in /resume and in the Mac app's session list.
LIVE=${EARSHOT_LIVE_DIR:-$STATE/live}   # one file per open session: project, title, [app label]
SESSION_NAME=${EARSHOT_SESSION_NAME:-auto}   # auto | always | never

# label(title): 1 to 3 words for a session title, to say it often. A title of
# 3 words or fewer is used as it is. A longer one drops a leading verb and "a",
# "an", "the", and stops at the first of "for", "with", "and", "to", "in",
# "on", "of", "vs": "Create guest confirmation email with event details"
# becomes "guest confirmation email". Nothing left: the first 3 words.
LABEL_AWK='
function label(t,   w, n, i, out, lw, cnt) {
  gsub(/[_\/-]/, " ", t); sub(/ [Ss]ession$/, "", t)
  cnt = split(t, w, " ")
  if (cnt <= 3) { out = ""; for (i = 1; i <= cnt; i++) out = out (i > 1 ? " " : "") w[i]; return out }
  n = 0; out = ""
  for (i = 1; i <= cnt; i++) {
    lw = tolower(w[i])
    if (i == 1 && lw ~ /^(fix|add|create|make|update|build|write|check|debug|refactor|implement)$/) continue
    if (lw ~ /^(a|an|the)$/) continue
    if (n > 0 && lw ~ /^(for|with|and|to|in|on|of|vs)$/) break
    out = out (n ? " " : "") w[i]
    if (++n == 3) break
  }
  if (out == "") out = w[1] " " w[2] " " w[3]
  return out
}'
short_label() { printf '%s\n' "$1" | awk "$LABEL_AWK"' { print label($0) }'; }

# session_names <session>: how lines name the session, in one pass over the
# open sessions: who ("the tax export session"), on ("tax export"), how many
# other sessions are open, and how many of them share its project. The
# shortest name that is unique: the project; else the label, when no other
# open session has the same label; else the label and the project. The label
# is the app's (live file line 3), or label() of the title.
session_names() {
  awk -v me="$LIVE/$1" -v mode="$SESSION_NAME" "$LABEL_AWK"'
    FNR == 1 { files[++nf] = FILENAME; proj[FILENAME] = $0 }
    FNR == 2 { title[FILENAME] = $0 }
    FNR == 3 { app[FILENAME] = $0 }
    function lab(f) { return app[f] != "" ? app[f] : label(title[f]) }
    END {
      p = proj[me]; t = title[me]; others = 0; twins = 0
      for (i = 1; i <= nf; i++) if (files[i] != me) { others++; if (proj[files[i]] == p) twins++ }
      if (t == "" || mode == "never" || (mode == "auto" && twins == 0)) { who = p; on = p }
      else {
        l = lab(me); clash = 0
        for (i = 1; i <= nf; i++) if (files[i] != me && tolower(lab(files[i])) == tolower(l)) clash = 1
        if (mode == "auto" && !clash) { who = "the " l " session"; on = l }
        else { who = l " in " p; on = l " in " p }
      }
      print who; print on; print others; print twins
    }' "$LIVE"/* 2>/dev/null
}

[ "$1" = label ] && { short_label "$EARSHOT_LABEL_TEST"; exit 0; }

# --- Roll call --------------------------------------------------------------------
# rollcall [--print]: says what every open session is doing, the ones that need
# you first. From a hotkey or /earshot:rollcall; --print also prints the line.
count_words=(No One Two Three Four Five Six Seven Eight Nine)
if [ "$1" = rollcall ]; then
  find "$LIVE" -type f -mmin +360 -delete 2>/dev/null
  now=$(date +%s); rows=""
  for f in "$LIVE"/*; do
    [ -f "$f" ] || continue
    s=${f##*/}
    st=open; since=0; name=""; detail=""
    { read -r st; read -r since; read -r _; read -r detail; } 2>/dev/null < "$STATE/status-$s"
    [ "$st" = needs ] && approved "$s" && st=working
    # The name as the alerts say it, worked out now, so a second session in
    # the same project is told apart by its label.
    name=$(session_names "$s" | head -1)
    Name=$(upper_first "$name")
    case "$st" in
      needs) r=0; text="$Name $detail." ;;
      reply) r=0; text="$Name is waiting on your answer." ;;
      stuck) r=1; text="$Name might be stuck." ;;
      failed) r=1; text="$Name hit an error." ;;
      working)
        r=2; start=$since; read -r start _ 2>/dev/null < "$STATE/turn-$s"
        case "$start" in ''|0|*[!0-9]*) start=$now ;; esac
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

# watch_command <session> <token> <transcript>: while the same command runs,
# says an update each time one is due, at most once a second. The command's
# PostToolUse removes the running file and stops it.
watch_command() {
  local sid=$1 token=$2 tr=$3 self=$0
  (
    began=$(date +%s)
    while :; do
      read -r start beat _ < "$STATE/turn-$sid" 2>/dev/null || exit 0
      wait=$((beat + BEAT_SECS - $(date +%s))); [ "$wait" -lt 1 ] && wait=1
      sleep "$wait"
      [ "$(head -1 "$STATE/running-$sid" 2>/dev/null)" = "$token" ] || exit 0
      # The turn ended, or the command already has a result: you said no or
      # pressed Esc, which fires no hook. Either way the command is over.
      [ -f "$STATE/turn-$sid" ] || exit 0
      [ -f "$tr" ] && tail -c 262144 "$tr" | grep -F "\"tool_use_id\":\"$token\"" | grep -qF '"type":"tool_result"' && exit 0
      t=$(date +%s)
      [ $((t - began)) -ge "$LONG_MAX" ] && exit 0
      # While a permission prompt waits, the command has not started yet.
      # Once it runs, you approved it: forget the prompt and give updates.
      if [ -f "$STATE/wait-$sid" ] && approved "$sid"; then rm -f "$STATE/wait-$sid"; mark_working "$sid"; fi
      [ -f "$STATE/wait-$sid" ] || bash "$self" longbeat "$sid" "$token" $((t - start))
      [ -f "$STATE/turn-$sid" ] && echo "$start $t" > "$STATE/turn-$sid"
    done
  ) </dev/null >/dev/null 2>&1 &
  echo $! >> "$STATE/running-$sid"   # line 4, so the end of the command can stop it
}

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
  echo $! >> "$(wait_file "$sid")"   # line 6, so an answer can stop the timer early
}

# Plain words for what a permission prompt asks for, e.g. "to run the invoice tests".
asks_for() {
  local desc   # $tool comes from the hook input, read once above
  case "$tool" in
    Bash)
      desc=$(jq -r '.tool_input.description // empty' <<<"$input" | tr '_' ' ' | awk '{for (i = 1; i <= NF && i <= 12; i++) printf "%s%s", $i, (i < NF && i < 12 ? " " : "")}' | sed 's/[.]*$//')
      if [ -n "$desc" ]; then echo "to $(lower_first "$desc")"; else echo "to run a command"; fi ;;
    Edit|MultiEdit|Write|NotebookEdit)
      desc=$(jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' <<<"$input")
      echo "to edit ${desc##*/}" ;;
    WebSearch) echo "to search the web" ;;
    WebFetch) echo "to open $(jq -r '.tool_input.url // empty' <<<"$input" | sed -E 's#^[a-z]+://([^/:]+).*#\1#')" ;;
    mcp__*) echo "to use $(awk -F'__' '{print $2}' <<<"$tool" | sed 's/^claude_ai_//' | tr '_-' '  ')" ;;
    "") echo "" ;;
    *) echo "to use $tool" ;;
  esac
}

# Setup built the mic helper once, but updates bring a new mic-in-use.swift.
# Rebuild it in the background when the source is newer. A failed build
# leaves the old helper, so MIC.stale marks it and lines are not held, and
# touches it, so the next hook does not try again. Setup clears the marker.
SRC=${0%/*}/mic-in-use.swift
if [ -z "$EARSHOT_MIC" ] && [ -x "$MIC" ] && [ "$SRC" -nt "$MIC" ]; then
  ( lockf -t 0 "$STATE/build.lock" sh -c 'if swiftc -O "$1" -o "$2.new" && mv "$2.new" "$2"; then rm -f "$2.stale"; else touch "$2" "$2.stale"; fi' _ "$SRC" "$MIC" ) \
    </dev/null >/dev/null 2>&1 &
fi
# The same for the Kokoro helper, for Kokoro users. An update gives every file
# a new time, so newer files only mean "compare": the helper is rebuilt when its
# sources really changed (source.md5, written by build-tts.sh). build-tts.sh
# stops the old server after a good build; then prepare loads both runtimes for
# the voice, so a retry on the older one never downloads while you work. A
# failed build leaves TTS.stale, so hooks do not try again; setup rebuilds it
# and --status shows it.
TTS_SRC=${0%/*}/../tts
if [ "$ENGINE" = kokoro ] && [ -x "$TTS" ] && [ ! -e "$TTS.stale" ] \
  && { [ "$TTS_SRC/Sources/earshot-tts/main.swift" -nt "$TTS" ] || [ "$TTS_SRC/Package.swift" -nt "$TTS" ]; }; then
  if [ "$(cat "$TTS_SRC/Package.swift" "$TTS_SRC/Package.resolved" "$TTS_SRC/Sources/earshot-tts/main.swift" 2>/dev/null | md5 -q)" \
    = "$(cat "${TTS%/*}/source.md5" 2>/dev/null)" ]; then
    touch "$TTS"   # same sources: skip the comparison next time
  else
    ( lockf -k -t 0 "$STATE/tts-build.lock" sh -c 'if bash "$1"; then "$2" prepare --voice "$3"; else touch "$2.stale"; fi' \
      _ "${EARSHOT_BUILD_TTS:-${0%/*}/build-tts.sh}" "$TTS" "$KOKORO_VOICE" ) \
      </dev/null >/dev/null 2>&1 &
  fi
fi

input=$(cat)
now=$(date +%s)
# One jq pass for the fields every hook needs. The separator is not whitespace,
# so an empty field does not shift the others.
IFS=$'\x1f' read -r sid cwd transcript tool < <(jq -r '[.session_id, .cwd, .transcript_path, .tool_name] | map(. // "" | tostring) | join("\u001f")' <<<"$input")
# The session ID becomes part of file names: allow only safe characters.
[[ $sid =~ ^[A-Za-z0-9_-]+$ ]] || exit 0
# The project as it is said out loud: "billing_service" and "billingService"
# both become "billing service".
root=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null || echo "$cwd")
if [ "$root" = "$HOME" ]; then proj="your home folder"
else proj=$(basename "$root" | tr '_.-' '   ' | sed 's/\([a-z]\)\([A-Z]\)/\1 \2/g'); fi
state="$STATE/turn-$sid"

# --- Which session is talking ---------------------------------------------------
# See "Session names" above for how a session is named.

# The newest title in the transcript, at most 6 words: a /rename title or the
# one Claude Code made. Reading from the end stops at the first match. The
# transcript format is internal, so a missing title is fine.
transcript_title() {
  [ -f "$transcript" ] || return
  tail -r "$transcript" | LC_ALL=C grep -m1 -F -e '"type":"custom-title"' -e '"type":"ai-title"' \
    | jq -r '.customTitle // .aiTitle // empty' 2>/dev/null \
    | awk '{for (i = 1; i <= NF && i <= 6; i++) printf "%s%s", $i, (i < NF && i < 6 ? " " : "")}'
}

mkdir -p "$LIVE"
find "$LIVE" -type f -mmin +360 -delete 2>/dev/null   # sessions quiet for 6 hours count as closed
# Hooks that run on every tool call only mark the session as active. The title
# is looked up when a session starts, once per prompt, and when a turn ends.
title=$(sed -n 2p "$LIVE/$sid" 2>/dev/null)
old_title=$title; old_label=$(sed -n 3p "$LIVE/$sid" 2>/dev/null)
# write_live: this session's live file. The app's label (line 3) stays while
# the title is the same, and goes when it changes, so a stale label is never said.
write_live() {
  if [ "$title" = "$old_title" ] && [ -n "$old_label" ]; then printf '%s\n%s\n%s\n' "$proj" "$title" "$old_label"
  else printf '%s\n%s\n' "$proj" "$title"; fi > "$LIVE/$sid"
}
case "$1" in
  begin) t=$(jq -r '.session_title // empty' <<<"$input"); [ -n "$t" ] && title=$t ;;
  start|stop) t=$(transcript_title); [ -n "$t" ] && title=$t ;;
esac
case "$1" in
  begin|start|stop) write_live ;;
  *) if [ -f "$LIVE/$sid" ]; then touch "$LIVE/$sid"; else write_live; fi ;;
esac
# who names the session as a speaker ("the tax export session needs your OK"),
# on names the work ("still on tax export"). Without a title, both are the
# project. See session_names: one awk over the open sessions, however many.
who=$proj; on=$proj; others=0; twins=0
names() { [ -f "$LIVE/$sid" ] && { read -r who; read -r on; read -r others; read -r twins; } < <(session_names "$sid"); }
names
# A session's title can appear after its first prompt. Alerts that need the
# name and do not have it yet look it up; tool calls never do.
if [ -z "$title" ] && { [ "$SESSION_NAME" = always ] || { [ "$SESSION_NAME" = auto ] && [ "$twins" -gt 0 ]; }; }; then
  case "$1" in
    ask|question|notify|idle|fail) title=$(transcript_title); [ -n "$title" ] && { write_live; names; } ;;
  esac
fi
# drop_held: you answered, so this session's held "needs you" and "waiting on
# your answer" lines are stale.
drop_held() {
  lockf -k "$HELD.lock" sh -c 'awk -F "$3" -v s="$2" "!(\$2 == s && (\$3 == \"need\" || \$3 == \"reply\"))" "$1" > "$1.t" && mv "$1.t" "$1"' \
    _ "$HELD" "$sid" $'\037' 2>/dev/null
}

# clear_wait: you answered, so stop the reminder timer and forget the prompt.
clear_wait() {
  local wf pid; wf=$(wait_file "$sid")
  [ -s "$HELD" ] && drop_held
  [ -e "$STATE/cmd-$sid" ] && rm -f "$STATE/cmd-$sid"
  [ -f "$wf" ] || return 0
  pid=$(sed -n 6p "$wf")
  # A timer that already finished may have its PID reused by another program.
  [ -n "$pid" ] && ps -o command= -p "$pid" 2>/dev/null | grep -Eq '/speak\.sh (ask|question|elicit)$' && { pkill -P "$pid" 2>/dev/null; kill "$pid" 2>/dev/null; }
  rm -f "$wf"
}
new_wait() {
  clear_wait
  token="$now-$$-$RANDOM"
  printf '%s\n%s\n%s\n%s\n%s\n' "$token" "$1" "$who" "$2" "$transcript" > "$(wait_file "$sid")"
  case "$1" in
    permission) set_status needs "needs your OK${2:+ $2}" ;;
    question) set_status needs "has a question for you" ;;
    input) set_status needs "needs your input${2:+ $2}" ;;
  esac
}

# --- Stuck detection ------------------------------------------------------------
# Modeled on OpenHands' stuck detector. Three signals; at most one warning per
# turn, so a loop that trips two signals is announced once:
#   1. the same error 3 times this turn, even with edits in between
#   2. the same call with the same result 3 times in a row
#   3. two steps alternating for 3 rounds (A B A B A B)
# A slow command repeats nothing, and a changed error means progress, so
# neither counts. Polling a long job repeats on purpose and is skipped.
hist="$STATE/hist-$sid"; errs="$STATE/errs-$sid"; warned="$STATE/warned-$sid"
running="$STATE/running-$sid"   # a long command in progress: token, name, step, timer PID
status="$STATE/status-$sid"     # for the roll call: state, since, spoken name, detail

# set_status <state> [detail]: what this session is doing, for the roll call.
set_status() {
  printf '%s\n%s\n%s\n%s\n' "$1" "$now" "$who" "$2" > "$status"
  # The app's session list follows it. In the background: a hook never waits for it.
  app_up && { app_send "$(jq -nc --arg s "$sid" --arg st "$1" --arg d "$2" --arg n "$who" --arg p "$proj" --arg t "$title" \
      '{v: 1, type: "status", session: $s, state: $st, detail: $d, name: $n, project: $p, title: $t}')" & } </dev/null >/dev/null 2>&1
}

# stop_watch: the command ended (or the turn did), so stop its update timer.
stop_watch() {
  local pid
  [ -f "$running" ] || return 0
  pid=$(sed -n 4p "$running")
  [ -n "$pid" ] && ps -o command= -p "$pid" 2>/dev/null | grep -q '/speak\.sh pretool$' && { pkill -P "$pid" 2>/dev/null; kill "$pid" 2>/dev/null; }
  rm -f "$running"
}

# claude_pid: Claude Code's process, the parent of the shells it runs commands
# in: a binary named claude, or node running the npm package.
claude_pid() {
  local p=$PPID c
  [ -n "$EARSHOT_CLAUDE_PID" ] && { echo "$EARSHOT_CLAUDE_PID"; return; }
  while [ "${p:-1}" -gt 1 ]; do
    c=$(ps -o comm= -p "$p" 2>/dev/null)
    case "${c##*/}" in
      claude) echo "$p"; return ;;
      node) ps -ww -o command= -p "$p" | grep -q 'claude-code/cli' && { echo "$p"; return; } ;;
    esac
    p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')
  done
}

# record_cmd: for a Bash permission prompt, what its approval will look like.
# The needle is the longest piece of the command's first line between quotes,
# tabs and non-ASCII characters (ps escapes those), after any leading
# "cd <dir> &&", which Claude Code may remove. At least 10 characters.
record_cmd() {
  local cpid needle pre
  cpid=$(claude_pid); [ -n "$cpid" ] || return 0
  needle=$(jq -r '.tool_input.command // empty' <<<"$input" | LC_ALL=C awk -v q="'" 'NR == 1 {
      sub(/^[ \t]+/, "")
      while (match($0, "^cd[ \t]+(\"[^\"]*\"|" q "[^" q "]*" q "|[^ \t]+)[ \t]*&&[ \t]*")) $0 = substr($0, RLENGTH + 1)
      n = split($0, c, "[^ -~]|[" q "\"\\\\]"); best = ""
      for (i = 1; i <= n; i++) { s = c[i]; gsub(/^ +| +$/, "", s); if (length(s) > length(best)) best = s }
      print substr(best, 1, 60) }')
  [ ${#needle} -ge 10 ] || return 0
  pre=$(claude_kids "$cpid" | grep -F -- "$needle" | awk '{print $1}' | paste -sd' ' -)
  printf '%s\n%s\n%s\n' "$cpid" "$needle" "$pre" > "$STATE/cmd-$sid"
}

warn_once() { [ -s "$warned" ] && return; echo "$1" > "$warned"; set_status stuck; tell alert "$2"; }

polling() {
  case "$tool" in BashOutput|TaskOutput|Monitor) return 0 ;; esac
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
    [ "$same" = 1 ] && ! polling && warn_once loop "Heads up, $who keeps running the same thing over and over. It might be stuck."
  fi
  if [ "$n" -eq 6 ] && [ "${h[0]}" != "${h[1]}" ] && [ "${h[0]}" = "${h[2]}" ] && [ "${h[2]}" = "${h[4]}" ] \
     && [ "${h[1]}" = "${h[3]}" ] && [ "${h[3]}" = "${h[5]}" ]; then
    warn_once pingpong "Heads up, $who keeps going back and forth between the same two steps. It might be stuck."
  fi
}

# last_text: Claude's last text reply. Reads only the end of the transcript,
# which can be tens of megabytes.
last_text() {
  tail -r "$transcript" | head -400 \
    | jq -rs '[.[] | select(.type=="assistant") | .message.content[]? | select(.type=="text") | .text] | first // empty' 2>/dev/null
}

# progress: the "still on it" heartbeat.
progress() {
  [ -f "$state" ] || echo "$now $now" > "$state"
  read -r start beat _ < "$state"
  if [ $((now - beat)) -ge "$BEAT_SECS" ]; then
    line="Still on $on, about $(( (now - start) / 60 )) minutes in."
    desc=$(jq -r '.tool_input.description // empty' <<<"$input")
    [ -n "$desc" ] && line="$line Latest step: $(lower_first "$desc")."
    tell beat "$line"
    beat=$now
  fi
  echo "$start $beat" > "$state"
}

case "$1" in
begin)
  # SessionStart: registered above, nothing to say. It also fires after a
  # compact or resume, so a status that is already there stays.
  [ -f "$status" ] || set_status open
  # Load Kokoro now, so the session's first line does not wait for it. A
  # server that is already running makes the new one exit at once. Earshot
  # for Mac keeps its own Kokoro loaded, so not while it runs.
  if [ "$ENGINE" = kokoro ] && [ -x "$TTS" ] && ! app_up; then
    ( "$TTS" serve --socket "$SOCK" ) </dev/null >/dev/null 2>>"$SOCK.log" &
  fi
  ;;
end)
  # SessionEnd: this session no longer counts as open.
  stop_watch
  clear_wait
  rm -f "$LIVE/$sid" "$state" "$hist" "$errs" "$warned" "$status"
  app_up && app_send "$(jq -nc --arg s "$sid" '{v: 1, type: "status", session: $s, state: "closed"}')" >/dev/null 2>&1
  ;;
start)
  stop_watch
  # /earshot:rollcall speaks for itself, so this turn gets no 🗣 line.
  case "$(jq -r '.prompt // empty' <<<"$input")" in /earshot:rollcall*|/rollcall*) exit 0 ;; esac
  clear_wait
  set_status working
  # Few fixed phrases, so all of them come from the cache after the first use.
  acks=("Got it." "On it." "Okay, on it.")
  tell ack "${acks[RANDOM % 3]}"
  echo "$now $now" > "$state"
  rm -f "$hist" "$errs" "$warned"
  # EARSHOT_STYLE only changes the finished line, which Claude writes fresh each
  # time. Alerts stay plain, and so does a turn that ends badly.
  serious="If the task failed, or the user needs to answer something or fix a blocker, drop the style and say it plainly."
  case "$STYLE" in
    upbeat) tone="Write it the way an upbeat coworker talks out loud: warm and encouraging, with contractions. Say the result, and add a few words of encouragement when it fits. $serious" ;;
    cheeky) tone="Write it the way a coworker with a dry, cheeky sense of humor talks out loud: casual, with contractions. Say the result, with a light joke or wry aside when it fits. Tease the code or the task, never the user. $serious" ;;
    *) tone="Write it the way a coworker talks out loud: casual, with contractions. Say the result." ;;
  esac
  # Plain stdout from UserPromptSubmit is added to Claude's context.
  cat <<EOF
Earshot voice is on. End your final reply with one line that starts with "🗣 " (the speaking-head emoji and a space). A hook reads that line aloud when you finish.
$tone If there is a question or blocker for the user, say it first; if there is a real risk, say it last. When there is none, leave it out: never say that there is no blocker or no risk. One or two short sentences, 25 words at most; for a small task a few words are enough. No code, file paths, markdown, emotion tags or stage directions.
The prompt was probably dictated: read misheard code terms as the closest name in this repo, and ask if unsure.
EOF
  ;;
tool)
  stop_watch
  clear_wait
  # You answered: back to work, or still stuck if it was before the prompt.
  if [ "$(head -1 "$status" 2>/dev/null)" = needs ]; then
    if [ -s "$warned" ]; then set_status stuck; else set_status working; fi
  fi
  progress
  # The end of the result is enough to tell results apart, and hashing less
  # keeps big Edit and Write payloads fast.
  step "$(jq -c '[.tool_name, .tool_input, (.tool_response | tostring | .[-4000:])]' <<<"$input" | md5 -q)"
  ;;
toolfail)
  # PostToolUseFailure: a Bash command that exits non-zero lands here, not in tool.
  stop_watch
  clear_wait
  # You answered: back to work, or still stuck if it was before the prompt.
  if [ "$(head -1 "$status" 2>/dev/null)" = needs ]; then
    if [ -s "$warned" ]; then set_status stuck; else set_status working; fi
  fi
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
      && warn_once error "Heads up, $who keeps hitting the same error. It might be stuck."
  fi
  step "$(printf '%s %s' "$call" "$err" | md5 -q)"
  ;;
ask)
  # PermissionRequest: fires as soon as the prompt shows. Record what it asks
  # and start the reminders; the Notification below speaks first, after ~6s.
  if [ "$tool" = AskUserQuestion ]; then
    grep -qx question <(sed -n 2p "$(wait_file "$sid")" 2>/dev/null) && exit 0
    new_wait question ""; start_timer "$sid" "$token" first
  else
    new_wait permission "$(asks_for)"; start_timer "$sid" "$token"
    [ "$tool" = Bash ] && record_cmd
  fi
  ;;
decide)
  # PermissionRequest, next to ask: Earshot for Mac can answer the prompt by
  # voice. The dialog stays on screen meanwhile; the first answer wins. Without
  # the app, or when it can't listen now, this ends at once.
  [ "$tool" = AskUserQuestion ] && exit 0
  app_up || exit 0
  # ask starts at the same moment and writes the wait file.
  wf=$(wait_file "$sid")
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do [ -f "$wf" ] && break; sleep 0.2; done
  read -r token 2>/dev/null < "$wf" || exit 0
  id="$now-$$-$RANDOM"; ans="$STATE/answer-$sid-$id"
  app_send "$(jq -nc --arg s "$sid" --arg i "$id" --arg n "$who" --arg w "$(asks_for)" --arg a "$ans" \
    '{v: 1, type: "approval", session: $s, id: $i, name: $n, what: $w, answer: $a}')" || exit 0
  # closed <by>: the app stops listening for this prompt. In the background,
  # and away from stdout, which carries the decision.
  closed_msg() { jq -nc --arg s "$sid" --arg i "$id" --arg b "$1" '{v: 1, type: "approval", session: $s, id: $i, state: "closed", by: $b}'; }
  closed() { app_send "$(closed_msg "$1")" </dev/null >/dev/null 2>&1 & }
  # Esc on the dialog: Claude Code stops this hook. Tell the app before going,
  # in the foreground, since the whole process group may be stopping.
  trap 'app_send "$(closed_msg screen)" </dev/null >/dev/null 2>&1; exit 0' TERM INT HUP
  deadline=$((now + DECIDE_SECS)); n=0
  while :; do
    if [ -e "$ans" ] || [ -L "$ans" ]; then
      # Trusted only as a plain file of yours that nobody else can write.
      a=
      [ -f "$ans" ] && [ ! -L "$ans" ] && [ -O "$ans" ] && [ $((0$(stat -f %Lp "$ans") & 022)) = 0 ] \
        && a=$(head -c 16 "$ans" | tr -d '[:space:]')
      rm -f "$ans"
      if [ "$a" = allow ] || [ "$a" = deny ]; then
        # After a deny no tool runs, so nothing else would stop the reminders.
        clear_wait
        if [ -s "$warned" ]; then set_status stuck; else set_status working; fi
        echo "$(date '+%F %T') $who: answered by voice ($a)" >> "$LOG"
        if [ "$a" = allow ]; then
          echo '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}'
        else
          echo '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"The user said no by voice."}}}'
        fi
        closed voice; exit 0
      fi
    fi
    # Answered on screen: the tool ran (no wait file), a newer prompt took its
    # place (new token), Esc or No (the transcript moved on), or, every 2 s,
    # a long command you approved is running.
    if [ "$(head -1 "$wf" 2>/dev/null)" != "$token" ] || ! still_waiting "$sid" \
      || { [ $((++n % 4)) = 0 ] && approved "$sid"; }; then
      closed screen; exit 0
    fi
    [ "$(date +%s)" -ge "$deadline" ] && { closed timeout; exit 0; }
    sleep 0.5
  done
  ;;
question)
  # PreToolUse for AskUserQuestion: the same grace period, then reminders.
  new_wait question ""; start_timer "$sid" "$token" first
  ;;
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
pretool)
  # PreToolUse (async) for Bash, MCP tools and web calls: one long call fires
  # no other hook until it ends, so a timer gives the "still on it" updates.
  [ "$(jq -r '.tool_input.run_in_background // false' <<<"$input")" = true ] && exit 0
  # Updates are progress lines, so quiet level needs no timer.
  case "$LEVEL" in normal|all) ;; *) exit 0 ;; esac
  stop_watch
  # No turn file: this async hook landed after the turn already ended.
  [ -f "$state" ] || exit 0
  if [ "$tool" = Bash ]; then desc=$(jq -r '.tool_input.description // empty | gsub("[\r\n]+"; " ")' <<<"$input")
  else desc=$(asks_for); desc=${desc#to }
  fi
  token=$(jq -r '.tool_use_id // empty' <<<"$input"); [ -n "$token" ] || token="$now-$$"
  printf '%s\n%s\n%s\n' "$token" "$on" "$desc" > "$running"
  watch_command "$sid" "$token" "$transcript"
  ;;
notify)
  # Notification permission_prompt: the prompt has waited about 6 seconds.
  { read -r _; read -r kind; read -r _; read -r what; } 2>/dev/null < "$(wait_file "$sid")"
  [ "$kind" = question ] && exit 0
  if [ -n "$what" ]; then tell need "Hey, $who needs your OK $what."
  else tell need "Hey, $who needs your OK before it keeps going."
  fi
  ;;
idle)
  # Notification idle_prompt: 60s after a turn ended with no typing. Speak only
  # when the last reply asked the user something.
  [ -f "$transcript" ] || exit 0
  last=$(last_text \
    | sed -e 's/[[:space:]]*$//' | grep -v '^$' | tail -1)
  case "$last" in *'?') set_status reply; tell reply "Hey, $who is still waiting on your answer." ;; esac
  ;;
stop)
  stop_watch
  clear_wait
  # Your own cache is not cleared at restart like /tmp. Drop lines unused for a
  # month and downloads that never finished.
  find "$CACHE" -type f \( \( -name '*.mp3' -o -name '*.wav' -o -name '*.aiff' \) -mtime +30 -o -name 'dl.*' -mmin +10 \) -delete 2>/dev/null
  # Lines said with the Mac's voice after an engine failed, left by a crash.
  find "$STATE" -maxdepth 1 -type f -name 'fallback.*' -mmin +10 -delete 2>/dev/null
  # Sessions that quit without SessionEnd leave files; 6 hours quiet means gone.
  find "$STATE" -maxdepth 1 -type f \( -name 'status-*' -o -name 'running-*' -o -name 'wait-*' -o -name 'cmd-*' \) -mmin +360 -delete 2>/dev/null
  rm -f "$state" "$hist" "$errs" "$warned"
  msg=$(jq -r '.last_assistant_message // empty' <<<"$input")
  if [ -z "$msg" ]; then
    [ -f "$transcript" ] && msg=$(last_text)
  fi
  # Take the text after the last 🗣 (with or without the emoji variation
  # selector), and drop markdown marks so they are not read aloud.
  # Only a line that starts with it counts, and at most 40 words are read, so
  # quoted text cannot turn into a long or costly speech.
  line=$(printf '%s\n' "$msg" | LC_ALL=C grep '^[[:space:]*_>]*🗣' | tail -1 \
    | LC_ALL=C sed -e 's/.*🗣//' -e $'s/^\xef\xb8\x8f//' -e 's/[*_`]//g' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
    | awk '{for (i = 1; i <= NF && i <= 40; i++) printf "%s%s", $i, (i < NF && i < 40 ? " " : "")}')
  # The roll call keeps the line, at most 15 words. A turn with no line ends a
  # working session but keeps a finished session's last line.
  if [ -n "$line" ]; then set_status done "$(awk '{for (i = 1; i <= NF && i <= 15; i++) printf "%s%s", $i, (i < NF && i < 15 ? " " : "")}' <<<"$line")"
  else case "$(head -1 "$status" 2>/dev/null)" in done|open|reply) ;; *) set_status done ;; esac
  fi
  # With other sessions open, say whose summary it is.
  [ -n "$line" ] && [ "$SESSION_NAME" != never ] && { [ "$others" -gt 0 ] || [ "$SESSION_NAME" = always ]; } && line="From $who: $line"
  [ -n "$line" ] && tell done "$line"
  ;;
fail)
  stop_watch
  clear_wait
  rm -f "$state" "$hist" "$errs" "$warned"
  set_status failed
  tell alert "$(upper_first "$who") hit an error. Take a look when you can."
  ;;
esac
exit 0
