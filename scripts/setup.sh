#!/bin/bash
# Earshot setup: chooses the engine and voice, builds the helpers, and plays a
# test line. Safe to run again, e.g. to change the voice.
#
#   setup.sh                        set up the saved engine, or Kokoro the first time
#   setup.sh --engine ENGINE        kokoro (on this Mac), elevenlabs or say
#   setup.sh --voice VOICE          a Kokoro voice (af_heart), an ElevenLabs voice ID, or a say voice
#   setup.sh --key-from-clipboard   ElevenLabs: read the key from the clipboard
#   setup.sh --key-file PATH        ElevenLabs: read the key from a file
#   setup.sh --list-voices          print the voices for the engine, then stop
#   setup.sh --status               print what is set up, then stop
#   setup.sh --auto-update          let Claude Code update Earshot by itself
#   setup.sh --no-auto-update       turn that off again
#   setup.sh --level LEVEL          how much Earshot says: quiet, normal or all
#   setup.sh --style STYLE          tone of the finished line: plain, upbeat or cheeky
set -euo pipefail

DIR=~/.config/earshot
CONF=${EARSHOT_CONF:-$DIR/config}   # tests point this elsewhere
SCRIPTS=$(cd "$(dirname "$0")" && pwd)
DEFAULT_VOICE=CwhRBWXzGAHq8TQ4Fs17   # Roger, a premade voice that works on every plan
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

die() { printf '%s\n' "$*" >&2; exit 1; }
say_ok() { printf '  %s\n' "$*"; }

for t in jq curl afplay; do
  command -v $t >/dev/null || die "Missing $t. Install it (jq: brew install jq) and run setup again."
done

EARSHOT_KEY= EARSHOT_VOICE= EARSHOT_MODEL= EARSHOT_ENGINE= EARSHOT_KOKORO_VOICE= EARSHOT_SAY_VOICE=
[ -f "$CONF" ] && . "$CONF"
KEY=$EARSHOT_KEY VOICE=$EARSHOT_VOICE MODEL=${EARSHOT_MODEL:-eleven_v4_turbo}
STATE_DIR=${EARSHOT_STATE_DIR:-$(getconf DARWIN_USER_TEMP_DIR)earshot}   # same folder as speak.sh
TTS=${EARSHOT_KOKORO_DIR:-$DIR/kokoro}/earshot-tts   # build-tts.sh installs it there
KOKORO_DEFAULT=af_heart

key_src= voice_arg= engine_arg= mode=setup
while [ $# -gt 0 ]; do
  case "$1" in
    --engine) engine_arg=${2:?--engine needs kokoro, elevenlabs or say}; shift ;;
    --key-from-clipboard) key_src=clipboard ;;
    --key-file) key_src=file; key_file=${2:?--key-file needs a path}; shift ;;
    --voice) voice_arg=${2:?--voice needs a voice}; shift ;;
    --list-voices) mode=list ;;
    --status) mode=status ;;
    --level) mode=level; level=${2:?--level needs quiet, normal or all}; shift ;;
    --style) mode=style; style=${2:?--style needs plain, upbeat or cheeky}; shift ;;
    --auto-update) mode=autoupdate; au=true ;;
    --no-auto-update) mode=autoupdate; au=false ;;
    -h|--help) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "Unknown option: $1 (try --help)" ;;
  esac
  shift
done

# The engine: the flag, else the saved one, else ElevenLabs for a config with a
# key from before 0.9.0, else Kokoro. Giving a key means ElevenLabs.
if [ -n "$engine_arg" ]; then ENGINE=$engine_arg
elif [ -n "$key_src" ]; then ENGINE=elevenlabs
elif [ -n "$EARSHOT_ENGINE" ]; then ENGINE=$EARSHOT_ENGINE
elif [ -n "$KEY" ]; then ENGINE=elevenlabs
else ENGINE=kokoro
fi
case "$ENGINE" in kokoro|elevenlabs|say) ;; *) die "Engine must be kokoro, elevenlabs or say." ;; esac

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

# Kokoro voices: from the helper when it is built, else the four we suggest.
kokoro_voices() {
  if [ -x "$TTS" ]; then "$TTS" voices; else printf '%s\n' af_heart af_bella am_michael bm_george; fi
}
say_voices() { say -v '?' | grep -E ' en_[A-Z]{2} ' | sed -E 's/ +en_[A-Z]{2} .*//'; }

# kokoro_support: why Kokoro can't run on this Mac, or nothing when it can.
# build-tts.sh checks the same things before it builds.
kokoro_support() {
  [ "$(uname -m)" = arm64 ] || { echo "no, it needs a Mac with Apple Silicon"; return; }
  [ "$(sw_vers -productVersion | cut -d. -f1)" -ge 15 ] || { echo "no, it needs macOS 15 or later"; return; }
  xcode-select -p >/dev/null 2>&1 || echo "not yet, it needs the Command Line Tools (run xcode-select --install)"
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

# save_conf NAME VALUE [NAME VALUE ...]: sets these config lines. Every other
# line stays as it is.
save_conf() {
  local a=("$@") names="" i
  mkdir -p "$DIR"
  for ((i = 0; i < ${#a[@]}; i += 2)); do names+="${a[i]}|"; done
  ( umask 077
    { for ((i = 0; i < ${#a[@]}; i += 2)); do printf '%s=%q\n' "${a[i]}" "${a[i+1]}"; done
      grep -E '^EARSHOT_' "$CONF" 2>/dev/null | grep -vE "^(${names%|})=" || true
    } > "$CONF.tmp"
    mv "$CONF.tmp" "$CONF" )
}

if [ "$mode" = level ]; then
  case "$level" in quiet|normal|all) ;; *) die "Level must be quiet, normal or all." ;; esac
  save_conf EARSHOT_LEVEL "$level"
  case "$level" in
    quiet) echo "Level: quiet. Earshot speaks only when it needs you, when it might be stuck, when something fails, and when Claude finishes." ;;
    normal) echo "Level: normal. Quiet, plus a short progress update every few minutes." ;;
    all) echo "Level: all. Normal, plus \"On it\" when your prompt arrives." ;;
  esac
  exit 0
fi

if [ "$mode" = style ]; then
  case "$style" in plain|upbeat|cheeky) ;; *) die "Style must be plain, upbeat or cheeky." ;; esac
  save_conf EARSHOT_STYLE "$style"
  case "$style" in
    plain) echo "Style: plain. The finished line says what Claude did, nothing extra." ;;
    upbeat) echo "Style: upbeat. The finished line adds a little encouragement. Alerts stay plain." ;;
    cheeky) echo "Style: cheeky. The finished line adds a light joke when it fits. Alerts stay plain." ;;
  esac
  exit 0
fi

if [ "$mode" = list ]; then
  case "$ENGINE" in kokoro) kokoro_voices ;; elevenlabs) voices ;; say) say_voices ;; esac
  exit 0
fi

if [ "$mode" = status ]; then
  echo "Config: $CONF"
  # No engine line and no key: the default, nothing chosen yet.
  say_ok "Engine: $ENGINE$([ -z "$EARSHOT_ENGINE" ] && [ -z "$KEY" ] && echo " (not set up yet)")"
  why=$(kokoro_support)
  case "$ENGINE" in
    kokoro)
      say_ok "Voice: ${EARSHOT_KOKORO_VOICE:-$KOKORO_DEFAULT}"
      if [ "${why%%,*}" = no ]; then say_ok "Kokoro helper: not available on this Mac. Earshot uses the Mac's own voice."
      elif [ -e "$TTS.stale" ]; then say_ok "Kokoro helper: out of date, its rebuild after an update failed (run setup.sh --engine kokoro)"
      elif [ -x "$TTS" ]; then say_ok "Kokoro helper: built"
      else say_ok "Kokoro helper: not built (run setup.sh --engine kokoro). Until then Earshot uses the Mac's own voice."; fi
      pgrep -f "$TTS serve" >/dev/null && say_ok "Kokoro: loaded" || say_ok "Kokoro: not loaded (it loads with the next session or line)"
      [ -n "$KEY" ] && say_ok "ElevenLabs key: saved (setup.sh --engine elevenlabs switches back)" ;;
    elevenlabs)
      [ -n "$KEY" ] && say_ok "Key: saved" || say_ok "Key: missing"
      [ -n "$VOICE" ] && say_ok "Voice: $(voice_name "$VOICE") ($VOICE)" || say_ok "Voice: not chosen" ;;
    say) say_ok "Voice: ${EARSHOT_SAY_VOICE:-the system voice}" ;;
  esac
  say_ok "Kokoro on this Mac: ${why:-yes}"
  if [ -e "$DIR/mic-in-use.stale" ]; then say_ok "Microphone check: out of date, so Earshot doesn't wait during calls (run setup again to rebuild it)"
  elif [ -x "$DIR/mic-in-use" ]; then say_ok "Microphone check: built"
  else say_ok "Microphone check: not built (Earshot won't stop when you talk or wait while you're on a call)"; fi
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

# --- ElevenLabs --------------------------------------------------------------
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

setup_elevenlabs() {
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
Copy your key, then run: bash \"$SCRIPTS/setup.sh\" --engine elevenlabs --key-from-clipboard
Or run this script in Terminal so it can ask for the key."
        fi
      fi ;;
  esac
  [[ "$KEY" == sk_* ]] || die "That doesn't look like an ElevenLabs API key (they start with sk_)."

  if [ -n "$voice_arg" ]; then VOICE=$voice_arg
  elif [ -t 0 ]; then pick_voice
  else VOICE=${VOICE:-$DEFAULT_VOICE}
  fi

  # Test the key and voice.
  local test_line tries=0 code
  test_line='{"text":"Earshot is set up. Talk to you soon.","model_id":"'"$MODEL"'"}'
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

  save_conf EARSHOT_ENGINE elevenlabs EARSHOT_KEY "$KEY" EARSHOT_VOICE "$VOICE" \
    ${EARSHOT_MODEL:+EARSHOT_MODEL "$EARSHOT_MODEL"}
  echo "Saved your key and voice to $CONF (only you can read it)."
  TEST=$TMP/test.mp3
  DONE_MSG="Done. Voice: $(voice_name "$VOICE") (ElevenLabs)."
}

# --- Kokoro ------------------------------------------------------------------
# kokoro_label af_heart -> "American English, female": what the name's prefix means.
kokoro_label() {
  case "$1" in
    af_*) echo "American English, female" ;; am_*) echo "American English, male" ;;
    bf_*) echo "British English, female" ;; bm_*) echo "British English, male" ;;
  esac
}

pick_kokoro_voice() {
  local list i=0 v choice def=${EARSHOT_KOKORO_VOICE:-$KOKORO_DEFAULT}
  list=$(printf '%s\n' af_heart af_bella am_michael bm_george)
  echo; echo "Kokoro voices (setup.sh --engine kokoro --list-voices shows all):"
  while read -r v; do
    i=$((i + 1))
    printf '  %d) %-11s %s%s\n' "$i" "$v" "$(kokoro_label "$v")" "$([ "$v" = "$def" ] && echo "  (current)")"
  done <<<"$list"
  read -rp "Number, a voice name, or Enter for $def: " choice
  if [ -z "$choice" ]; then KVOICE=$def
  elif [[ "$choice" =~ ^[1-4]$ ]]; then KVOICE=$(sed -n "${choice}p" <<<"$list")
  else KVOICE=$choice
  fi
}

# The helper is current when it was built from these sources (build-tts.sh
# writes source.md5) and its last rebuild did not fail (TTS.stale).
kokoro_current() {
  local src=$SCRIPTS/../tts
  [ -x "$TTS" ] && [ ! -e "$TTS.stale" ] \
    && [ "$(cat "$src/Package.swift" "$src/Package.resolved" "$src/Sources/earshot-tts/main.swift" | md5 -q)" \
      = "$(cat "${TTS%/*}/source.md5" 2>/dev/null)" ]
}

setup_kokoro() {
  KVOICE=${voice_arg:-${EARSHOT_KOKORO_VOICE:-$KOKORO_DEFAULT}}
  if [ -z "$voice_arg" ] && [ -t 0 ]; then pick_kokoro_voice; fi
  ( umask 077; mkdir -p "$STATE_DIR" )
  if ! kokoro_current; then
    local why; why=$(kokoro_support)
    [ -z "$why" ] || die "Kokoro can't run on this Mac: ${why#*, }. Nothing was saved. To use ElevenLabs instead, run: setup.sh --engine elevenlabs"
    echo "Building the Kokoro helper. The first build takes about 2 minutes."
    # The same lock as the rebuild that hooks start after an update, so the
    # two never write the helper at once. This waits for that one to finish.
    local rc=0
    lockf -k -t 900 "$STATE_DIR/tts-build.lock" bash "${EARSHOT_BUILD_TTS:-$SCRIPTS/build-tts.sh}" >&2 || rc=$?
    [ "$rc" = 75 ] && die "Another build of the Kokoro helper is still running. Try setup again in a few minutes."
    [ "$rc" = 0 ] || die "Setup stopped. Nothing was saved. To use ElevenLabs instead, run: setup.sh --engine elevenlabs"
  fi
  kokoro_voices | grep -qx -- "$KVOICE" \
    || die "Kokoro has no voice called $KVOICE. To see the list, run: setup.sh --engine kokoro --list-voices"
  echo "Getting the voice ready. The first time, this downloads it (about 460 MB on disk)."
  # Both runtimes: Kokoro retries a line on the older one when v3 fails, and
  # that should never mean a download while you work. Exit 3: only the older
  # one failed, and Kokoro works without it.
  local prc=0
  "$TTS" prepare --voice "$KVOICE" >/dev/null 2>"$TMP/err" || prc=$?
  case "$prc" in
    0) ;;
    3) echo "Note: the backup voice model didn't download ($(tail -1 "$TMP/err")). Kokoro works. A line it can't say uses the Mac's own voice until you run setup again." ;;
    *) die "Kokoro couldn't load: $(tail -1 "$TMP/err"). Nothing was saved. To use ElevenLabs instead, run: setup.sh --engine elevenlabs" ;;
  esac
  printf 'Earshot is set up. Talk to you soon.' \
    | "$TTS" speak --socket "$STATE_DIR/kokoro.sock" --voice "$KVOICE" --out "$TMP/test.wav" --timeout 600 2>"$TMP/err" \
    || die "Kokoro couldn't make the test line: $(tail -1 "$TMP/err"). Nothing was saved. To use ElevenLabs instead, run: setup.sh --engine elevenlabs"
  save_conf EARSHOT_ENGINE kokoro EARSHOT_KOKORO_VOICE "$KVOICE"
  TEST=$TMP/test.wav
  DONE_MSG="Done. Voice: $KVOICE (Kokoro, on this Mac: free, and your lines stay on it)."
}

# --- The Mac's own voice -----------------------------------------------------
setup_say() {
  local v=${voice_arg:-$EARSHOT_SAY_VOICE}
  printf 'Earshot is set up. Talk to you soon.' > "$TMP/line"
  say ${v:+-v "$v"} -f "$TMP/line" -o "$TMP/test.aiff" || die "say couldn't make the test line. Nothing was saved."
  save_conf EARSHOT_ENGINE say EARSHOT_SAY_VOICE "$v"
  TEST=$TMP/test.aiff
  DONE_MSG="Done. Voice: ${v:-the system voice} (the Mac's own voice)."
}

# In a terminal, ask for the engine unless a flag chose it.
pick_engine() {
  local choice why
  why=$(kokoro_support)
  if [ "${why%%,*}" = no ]; then
    echo "Kokoro can't run on this Mac: ${why#*, }."
    echo "Which voice should Earshot use?"
    echo "  1) ElevenLabs: natural voices, needs an API key, about \$8 a month$([ "$ENGINE" = elevenlabs ] && echo "  (current)")"
    echo "  2) The Mac's own voice: free and built in, but sounds robotic$([ "$ENGINE" = say ] && echo "  (current)")"
    read -rp "1 or 2: " choice
    case "$choice" in 2) ENGINE=say ;; *) ENGINE=elevenlabs ;; esac
    return
  fi
  echo "Which voice should Earshot use?"
  echo "  1) Kokoro: free, runs on this Mac, and your lines never leave it$([ "$ENGINE" = kokoro ] && echo "  (current)")"
  echo "  2) ElevenLabs: more expressive, needs an API key, about \$8 a month$([ "$ENGINE" = elevenlabs ] && echo "  (current)")"
  read -rp "1 or 2, or Enter for $ENGINE: " choice
  case "$choice" in 1) ENGINE=kokoro ;; 2) ENGINE=elevenlabs ;; esac
}
if [ -z "$engine_arg" ] && [ -z "$key_src" ] && [ -t 0 ]; then pick_engine; fi

case "$ENGINE" in
  kokoro) setup_kokoro ;;
  elevenlabs) setup_elevenlabs ;;
  say) setup_say ;;
esac

if command -v swiftc >/dev/null; then
  swiftc -O "$SCRIPTS/mic-in-use.swift" -o "$DIR/mic-in-use" 2>/dev/null \
    && rm -f "$DIR/mic-in-use.stale" \
    && echo "Built the microphone check, so Earshot stops talking when you start and waits while you're on a call." \
    || echo "Couldn't build the microphone check. Earshot still works but won't stop when you talk."
else
  echo "swiftc not found (xcode-select --install), so Earshot won't stop when you talk. Everything else works."
fi

# Everything is saved by now, so a Mac that can't play sound is not a failed setup.
if ! afplay "$TEST" 2>"$TMP/play-err"; then
  echo "Saved, but this Mac couldn't play the test line ($(tail -1 "$TMP/play-err")). Check the sound output in System Settings > Sound, then run setup again to hear it."
fi
echo "$DONE_MSG In Claude Code, run /voice to turn it on."
