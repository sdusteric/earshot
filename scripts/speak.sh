#!/bin/bash
# Earshot: spoken updates for Claude Code via ElevenLabs.
# Modes: start | tool | stop | notify | fail (hooks), say "<text>" (manual test)
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
LOOP_REPEATS=${EARSHOT_LOOP_REPEATS:-3}   # same tool call this many times in a row = probably stuck
CACHE=/tmp/earshot-cache
LOG=/tmp/earshot.log
MIC=~/.config/earshot/mic-in-use

mic_on() { [ -x "$MIC" ] && "$MIC"; }

say() {
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

input=$(cat)
now=$(date +%s)
cwd=$(jq -r '.cwd // empty' <<<"$input")
proj=$(basename "$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null || echo "$cwd")" | tr '_-' '  ')
state="/tmp/earshot-$(jq -r '.session_id' <<<"$input")"

case "$1" in
start)
  # Few fixed phrases, so all of them come from the cache after the first use.
  acks=("Got it." "On it." "Okay, on it.")
  say "${acks[RANDOM % 3]}"
  echo "$now $now - 0" > "$state"
  # Plain stdout from UserPromptSubmit is added to Claude's context.
  cat <<'EOF'
Earshot voice is on. End your final reply with one line that starts with "🗣 " (the speaking-head emoji and a space). A hook reads that line aloud when you finish.
Write it the way a coworker talks out loud: casual, with contractions. Say the result. If there is a question or blocker for the user, say it first; if there is a real risk, say it last. When there is none, leave it out: never say that there is no blocker or no risk. One or two short sentences, 25 words at most; for a small task a few words are enough. No code, file paths, markdown, emotion tags or stage directions.
The prompt was probably dictated: read misheard code terms as the closest name in this repo, and ask if unsure.
EOF
  ;;
tool)
  [ -f "$state" ] || echo "$now $now - 0" > "$state"
  read -r start beat sig count < "$state"
  new_sig=$(jq -c '[.tool_name, .tool_input]' <<<"$input" | md5 -q)
  if [ "$new_sig" = "$sig" ]; then count=$((count + 1)); else count=1; fi
  if [ "$count" -eq "$LOOP_REPEATS" ]; then
    say "Heads up, $proj keeps running the same thing over and over. It might be stuck."
    beat=$now
  elif [ $((now - beat)) -ge "$BEAT_SECS" ]; then
    line="Still on $proj, about $(( (now - start) / 60 )) minutes in."
    desc=$(jq -r '.tool_input.description // empty' <<<"$input")
    [ -n "$desc" ] && line="$line Latest step: $(tr '[:upper:]' '[:lower:]' <<<"${desc:0:1}")${desc:1}."
    say "$line"
    beat=$now
  fi
  echo "$start $beat $new_sig $count" > "$state"
  ;;
stop)
  rm -f "$state"
  msg=$(jq -r '.last_assistant_message // empty' <<<"$input")
  if [ -z "$msg" ]; then
    transcript=$(jq -r '.transcript_path // empty' <<<"$input")
    [ -f "$transcript" ] && msg=$(jq -rs '[.[] | select(.type=="assistant") | .message.content[]? | select(.type=="text") | .text] | last // empty' "$transcript")
  fi
  # Take the text after the last 🗣 (with or without the emoji variation
  # selector), and drop markdown marks so they are not read aloud.
  line=$(printf '%s\n' "$msg" | LC_ALL=C grep '🗣' | tail -1 \
    | LC_ALL=C sed -e 's/.*🗣//' -e $'s/^\xef\xb8\x8f//' -e 's/[*_`]//g' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
  [ -n "$line" ] && say "$line"
  ;;
notify)
  say "Hey, $proj needs your OK before it keeps going."
  ;;
fail)
  rm -f "$state"
  say "Something broke in $proj. Take a look when you can."
  ;;
esac
exit 0
