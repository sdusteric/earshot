#!/bin/bash
# Earshot setup: saves your ElevenLabs key and voice, builds the microphone
# helper, and plays a test line. Safe to run again, e.g. to change the voice.
#
#   setup.sh                        ask for the key and voice (needs a terminal)
#   setup.sh --key-from-clipboard   read the key from the clipboard
#   setup.sh --key-file PATH        read the key from a file
#   setup.sh --voice VOICE_ID       use this voice without asking
#   setup.sh --list-voices          print voices you can use, then stop
#   setup.sh --status               print what is set up, then stop
#   setup.sh --auto-update          let Claude Code update Earshot by itself
#   setup.sh --no-auto-update       turn that off again
#   setup.sh --level LEVEL          how much Earshot says: quiet, normal or all
#   setup.sh --style STYLE          tone of the finished line: plain, upbeat or cheeky
set -euo pipefail

DIR=~/.config/earshot
CONF=$DIR/config
SCRIPTS=$(cd "$(dirname "$0")" && pwd)
DEFAULT_VOICE=CwhRBWXzGAHq8TQ4Fs17   # Roger, a premade voice that works on every plan
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

die() { printf '%s\n' "$*" >&2; exit 1; }
say_ok() { printf '  %s\n' "$*"; }

for t in jq curl afplay; do
  command -v $t >/dev/null || die "Missing $t. Install it (jq: brew install jq) and run setup again."
done

EARSHOT_KEY= EARSHOT_VOICE= EARSHOT_MODEL=
[ -f "$CONF" ] && . "$CONF"
KEY=$EARSHOT_KEY VOICE=$EARSHOT_VOICE MODEL=${EARSHOT_MODEL:-eleven_v4_turbo}

key_src= voice_arg= mode=setup
while [ $# -gt 0 ]; do
  case "$1" in
    --key-from-clipboard) key_src=clipboard ;;
    --key-file) key_src=file; key_file=${2:?--key-file needs a path}; shift ;;
    --voice) voice_arg=${2:?--voice needs a voice ID}; shift ;;
    --list-voices) mode=list ;;
    --status) mode=status ;;
    --level) mode=level; level=${2:?--level needs quiet, normal or all}; shift ;;
    --style) mode=style; style=${2:?--style needs plain, upbeat or cheeky}; shift ;;
    --auto-update) mode=autoupdate; au=true ;;
    --no-auto-update) mode=autoupdate; au=false ;;
    -h|--help) sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "Unknown option: $1 (try --help)" ;;
  esac
  shift
done

# api METHOD PATH [JSON] -> prints the HTTP code, body in $TMP/body
api() {
  local args=(-s -o "$TMP/body" -w '%{http_code}' -X "$1" "https://api.elevenlabs.io$2" -H @-)
  [ $# -ge 3 ] && args+=(-H 'Content-Type: application/json' -d "$3")
  # The key goes in through stdin so it never shows up in the process list.
  printf 'xi-api-key: %s\n' "$KEY" | curl "${args[@]}" || true
}

# Premade voices work on every ElevenLabs plan. Used when the key cannot list voices.
FALLBACK_VOICES="CwhRBWXzGAHq8TQ4Fs17	premade	Roger - Laid-Back, Casual, Resonant
EXAVITQu4vr4xnSDxMaL	premade	Sarah - Mature, Reassuring, Confident
SAz9YHcvj6GT2YYXdXww	premade	River - Relaxed, Neutral, Informative
cjVigY5qzO86Huf0OWal	premade	Eric - Smooth, Trustworthy
Xb7hH8MSUJpSbSDYk0k2	premade	Alice - Clear, Engaging Educator
JBFqnCBsd6RMkjVDRZzb	premade	George - Warm, Captivating Storyteller
cgSgspJ2msm6clMCkdW9	premade	Jessica - Playful, Bright, Warm
iP95p4xoKVk53GoZ742B	premade	Chris - Charming, Down-to-Earth
XrExE9yKIg1WjnnlVkGX	premade	Matilda - Knowledgable, Professional
onwK4e9ZLuTAKqWW03F9	premade	Daniel - Steady Broadcaster"

# Prints "id<TAB>category<TAB>name" lines: your own voices first, then premade ones.
voices() {
  if [ -n "$KEY" ] && [ "$(api GET /v1/voices)" = 200 ]; then
    jq -r '.voices
      | sort_by(if .category == "premade" then 1 else 0 end)
      | .[] | [.voice_id, .category, .name] | @tsv' "$TMP/body"
  else
    printf '%s\n' "$FALLBACK_VOICES"
  fi
}

voice_name() {
  local n
  n=$(voices | awk -F'\t' -v id="$1" '$1 == id { print $3; exit }')
  printf '%s' "${n:-$1}"
}

# Turns an ElevenLabs error into something a person can act on.
explain() {
  local code=$1 status msg
  status=$(jq -r '.detail.status // .detail.code // empty' "$TMP/body" 2>/dev/null || true)
  msg=$(jq -r '.detail.message // .detail // empty' "$TMP/body" 2>/dev/null || head -c 200 "$TMP/body")
  case "$code:$status:$msg" in
    000:*) echo "Could not reach ElevenLabs. Check your internet connection." ;;
    401:missing_permissions:*) echo "The key works but lacks the Text to Speech permission. Edit it at elevenlabs.io > Developers > API Keys." ;;
    401:*) echo "ElevenLabs rejected the key. Check that you copied all of it (it starts with sk_)." ;;
    *:free_users_not_allowed:*|*tier*)
      echo "Your ElevenLabs plan can't use this voice through the API. ($msg)"
      echo "ElevenLabs sells separate plans for ElevenCreative, ElevenAgents and ElevenAPI, so a paid plan for one may not cover text to speech."
      echo "Premade voices work on every plan: pick one from the list." ;;
    *:quota_exceeded:*) echo "Your ElevenLabs account is out of credits for this month." ;;
    404:*|*:voice_not_found:*) echo "No voice with that ID. Copy the ID from your Voices page, or pick one from the list." ;;
    *) echo "ElevenLabs returned HTTP $code: $msg" ;;
  esac
}

SETTINGS="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"

# Auto-update is a per-user setting: the autoUpdate flag on Earshot's entry in
# extraKnownMarketplaces, the same flag the /plugin Marketplaces toggle writes.
if [ "$mode" = autoupdate ]; then
  [ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
  jq empty "$SETTINGS" 2>/dev/null || die "$SETTINGS is not valid JSON. Fix it, then run this again."
  jq --argjson on "$au" '
    .extraKnownMarketplaces.earshot.source //= {source: "github", repo: "sdusteric/earshot"}
    | .extraKnownMarketplaces.earshot.autoUpdate = $on' "$SETTINGS" > "$SETTINGS.earshot-tmp" \
    && cat "$SETTINGS.earshot-tmp" > "$SETTINGS" && rm -f "$SETTINGS.earshot-tmp"
  # Claude Code's own record, which the /plugin toggle also writes.
  KNOWN="${CLAUDE_CODE_PLUGIN_CACHE_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins}/known_marketplaces.json"
  if jq -e '.earshot' "$KNOWN" >/dev/null 2>&1; then
    jq --argjson on "$au" '.earshot.autoUpdate = $on' "$KNOWN" > "$KNOWN.earshot-tmp" && cat "$KNOWN.earshot-tmp" > "$KNOWN" && rm -f "$KNOWN.earshot-tmp"
  fi
  if [ "$au" = true ]; then
    echo "Auto-update is on. Claude Code now installs new Earshot versions by itself, a few minutes after a session starts."
  else
    echo "Auto-update is off. To update, run: claude plugin update earshot@earshot"
  fi
  exit 0
fi

# set_conf NAME VALUE: level and style are lines in the config file; other
# lines stay as they are.
set_conf() {
  mkdir -p "$DIR"
  ( umask 077; touch "$CONF"; { grep -v "^$1=" "$CONF" || true; } > "$CONF.tmp"; echo "$1=$2" >> "$CONF.tmp"; mv "$CONF.tmp" "$CONF" )
}

if [ "$mode" = level ]; then
  case "$level" in quiet|normal|all) ;; *) die "Level must be quiet, normal or all." ;; esac
  set_conf EARSHOT_LEVEL "$level"
  case "$level" in
    quiet) echo "Level: quiet. Earshot speaks only when it needs you, when it might be stuck, when something fails, and when Claude finishes." ;;
    normal) echo "Level: normal. Quiet, plus a short progress update every few minutes." ;;
    all) echo "Level: all. Normal, plus \"On it\" when your prompt arrives." ;;
  esac
  exit 0
fi

if [ "$mode" = style ]; then
  case "$style" in plain|upbeat|cheeky) ;; *) die "Style must be plain, upbeat or cheeky." ;; esac
  set_conf EARSHOT_STYLE "$style"
  case "$style" in
    plain) echo "Style: plain. The finished line says what Claude did, nothing extra." ;;
    upbeat) echo "Style: upbeat. The finished line adds a little encouragement. Alerts stay plain." ;;
    cheeky) echo "Style: cheeky. The finished line adds a light joke when it fits. Alerts stay plain." ;;
  esac
  exit 0
fi

if [ "$mode" = list ]; then
  voices
  exit 0
fi

if [ "$mode" = status ]; then
  echo "Config: $CONF"
  [ -n "$KEY" ] && say_ok "Key: saved" || say_ok "Key: missing"
  [ -n "$VOICE" ] && say_ok "Voice: $(voice_name "$VOICE") ($VOICE)" || say_ok "Voice: not chosen"
  [ -x "$DIR/mic-in-use" ] && say_ok "Microphone check: built" || say_ok "Microphone check: not built (Earshot won't stop when you talk or wait while you're on a call)"
  [ "$(jq -r '.voice.enabled // .voiceEnabled // false' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json" 2>/dev/null)" = true ] \
    && say_ok "/voice: on" || say_ok "/voice: off (Earshot stays quiet until you turn it on)"
  case "$(jq -r '.extraKnownMarketplaces.earshot | if . == null then "none" elif .source.source == "directory" then "local" else (.autoUpdate // false | tostring) end' "$SETTINGS" 2>/dev/null)" in
    true) say_ok "Auto-update: on" ;;
    local) say_ok "Auto-update: local folder. Claude Code runs a copy, so after a change run: claude plugin marketplace update earshot && claude plugin update earshot@earshot" ;;
    *) say_ok "Auto-update: off (turn it on: setup.sh --auto-update)" ;;
  esac
  say_ok "Level: $(sed -n 's/^EARSHOT_LEVEL=//p' "$CONF" 2>/dev/null | tail -1 | grep . || echo normal)"
  say_ok "Style: $(sed -n 's/^EARSHOT_STYLE=//p' "$CONF" 2>/dev/null | tail -1 | grep . || echo plain)"
  [ -e "$DIR/mute" ] && say_ok "Muted: yes (rm $DIR/mute to unmute)"
  exit 0
fi

# --- Key ---------------------------------------------------------------------
case "$key_src" in
  clipboard) KEY=$(pbpaste | tr -d '[:space:]') ;;
  file) [ -r "$key_file" ] || die "Can't read $key_file."; KEY=$(tr -d '[:space:]' < "$key_file") ;;
  *)
    if [ -z "$KEY" ]; then
      if [ -t 0 ]; then
        read -rsp "ElevenLabs API key (hidden): " KEY; echo
        KEY=$(printf '%s' "$KEY" | tr -d '[:space:]')
      else
        die "No ElevenLabs key yet, and there's no terminal to type one in.
Copy your key, then run: bash \"$SCRIPTS/setup.sh\" --key-from-clipboard
Or run this script in Terminal so it can ask for the key."
      fi
    fi ;;
esac
[[ "$KEY" == sk_* ]] || die "That doesn't look like an ElevenLabs API key (they start with sk_)."

# --- Voice -------------------------------------------------------------------
pick_voice() {
  local list i=0 line id cat name def choice
  list=$(voices)
  def=${VOICE:-$DEFAULT_VOICE}
  echo
  echo "Voices you can use:"
  while IFS=$'\t' read -r id cat name; do
    i=$((i + 1))
    printf '  %2d) %s%s%s\n' "$i" "$name" "$([ "$cat" = premade ] || echo " [$cat]")" "$([ "$id" = "$def" ] && echo "  (current)")"
  done <<<"$list"
  read -rp "Number, a voice ID, or Enter for $(voice_name "$def"): " choice
  if [ -z "$choice" ]; then VOICE=$def
  elif [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "$i" ]; then
    VOICE=$(sed -n "${choice}p" <<<"$list" | cut -f1)
  else VOICE=$choice
  fi
}

if [ -n "$voice_arg" ]; then VOICE=$voice_arg
elif [ -t 0 ]; then pick_voice
else VOICE=${VOICE:-$DEFAULT_VOICE}
fi

# --- Test the key and voice --------------------------------------------------
test_line='{"text":"Earshot is set up. Talk to you soon.","model_id":"'"$MODEL"'"}'
tries=0
while :; do
  code=$(api POST "/v1/text-to-speech/$VOICE" "$test_line")
  [ "$code" = 200 ] && break
  explain "$code" >&2
  tries=$((tries + 1))
  if [ -t 0 ] && [ -z "$voice_arg" ] && [ "$code" != 401 ] && [ $tries -lt 3 ]; then
    pick_voice
  else
    die "Setup stopped. Nothing was saved."
  fi
done
mv "$TMP/body" "$TMP/test.mp3"

# --- Save --------------------------------------------------------------------
mkdir -p "$DIR"
( umask 077
  { printf 'EARSHOT_KEY=%q\n' "$KEY"
    printf 'EARSHOT_VOICE=%q\n' "$VOICE"
    if [ -n "$EARSHOT_MODEL" ]; then printf 'EARSHOT_MODEL=%q\n' "$EARSHOT_MODEL"; fi
    # Every other setting stays as it is.
    grep -E '^EARSHOT_' "$CONF" 2>/dev/null | grep -vE '^EARSHOT_(KEY|VOICE|MODEL)=' || true
  } > "$CONF.tmp"
  mv "$CONF.tmp" "$CONF" )
echo "Saved your key and voice to $CONF (only you can read it)."

if command -v swiftc >/dev/null; then
  swiftc -O "$SCRIPTS/mic-in-use.swift" -o "$DIR/mic-in-use" 2>/dev/null \
    && echo "Built the microphone check, so Earshot stops talking when you start and waits while you're on a call." \
    || echo "Couldn't build the microphone check. Earshot still works but won't stop when you talk."
else
  echo "swiftc not found (xcode-select --install), so Earshot won't stop when you talk. Everything else works."
fi

afplay "$TMP/test.mp3"
echo "Done. Voice: $(voice_name "$VOICE"). In Claude Code, run /voice to turn it on."
