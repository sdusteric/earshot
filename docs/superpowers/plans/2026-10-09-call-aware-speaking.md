# Call-aware speaking Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Earshot stays silent while any app uses the microphone, then says the urgent lines it held, most urgent first, once the mic is free.

**Architecture:** The Swift mic helper changes from "is the input device running" to "is an app, other than an always-on listener, capturing input". `speak.sh` gets a `speak` worker that holds a line in a queue file when the mic is busy, and a `release` watcher that waits for the mic to be free, then plays a deduplicated, sorted catch-up through the same speaker lock as every other line.

**Tech Stack:** bash 3.2 (macOS `/bin/bash`), BSD userland (`lockf`, `stat -f`, `md5 -q`), `jq`, Swift + CoreAudio (`swiftc`), macOS 14.2+ for per-app mic state.

**Spec:** `docs/superpowers/specs/2026-10-09-call-aware-speaking-design.md`

## Global Constraints

- macOS only. Scripts run under `/bin/bash` 3.2: no associative arrays, no `mapfile`, no `${var,,}`.
- Hooks must return in about 50 ms. Anything that can take longer (mic checks, downloads, builds) runs in the background.
- Every file Earshot writes is private (`umask 077` at the top of `speak.sh` already does this).
- Held queue: `$STATE/held`. One entry per line, fields separated by `\037` (unit separator): time, session ID, kind, text.
- Kinds: `need`, `alert`, `done` are held; `beat`, `ack`, `intro` are never held. (The spec drops `beat` at the catch-up; dropping it when it would be held gives the same result with less work.)
- Catch-up: drop entries older than 4 hours, newest entry per session and kind, sort `need` < `alert` < `done`, then oldest first; intro "While you were on the mic:" when the oldest kept entry is 30 s old or more; at most 4 entries, then "And N more."
- Mic free means two checks in a row, 2 s apart, report free.
- Helper exit codes: `0` an app is capturing, `1` free, `2` the device is running but the Mac cannot say which app (before macOS 14.2). Only `0` holds lines.
- Setting: `EARSHOT_HOLD_ON_MIC`, default `on`; `off` disables holding.
- Test-only knobs (not documented in the README): `EARSHOT_MIC`, `EARSHOT_POLL_SECS`, `EARSHOT_HOLD_MAX_SECS`.
- User-facing prose (README, comments): plain words, no em dashes.
- Work on a branch, not `main`.

## Review Focus

1. **An always-on listener that is not on the ignore list.** If Voice Control (or a similar listener) counts as "an app using the mic", every line is held until the 4 hour cap and Earshot goes silent. Expected: the helper ignores it. Pinned by the manual Voice Control check in Task 1 and the `--list` flag that shows what the helper sees.
2. **Text with shell or separator characters.** A finished line with quotes, `$`, `&`, `%`, a backslash, or a stray `\037` must come back word for word (minus the `\037`). Pinned by a round-trip test in Task 3.
3. **A prompt answered during the call.** Expected: its "needs your OK" is not read afterwards, and other sessions' held lines stay. Pinned in Task 4.
4. **Two watchers or two catch-ups at once.** Expected: each held line is spoken exactly once. Pinned by a concurrent-release test in Task 3.
5. **A mic that never frees up** (a stuck call app, a missed listener). Expected: the watcher gives up after the cap and empties the queue, so it does not run forever. Pinned in Task 3 with `EARSHOT_HOLD_MAX_SECS=1`.

Known limit, not tested: a prompt answered with Esc during a call fires no hook, so its held "needs your OK" is still read at the catch-up. The next hook from that session drops it if it fires first.

---

### Task 1: Per-app mic helper

**Files:**
- Modify: `scripts/mic-in-use.swift` (whole file)
- Modify: `scripts/speak.sh:30-32` (helper path, rebuild on update)
- Modify: `scripts/setup.sh:171` and `scripts/setup.sh:256-258` (messages)

**Interfaces:**
- Produces: `~/.config/earshot/mic-in-use` exits `0` (an app is capturing), `1` (free), `2` (device busy, app unknown). `mic-in-use --list` prints one line per capturing process: `<bundle ID or (no bundle ID)> counts|ignored`, exit code as above.
- Produces: in `speak.sh`, `MIC` (path, overridable by `EARSHOT_MIC`) and `mic_state` (runs the helper, returns its exit code; returns `1` when there is no helper).

- [ ] **Step 1: Create a branch**

```bash
git checkout -b call-aware-speaking
```

- [ ] **Step 2: Find the Voice Control bundle ID**

Ask the user to turn on Voice Control for a moment (System Settings > Accessibility > Voice Control). Do not change the setting yourself. While it is on, build and run the probe from the spec work:

```bash
cat > /tmp/micwho.swift <<'EOF'
import CoreAudio
var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
var size = UInt32(0)
AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size)
var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids)
for id in ids {
  var a = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyIsRunningInput, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
  var on = UInt32(0); var s = UInt32(4)
  AudioObjectGetPropertyData(id, &a, 0, nil, &s, &on)
  a.mSelector = kAudioProcessPropertyBundleID
  var cf: Unmanaged<CFString>? = nil; s = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
  AudioObjectGetPropertyData(id, &a, 0, nil, &s, &cf)
  if on != 0 { print((cf?.takeRetainedValue() as String?) ?? "(no bundle ID)") }
}
EOF
swiftc -O /tmp/micwho.swift -o /tmp/micwho && /tmp/micwho
```

Expected: one or more bundle IDs. Note the one that belongs to Voice Control (it is not a call app the user opened). If the user declines, use the prefixes in Step 3 as they are and say so in the final report.

- [ ] **Step 3: Rewrite the helper**

Replace `scripts/mic-in-use.swift` with the code below. If Step 2 found a Voice Control bundle ID that none of the prefixes match, add it to `ignored`.

```swift
// Is an app capturing from the microphone? Earshot holds its lines while one
// is, for example during a call or while you dictate with /voice.
// Exit 0: an app is capturing. Exit 1: none is.
// Exit 2: the input device is running, but this Mac (before macOS 14.2)
// cannot say which app uses it.
// Always-on listeners (Siri, Voice Control) do not count: they keep the mic
// open all day. --list prints each app that is capturing and whether it counts.
import CoreAudio
import Foundation

let ignored = ["com.apple.corespeechd", "com.apple.SpeechRecognitionCore", "com.apple.speech."]
let list = CommandLine.arguments.contains("--list")
let system = AudioObjectID(kAudioObjectSystemObject)

func get<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ value: inout T) -> Bool {
  var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                        mElement: kAudioObjectPropertyElementMain)
  var size = UInt32(MemoryLayout<T>.size)
  return AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr
}

if #available(macOS 14.2, *) {
  var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                        mScope: kAudioObjectPropertyScopeGlobal,
                                        mElement: kAudioObjectPropertyElementMain)
  var size = UInt32(0)
  if AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr {
    var procs = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &procs) == noErr else { exit(1) }
    var busy = false
    for p in procs {
      var input = UInt32(0)
      guard get(p, kAudioProcessPropertyIsRunningInput, &input), input != 0 else { continue }
      var cf: Unmanaged<CFString>? = nil
      let id = get(p, kAudioProcessPropertyBundleID, &cf) ? ((cf?.takeRetainedValue() as String?) ?? "") : ""
      let skip = ignored.contains { id.hasPrefix($0) }
      if list { print(id.isEmpty ? "(no bundle ID)" : id, skip ? "ignored" : "counts") }
      if !skip { busy = true; if !list { break } }
    }
    exit(busy ? 0 : 1)
  }
}

// Before macOS 14.2: only the device state is known.
var dev = AudioDeviceID(0)
guard get(system, kAudioHardwarePropertyDefaultInputDevice, &dev) else { exit(1) }
var running = UInt32(0)
guard get(dev, kAudioDevicePropertyDeviceIsRunningSomewhere, &running) else { exit(1) }
exit(running != 0 ? 2 : 1)
```

- [ ] **Step 4: Build and check the helper**

```bash
swiftc -O scripts/mic-in-use.swift -o /tmp/mic-in-use && /tmp/mic-in-use; echo "exit $?"; /tmp/mic-in-use --list; echo "exit $?"
```

Expected with nothing recording: `exit 1` twice, and `--list` prints nothing (or only `ignored` lines). Then ask the user to hold Space in a `/voice` session (or open Voice Memos and record) while you run `/tmp/mic-in-use --list; echo "exit $?"`. Expected: a `counts` line and `exit 0`. Time it: `/usr/bin/time -p /tmp/mic-in-use` should report `real` under 0.2.

- [ ] **Step 5: Point speak.sh at the helper and rebuild it on update**

In `scripts/speak.sh`, replace lines 30-32:

```bash
MIC=~/.config/earshot/mic-in-use

mic_on() { [ -x "$MIC" ] && "$MIC"; }
```

with:

```bash
MIC=${EARSHOT_MIC:-$HOME/.config/earshot/mic-in-use}   # tests point this at a stub
HOLD=${EARSHOT_HOLD_ON_MIC:-on}   # on: hold lines while an app uses the mic

# mic_state: the helper's answer. 0 an app is capturing (a call, or you
# dictating), 1 free, 2 the device runs but the app is unknown (macOS before 14.2).
mic_state() { [ -x "$MIC" ] || return 1; "$MIC"; }
mic_busy() { mic_state; [ $? != 1 ]; }
```

Then, directly above the line `input=$(cat)` (line 157 today), add:

```bash
# Setup built the mic helper once, but updates bring a new mic-in-use.swift.
# Rebuild it in the background when the source is newer. The old helper keeps
# working until then. A failed build touches the helper, so the next hook
# does not try again.
SRC=${0%/*}/mic-in-use.swift
if [ -z "$EARSHOT_MIC" ] && [ -x "$MIC" ] && [ "$SRC" -nt "$MIC" ]; then
  ( lockf -t 0 "$STATE/build.lock" sh -c 'swiftc -O "$1" -o "$2.new" && mv "$2.new" "$2" || touch "$2"' _ "$SRC" "$MIC" ) \
    </dev/null >/dev/null 2>&1 &
fi
```

`mic_on` is still used by `play()`. Replace both uses in `play()` now, so nothing calls `mic_on`:

```bash
  mic_busy && mic_was_on=1
```

and

```bash
    [ -z "$mic_was_on" ] && mic_busy && { kill $pid; touch "$STATE/hushed"; }
```

(Task 2 rewrites `play()`; this keeps the file working between tasks.)

- [ ] **Step 6: Update the setup messages**

In `scripts/setup.sh`, change the status line (line 171) to:

```bash
  [ -x "$DIR/mic-in-use" ] && say_ok "Microphone check: built" || say_ok "Microphone check: not built (Earshot won't stop when you talk or wait while you're on a call)"
```

and the build messages (lines 256-258) to:

```bash
  swiftc -O "$SCRIPTS/mic-in-use.swift" -o "$DIR/mic-in-use" 2>/dev/null \
    && echo "Built the microphone check, so Earshot stops talking when you start and waits while you're on a call." \
    || echo "Couldn't build the microphone check. Earshot still works but won't stop when you talk."
```

- [ ] **Step 7: Check the rebuild by hand**

```bash
cp ~/.config/earshot/mic-in-use /tmp/mic-in-use.bak
touch scripts/mic-in-use.swift
jq -nc --arg c "$PWD" '{session_id: "rebuild-check", cwd: $c}' | bash scripts/speak.sh tool
sleep 20; ls -l ~/.config/earshot/mic-in-use scripts/mic-in-use.swift; ~/.config/earshot/mic-in-use --list; echo "exit $?"
```

Expected: the helper's time is now newer than the source, and `--list` works (the old helper ignores the flag and prints nothing, so run it while recording if unsure). This needs `/voice` on, because `speak.sh` exits early without it. Remove the test session afterwards: `jq -nc '{session_id: "rebuild-check"}' | bash scripts/speak.sh end`.

- [ ] **Step 8: Run the existing tests**

```bash
bash tests/stuck-and-levels.sh
```

Expected: all pass, `0 failed`.

- [ ] **Step 9: Commit**

```bash
git add scripts/mic-in-use.swift scripts/speak.sh scripts/setup.sh
git commit -m "Mic check sees which app uses the mic

The helper now ignores always-on listeners such as Siri and Voice Control,
and --list shows what it sees. speak.sh rebuilds the helper in the
background when an update brings a newer source."
```

---

### Task 2: Hold lines while the mic is busy

**Files:**
- Modify: `scripts/speak.sh` (`tell`, `say`, `play`, dispatch lines, every `tell` call site)
- Test: `tests/stuck-and-levels.sh`

**Interfaces:**
- Consumes: `MIC`, `HOLD`, `mic_state`, `mic_busy` from Task 1.
- Produces:
  - `tell <kind> "<line>"` with kinds `need | alert | done | beat | ack`.
  - `say "<line>" [kind] [session]`: background, returns at once (synchronous when `EARSHOT_DRYRUN` is set).
  - `speak "<line>" <kind> <session>`: synchronous worker: hold, or download and play under the speaker lock.
  - `hold <kind> "<line>" <session>`: appends to `$HELD` under `$HELD.lock` and starts the watcher. Never holds `beat`, `ack`, `intro`.
  - `HELD=$STATE/held`.
  - `play <file> <asked> <kind> <line> <session>`.

- [ ] **Step 1: Give every test a fake mic**

In `tests/stuck-and-levels.sh`, after the line `printf 'EARSHOT_KEY=sk_test\nEARSHOT_VOICE=test\n' > "$EARSHOT_CONF"`, add:

```bash
# A fake mic helper, so a real call on this Mac cannot change the results.
# mic 0 = an app is capturing, mic 1 = free, mic 2 = busy but the app is unknown.
MICST=$(mktemp); echo 1 > "$MICST"
export EARSHOT_MIC=$(mktemp) EARSHOT_POLL_SECS=0.1
printf '#!/bin/bash\nexit $(cat "%s")\n' "$MICST" > "$EARSHOT_MIC"; chmod +x "$EARSHOT_MIC"
mic() { echo "$1" > "$MICST"; }
HELD=$EARSHOT_STATE_DIR/held
held_count() { grep -c -- "$1" "$HELD" 2>/dev/null || true; }
```

Add `"$MICST" "$EARSHOT_MIC"` to the final `rm -f` line:

```bash
rm -f "$OUT" "$EARSHOT_CONF" "$MICST" "$EARSHOT_MIC"
```

- [ ] **Step 2: Write the failing tests**

Add this section before the cleanup lines (`rm -rf "$T" "$EARSHOT_STATE_DIR"`) at the end of `tests/stuck-and-levels.sh`:

```bash
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
```

- [ ] **Step 3: Run the tests to see them fail**

```bash
bash tests/stuck-and-levels.sh
```

Expected: the new "mic busy" checks FAIL (lines are spoken, nothing is held). Older checks pass.

- [ ] **Step 4: Replace `tell`, `say` and `play`**

In `scripts/speak.sh`, replace everything from the comment `# tell <tier> "<line>": speak only if EARSHOT_LEVEL includes the tier.` through the line `[ "$1" = play ] && { play "$2" "$3"; exit 0; }` with:

```bash
# tell <kind> "<line>": speak only if EARSHOT_LEVEL includes the kind.
#   need   waiting on you: a permission prompt, a question, reminders   every level
#   alert  might be stuck, something broke                              every level
#   done   the finished line                                            every level
#   beat   "still on it" progress updates                               normal, all
#   ack    "On it" when your prompt arrives                             all
tell() {
  case "$1:$LEVEL" in
    need:*|alert:*|done:*|beat:normal|beat:all|ack:all) say "$2" "$1" "$sid" ;;
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
  case "$1" in need|alert|done) ;; *) return ;; esac
  printf '%s\037%s\037%s\037%s\n' "$(date +%s)" "$3" "$1" "$(printf '%s' "$2" | tr -d '\037\n')" \
    | lockf -k "$HELD.lock" sh -c 'cat >> "$1"' _ "$HELD"
  # One watcher at a time: a second one gives up at once.
  [ -n "$EARSHOT_DRYRUN" ] || ( lockf -t 0 -k "$STATE/release.lock" bash "$0" release ) </dev/null >/dev/null 2>&1 &
}

# speak "<line>" <kind> <session>: holds the line while an app uses the mic,
# or plays it. It returns when the line has played.
speak() {
  local asked out dl body code ok
  if [ "$HOLD" = on ] && mic_state; then hold "$2" "$1" "$3"; return; fi
  # Tests set EARSHOT_DRYRUN to a file: lines go there instead of the speaker.
  [ -n "$EARSHOT_DRYRUN" ] && { echo "$1" >> "$EARSHOT_DRYRUN"; return; }
  asked=$(date +%s)
  out="$CACHE/$(printf '%s' "$MODEL $VOICE $1" | md5 -q).mp3"
  if [ ! -s "$out" ]; then
    # The key goes in through stdin and the text through a file, so neither
    # shows up in the process list. A unique download file keeps two
    # sessions from writing the same file.
    dl=$(mktemp "$CACHE/dl.XXXXXX") && body=$(mktemp "$STATE/body.XXXXXX") || return
    jq -n --arg t "$1" --arg m "$MODEL" '{text: $t, model_id: $m}' > "$body"
    code=$(printf 'xi-api-key: %s\n' "$KEY" | curl -s --connect-timeout 5 --max-time 20 -w '%{http_code}' -o "$dl" \
      "https://api.elevenlabs.io/v1/text-to-speech/$VOICE" \
      -H @- -H 'Content-Type: application/json' --data-binary @"$body")
    ok=$?
    rm -f "$body"
    # A dropped connection can still report 200, so curl must succeed too.
    if [ "$ok" != 0 ] || [ "$code" != 200 ]; then
      echo "$(date '+%F %T') HTTP $code curl $ok: $(head -c 300 "$dl" 2>/dev/null)" >> "$LOG"
      rm -f "$dl"
      out=/System/Library/Sounds/Basso.aiff   # the error tone waits its turn too
    else
      mv "$dl" "$out"
    fi
  fi
  # All sessions share one speaker, so lines take turns: a line waits for
  # the one playing to finish, and is dropped after a minute in the queue.
  # -k keeps the lock file, so a new line cannot lock a fresh copy of it.
  lockf -s -k -t 60 "$STATE/speaker.lock" bash "$0" play "$out" "$asked" "$2" "$1" "$3"
}

# play <file> <asked> <kind> <line> <session>: plays one line while it holds the speaker.
play() {
  # You talked over an earlier line, so the lines queued behind it are dropped too.
  [ "$(stat -f %m "$STATE/hushed" 2>/dev/null || echo 0)" -ge "$2" ] && return
  # A call started while this line waited for the speaker: keep it for later.
  # Its audio is cached, so the catch-up does not download it again.
  if [ "$HOLD" = on ] && mic_state; then hold "$3" "$4" "$5"; return; fi
  # Stop when you start talking. A mic that was already on (an app the helper
  # cannot name, or holding is off) does not count.
  mic_busy && mic_was_on=1
  afplay "$1" & pid=$!
  while kill -0 $pid 2>/dev/null; do
    sleep 0.5
    [ -z "$mic_was_on" ] && mic_busy && { kill $pid; touch "$STATE/hushed"; }
  done
}

[ "$1" = say ] && { say "$2"; exit 0; }
[ "$1" = play ] && { play "$2" "$3" "$4" "$5" "$6"; exit 0; }
```

- [ ] **Step 5: Give each `tell` its kind**

In `scripts/speak.sh`:

1. In the `remind` block, add `sid=$2` as the first line inside `if [ "$1" = remind ]; then`, so held reminders know their session. Change both `tell alert` calls in that block to `tell need`.
2. `warn_once`: keep `tell alert`.
3. `notify`: change both `tell alert "Hey, $who needs your OK ...` calls to `tell need`.
4. `idle`: change `tell alert "Hey, $who is still waiting on your answer."` to `tell need`.
5. `stop`: change `[ -n "$line" ] && tell alert "$line"` to `[ -n "$line" ] && tell done "$line"`.
6. `fail`: keep `tell alert`.
7. `progress` (`tell beat`) and `start` (`tell ack`) stay as they are.

Check that no other tier names are left:

```bash
grep -n 'tell [a-z]*' scripts/speak.sh | grep -vE 'tell (need|alert|done|beat|ack) '
```

Expected: no output.

- [ ] **Step 6: Run the tests**

```bash
bash tests/stuck-and-levels.sh
```

Expected: all pass, including the "Holding lines" section. The EARSHOT_LEVEL section still passes because `need` and `done` speak at every level like `alert` did.

- [ ] **Step 7: Commit**

```bash
git add scripts/speak.sh tests/stuck-and-levels.sh
git commit -m "Hold urgent lines while an app uses the mic

Lines that need you, alerts and finished lines wait in a queue while
another app captures audio. Progress updates are dropped. Holding happens
before the download, so a held line costs nothing until it plays."
```

---

### Task 3: The catch-up after the call

**Files:**
- Modify: `scripts/speak.sh` (add `HOLD_MAX`, `POLL`, `catch_up`, `release` mode)
- Test: `tests/stuck-and-levels.sh`

**Interfaces:**
- Consumes: `speak`, `hold`, `HELD`, `mic_state` from Tasks 1-2.
- Produces: `bash speak.sh release`: the watcher. `catch_up`: takes the queue and speaks it.

- [ ] **Step 1: Write the failing tests**

Add after the "Holding lines" section in `tests/stuck-and-levels.sh`:

```bash
echo "Catch-up after the call"
held_add() { printf '%s\037%s\037%s\037%s\n' "$1" "$2" "$3" "$4" >> "$HELD"; }
held_now() { held_add "$(date +%s)" "$@"; }   # held just now: no intro
release() { bash "$S" release </dev/null; }
order_check() { # order_check <name> <expected lines joined by |>
  local got; got=$(tr '\n' '|' < "$OUT")
  if [ "$got" = "$2" ]; then pass=$((pass + 1)); echo "  ok    $1"; else fail=$((fail + 1)); echo "  FAIL  $1 (heard: $got)"; fi
  : > "$OUT"
}
rm -f "$HELD"; mic 1
held_now a done "Done A."; held_now b alert "Stuck B."; held_now c need "Need C."
release
order_check "needs you first, then alerts, then finished lines" "Need C.|Stuck B.|Done A.|"
held_now d need "Waiting 2."; held_now d need "Waiting 5."; held_now d need "Waiting 10."
release
order_check "three reminders for one prompt become the newest one" "Waiting 10.|"
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
```

- [ ] **Step 2: Run the tests to see them fail**

```bash
bash tests/stuck-and-levels.sh
```

Expected: the "Catch-up" checks FAIL. `release` is not a mode yet, so `speak.sh` reads stdin as hook input, fails the session ID check and exits silently.

- [ ] **Step 3: Add the watcher and the catch-up**

In `scripts/speak.sh`, directly after the line `[ "$1" = play ] && { play "$2" "$3" "$4" "$5" "$6"; exit 0; }`, add:

```bash
# --- After the call: the catch-up -------------------------------------------------
POLL=${EARSHOT_POLL_SECS:-2}            # seconds between mic checks
HOLD_MAX=${EARSHOT_HOLD_MAX_SECS:-14400}   # held lines older than 4 hours are dropped

# catch_up: says the held lines. The newest line per session and kind;
# lines that need you first, then alerts, then finished lines, oldest first.
catch_up() {
  local batch now lines total n=0 t s kind text
  batch=$(mktemp "$STATE/batch.XXXXXX") || return
  # Taking the whole queue under the lock means a line is spoken once, even
  # when two catch-ups run at the same time.
  lockf -k "$HELD.lock" mv "$HELD" "$batch" 2>/dev/null || { rm -f "$batch"; return; }
  now=$(date +%s)
  lines=$(awk -F'\037' -v min=$((now - HOLD_MAX)) '$1 >= min { last[$2 FS $3] = $0 }
      END { for (k in last) { split(last[k], f, FS); print (f[3] == "need" ? 0 : f[3] == "alert" ? 1 : 2), f[1], last[k] } }' "$batch" \
    | sort -k1,1n -k2,2n | cut -d' ' -f3-)
  rm -f "$batch"
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
    [ $(( $(date +%s) - began )) -ge "$HOLD_MAX" ] && { rm -f "$HELD"; break; }
    sleep "$POLL"
  done
  exit 0
fi
```

Each line in the catch-up goes through `speak`, so it waits its turn on the speaker, and a call that starts again holds it again (it goes back into `$HELD`, which keeps the loop running).

- [ ] **Step 4: Run the tests**

```bash
bash tests/stuck-and-levels.sh
```

Expected: all pass, `0 failed`.

- [ ] **Step 5: Check the real thing by hand**

With `/voice` on and a real key in `~/.config/earshot/config`:

```bash
bash scripts/speak.sh say "Before the recording."
```

Then start a Voice Memos recording (or any call), and in another terminal:

```bash
jq -nc --arg c "$PWD" '{session_id: "manual-1", cwd: $c, last_assistant_message: "Done.\n🗣 This line waited for you."}' | bash scripts/speak.sh stop
```

Expected: silence while recording. Stop the recording. About 3 to 5 seconds later you hear the line. Wait more than 30 seconds before stopping to hear "While you were on the mic:" first. Clean up: `jq -nc '{session_id: "manual-1"}' | bash scripts/speak.sh end`.

- [ ] **Step 6: Commit**

```bash
git add scripts/speak.sh tests/stuck-and-levels.sh
git commit -m "Say what you missed once the mic is free

A watcher checks the mic every 2 seconds while lines are held. When the
mic is free twice in a row, it says the newest line per session, the ones
that need you first, with at most 4 lines and a short intro after a long
hold. A mic that stays busy for 4 hours drops the queue."
```

---

### Task 4: Forget held prompts you already answered

**Files:**
- Modify: `scripts/speak.sh` (`clear_wait`)
- Test: `tests/stuck-and-levels.sh`

**Interfaces:**
- Consumes: `HELD`, `$HELD.lock`, `sid` (set by the hook input parse).
- Produces: `drop_held`: removes this session's `need` entries from `$HELD`.

- [ ] **Step 1: Write the failing tests**

Add after the "Catch-up" section in `tests/stuck-and-levels.sh`:

```bash
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
```

- [ ] **Step 2: Run the tests to see them fail**

```bash
bash tests/stuck-and-levels.sh
```

Expected: "a tool call drops that session's need line" and "a new prompt drops that session's need line" FAIL.

- [ ] **Step 3: Drop held need lines when you answer**

In `scripts/speak.sh`, replace the `clear_wait` function:

```bash
# clear_wait: you answered, so stop the reminder timer and forget the prompt.
clear_wait() {
  local wf pid; wf=$(wait_file "$sid")
  [ -f "$wf" ] || return 0
```

with:

```bash
# drop_held: you answered, so this session's held "needs you" lines are stale.
drop_held() {
  lockf -k "$HELD.lock" sh -c 'awk -F "$3" -v s="$2" "!(\$2 == s && \$3 == \"need\")" "$1" > "$1.t" && mv "$1.t" "$1"' \
    _ "$HELD" "$sid" $'\037' 2>/dev/null
}

# clear_wait: you answered, so stop the reminder timer and forget the prompt.
clear_wait() {
  local wf pid; wf=$(wait_file "$sid")
  [ -s "$HELD" ] && drop_held
  [ -f "$wf" ] || return 0
```

The rest of `clear_wait` stays as it is. `start`, `tool`, `toolfail`, `stop` and `fail` all call `clear_wait`, so each of them drops the session's held `need` lines. The `[ -s "$HELD" ]` check keeps tool hooks fast when nothing is held.

- [ ] **Step 4: Run the tests**

```bash
bash tests/stuck-and-levels.sh
```

Expected: all pass, `0 failed`.

- [ ] **Step 5: Commit**

```bash
git add scripts/speak.sh tests/stuck-and-levels.sh
git commit -m "Skip held prompts that you answered during the call"
```

---

### Task 5: Docs and release

**Files:**
- Modify: `README.md`
- Modify: `.claude-plugin/plugin.json` (version)
- Modify: `docs/superpowers/specs/2026-10-09-call-aware-speaking-design.md` (status)

- [ ] **Step 1: README, "What you hear"**

Add this row to the table under `## What you hear`, after the "Claude finishes" row:

```markdown
| You were on a call, or another app used the mic | Nothing until the mic is free. Then the lines you missed, most urgent first: "While you were on the mic: Hey, billing service needs your OK to run the database migration." |
```

After the paragraph that starts "Earshot only speaks while `/voice` is on.", add:

```markdown
Earshot also waits while another app uses the microphone, for example during a
Zoom, Meet, or FaceTime call, or while you dictate with `/voice`. When the mic
is free, you hear what you missed: lines that need you first, then stuck
warnings and failures, then finished lines. Progress updates are skipped, and a
prompt that you answered during the call is not read. After a short wait, such
as while you dictate, the line plays as usual.
```

- [ ] **Step 2: README, Requirements, Settings, Troubleshooting, Limits, FAQ**

Requirements, replace the `swiftc` bullet with:

```markdown
- Optional: `swiftc`. To install it, run `xcode-select --install`. Without `swiftc`, Earshot does not stop talking when you start to talk, and it does not wait while you are on a call.
```

Settings table, add after the `EARSHOT_REMIND_MINS` row:

```markdown
| `EARSHOT_HOLD_ON_MIC` | `on` | `on` waits while another app uses the microphone and catches you up after. `off` speaks right away. |
```

Troubleshooting table, add:

```markdown
| Earshot is silent, and lines come much later | Another app may be using the microphone. Run `~/.config/earshot/mic-in-use --list` to see which app. An app marked `counts` makes Earshot wait. |
```

Limits, add:

```markdown
- Earshot cannot tell a call from other apps that use the microphone, such as a voice recorder. It waits for any of them. Siri and Voice Control do not count.
- A line held for more than 4 hours is dropped.
- Per-app microphone checks need macOS 14.2 or later. On older versions, Earshot does not wait during calls.
```

FAQ, add after "How is it different from a notification sound?":

```markdown
**Does it talk during my calls?**
No. While another app uses the microphone, Earshot waits. When the call ends,
you hear what you missed, with the lines that need you first.
```

- [ ] **Step 3: Version and spec status**

In `.claude-plugin/plugin.json`, change `"version": "0.6.2"` to `"version": "0.7.0"`.

In the spec, change `Status: draft, waiting for review` to `Status: implemented in 0.7.0`.

- [ ] **Step 4: Run the tests one last time**

```bash
bash tests/stuck-and-levels.sh
```

Expected: all pass, `0 failed`.

- [ ] **Step 5: Commit**

```bash
git add README.md .claude-plugin/plugin.json docs/superpowers/specs/2026-10-09-call-aware-speaking-design.md docs/superpowers/plans/2026-10-09-call-aware-speaking.md
git commit -m "Release 0.7.0: Earshot waits while you're on a call"
```
