# Earshot for Mac: design

Date: 2026-10-11. Status: draft for review.

## Goal

A companion menu bar app for the Earshot plugin. You say "Hey Earshot, tell
billing service to run the tests", the right Claude Code session gets that
prompt, and Earshot says that it did. This works for terminal, background and
desktop app sessions. The app also takes over playback from the plugin: the
speech queue, holding lines during calls, lowering other audio, and the voices.

This is sub-project D (orchestrator) from the roadmap, plus the app shell it
needs. The spike in `2026-10-10-session-injection-spike.md` proved that an outside
process can send a prompt into any running session.

## Decisions made while brainstorming

- One spec for three parts: the app shell with the playback takeover, voice in,
  and the orchestrator. The plan builds them in that order.
- Four commands: send to a session, ask for status, stop a session, start a new
  session.
- Two triggers: the wake word "Hey Earshot" and a hold-to-talk hotkey. The wake
  word can be switched off.
- Earshot acts right away and then says what it did. It asks back only when the
  target is unclear.
- Everything runs on the Mac: FluidAudio for the wake word and transcription,
  Apple's on-device Foundation Model for understanding, and a fixed grammar as
  the fast path and fallback. Requires macOS 26 or later.
- Public release with the plugin: Developer ID signed, notarized, Sparkle
  updates. The user has an Apple Developer account.
- Other apps' audio is lowered with a Core Audio process tap while Earshot
  speaks or listens. Never during calls, because Earshot is silent then.
- Session names are said in their shortest unique form (see "Spoken names").

## Out of scope

- Approving permission prompts by voice. A socket message arrives as a peer
  message, and Claude Code will not accept a peer message as approval. That is
  the right behavior.
- Moving the plugin's "what to say" logic (stuck detection, levels, reminders,
  the finished line) into the app. It stays in `speak.sh`.
- Mac App Store distribution. The sandbox blocks `/tmp/cc-socks` and running
  `claude`.
- VS Code sessions. Untested. They may work, but they are not a goal.
- Languages other than English.

## 1. Architecture

The plugin stays the sensor layer. Hooks are the only way to learn what a
session is doing, and the decision logic in `speak.sh` (about 600 lines, with
tests) stays where it is. The app owns how and when a line is heard, and
everything about listening.

```
Claude Code sessions --hooks--> speak.sh --say/status/prompt--> Earshot.app
        ^                          |                              |
        |                          +-- no answer in 200 ms:       |
        |                              plays the line itself      |
        +---- /tmp/cc-socks/<pid>.sock <-- Dispatcher <-----------+
```

### Parts of the app

All non-UI parts live in a Swift package, `EarshotKit`, and are tested without
the app. Each part has one job and a small interface.

| Part | Job | Depends on |
|---|---|---|
| EventServer | Accepts `say`, `status` and `prompt` messages from the plugin | nothing |
| SpeechOut | Queue, priorities, hold during calls, catch-up, barge-in, engines | MicMonitor, Ducker, engines |
| Engines | Kokoro (in process), ElevenLabs, `say` | FluidAudio, Keychain |
| Ducker | Lowers other apps' audio while Earshot speaks or listens | Core Audio taps |
| MicMonitor | Knows when another app uses the mic; ignores Earshot itself | Core Audio |
| Listener | Wake word or hotkey, then records and transcribes one command | FluidAudio, MicMonitor |
| CommandParser | Turns a transcript into a typed `Command` | Foundation Models, grammar |
| SessionDirectory | Live sessions, their state, spoken names, fuzzy matching | `claude agents --json`, plugin status |
| Dispatcher | Carries out a `Command` and returns the line to say | SessionDirectory, sockets, `claude` |
| Names | Shortest unique spoken name for each session | SessionDirectory, Foundation Models |

The app target (`Earshot`) holds only the menu bar, settings, onboarding and
Sparkle.

### What changes in the plugin

- Where `speak.sh` plays a line today, it first offers the line to the app. If
  the app accepts, the plugin does nothing more. If the socket is missing, or
  there is no answer within 200 ms, the plugin plays the line as it does now.
  Each line plays exactly once.
- `speak.sh` sends `status` when a session's state changes and `prompt` when a
  prompt arrives.
- The ElevenLabs key moves to Keychain. `speak.sh` reads it with `security
  find-generic-password`, so the fallback keeps working.
- `/earshot:setup` offers the app download. `/earshot:rollcall` keeps working
  without the app.
- Spoken names get shorter (see "Spoken names"). This change helps plugin-only
  users too.

## 2. Latency, resources and power

### Listening is a cascade

Only the cheapest stage runs all the time.

| Stage | Runs when | Cost |
|---|---|---|
| 0. Mic closed | Wake word off, no live sessions, screen locked, Mac asleep, another app uses the mic, or Low Power Mode (default rule) | none |
| 1. Energy gate | Always, while listening is allowed | close to none |
| 2. Voice activity detection (FluidAudio VAD) | When the energy gate opens | small |
| 3. Wake word spotter | On speech segments only | medium, measured first |
| 4. Transcription (Parakeet, streaming) | After the wake word or hotkey, until end of speech | high, brief |

Audio is held in a ring buffer of about 10 seconds in memory. It is never
written to disk and never leaves the Mac.

### Latency budget

Target: under 1 second from the end of speech to the start of the spoken
confirmation.

- A short chime plays as soon as the wake word or hotkey fires.
- End of speech: about 600 ms of silence after the wake word, tuned during
  testing. With the hotkey, releasing the key ends the command at once.
- Transcription streams while you talk, so the final text is ready in under
  100 ms.
- The fixed grammar runs first (under 5 ms). The Foundation Model runs only when
  the grammar does not match. Its session is prewarmed when the wake word fires.
- The session list is refreshed in the background when the wake word fires
  (`claude agents --json` takes about 130 ms), so it is fresh by the end of the
  command.
- The socket write takes under 5 ms. Kokoro is loaded and starts in 80 to 300 ms.

### Memory

- Always loaded while listening is allowed: the VAD and the wake word spotter.
- Loaded on first use and unloaded after 10 idle minutes: transcription and
  Kokoro. A cold first command loses no audio, because the ring buffer keeps the
  whole command while the model loads.
- On a memory pressure warning, every idle model is unloaded.

### Power

- Nothing polls while idle. The sockets use dispatch sources, session state is
  pushed by the plugin, and MicMonitor uses Core Audio property listeners.
- The audio output engine stops between lines, so the audio hardware can sleep.
- App Nap is disabled only while listening or speaking.
- Wake word on battery: always, only on power, or off in Low Power Mode
  (default).

### Budgets

- Idle with the wake word off: about 0% CPU, under 50 MB of memory.
- Wake word on, quiet room: "Low" Energy Impact in Activity Monitor, and a
  number recorded with `powermetrics` in the plan's first step.
- Hotkey commands: p50 under 1 s and p95 under 1.5 s from key release to the
  start of the spoken confirmation, over 20 commands.
- Every command logs signposts: wake, end of speech, transcript, command, sent,
  speech start.

The biggest unknown is the wake word spotter's power use. FluidAudio's spotter
uses a speech recognition (CTC) model, which may be heavier than a dedicated
wake word model. The plan measures it first. If it is over budget, the fallback
is a small dedicated wake word model on the Neural Engine.

## 3. Commands and data flow

### Plugin to app protocol

The app listens on `~/Library/Application Support/Earshot/earshot.sock`, mode
0600. Each message is one JSON line. The app answers each one with one line.

```
{"v":1,"type":"say","text":"...","kind":"alert|progress|finished|stuck|fail|roll|ack","session":"<id>","name":"billing service","urgent":true}
{"v":1,"type":"status","session":"<id>","state":"working|needs|reply|stuck|failed|done|open","detail":"...","project":"billing service","title":"..."}
{"v":1,"type":"prompt","session":"<id>"}
-> {"ok":true}  or  {"ok":false,"reason":"version"}
```

The plugin waits at most 200 ms for the answer. Any other outcome means the
plugin handles the line itself.

### Finding the target session

SessionDirectory merges `claude agents --json` (pid, session id, kind, busy,
idle or waiting) with the plugin's `status` messages (state, detail, project,
title).

Matching, in order: project name, session label, full title, then a fuzzy match
on the spoken words. Live session names are also passed to the transcriber as
boosted vocabulary, so "finebrief" is not heard as "fine brief".

- Two sessions match: "Billing service has two: refund rounding and invoices.
  Which one?" Earshot then listens for 6 seconds without the wake word.
- No target is named ("run the tests"): the only live session; else the session
  Earshot last spoke about, if that was within 2 minutes; else Earshot asks.

### The four commands

**Send.** Earshot writes `{"type":"user","from":"earshot","session_id":...,
"priority":"next","message":{...}}` to the session's socket. It says "Sent to
billing service." If the session is busy, it says "Queued, billing service is
busy." If the session waits on a permission prompt, it says "Queued. Billing
service is still waiting on your OK." If an idle session sends no `prompt`
receipt within 5 seconds, it says "Billing service didn't pick it up."

**Status.** "What's everyone doing?" plays the roll call, the sessions that need
you first. "What's billing doing?" says that session's state and latest step.

**Stop.** Not verified yet. The plan's first step checks whether a
`priority: "now"` message interrupts a busy turn. If it does, Earshot sends
"Stop what you're doing and wait for the user." If it does not, background
sessions are stopped with `claude stop <id>`, and for terminal and desktop
sessions Earshot says "I can't stop that session yet." Sending a signal to the
process is not allowed: a second Ctrl-C quits the session.

**Start.** Earshot finds the project folder among the folders Claude Code knows
(live sessions and recent projects), runs `claude --bg "<prompt>"` there, and
says "Started a session in blog." An untrusted folder fails to start, so Earshot
says "Blog isn't trusted yet. Open it in Claude once first."

### Barge-in and calls

- The wake word or hotkey stops the line that is playing.
- If another app starts using the mic while Earshot talks, the line stops and is
  held for the catch-up. Lines are held during calls, as in the plugin today.
- The wake word listener closes the mic while another app uses it. It cannot be
  triggered from a call, and nobody on the call hears Earshot.

### Lowering other audio

- While Earshot speaks, and while it listens after the wake word or hotkey, a
  Core Audio process tap covers every app except Earshot. Their audio fades to
  about 30% over 200 ms, then fades back after the line.
- The tap exists only during those moments. Audio is not recorded or saved.
- It needs the "Screen & System Audio Recording" permission. Onboarding
  explains why. If the permission is denied, nothing is lowered.

### Safety

- Earshot never sends approvals or settings changes, and every injected prompt
  is marked `from: "earshot"`.
- Both sockets are owned by the user with mode 0600.
- `session_id` is always set, so a reused pid cannot get a command meant for
  another session.

## 4. Spoken names

Today a second session in the same project is named with up to 6 words of its
title: "the orchestrator agent for multi session voice session in earshot". That
is too long to hear many times a day.

New rule: say the shortest name that is unique among live sessions.

1. If the project is the only live session in that folder: the project, e.g.
   "billing service".
2. Otherwise, if the session's label is unique across all live sessions: "the
   refund rounding session".
3. Otherwise: "refund rounding in billing service".

The label is 1 to 3 words:

- A custom title set with `/rename` of 3 words or fewer is used as is.
- In the app, the Foundation Model turns the title into a 1 to 3 word noun
  phrase ("Orchestrator agent for multi-session voice control" becomes "voice
  orchestrator"). It is cached by session id and title, and written to the
  plugin's live file as line 3, so the plugin uses it too.
- Without the app or the model, a rule in `speak.sh`: drop a leading verb (fix,
  add, create, make, update, build, write, check, debug, refactor, implement),
  drop "a", "an", "the", then keep words up to the first of "for", "with", "and",
  "to", "in", "on", "of", "vs", at most 3 words. "Create guest confirmation email
  with event details" becomes "guest confirmation email".

The same names are used in alerts, the roll call, and command confirmations.
Voice commands match the label, the full title, and the project, so you can say
either form.

## 5. When things go wrong

### Between the app and the plugin

- App not running, crashed or slow: the plugin plays the line itself.
- Protocol version not known: the app answers `{"ok":false}` and the plugin
  plays the line itself.
- Two copies of the app: a single-instance lock, as the Kokoro helper uses.
- The app is a login item. After a crash, the plugin covers until the next
  launch.

### Sending into sessions

- `claude` not on the app's PATH: check `~/.local/bin`, `/opt/homebrew/bin`
  and `/usr/local/bin`, then ask the login shell once at launch.
- The session closed between hearing and sending: "Billing service has closed."
- A Claude Code update changes the socket format: after two idle sessions in a
  row send no receipt, sending is marked broken for that Claude Code version,
  and Earshot says so once. Background sessions still work through `claude
  --resume <id> --bg "<prompt>"`, with no other flags, so it continues the same
  session.
- Unknown target: "I don't know a session called payments. Open ones are
  billing service, blog and earshot." It names at most 3.

### Hearing

- Wake word and then silence: after 8 seconds a closing chime, nothing else.
  False wakes are counted locally. Settings has a sensitivity slider.
- Not understood: the Foundation Model fails or is unavailable, so the grammar
  is used. If the grammar does not match: "Sorry, I didn't get that."
- Models not downloaded yet, or offline at first launch: wake word and hotkey are
  off, and the menu says why. Speaking still works.
- Mic permission denied: listening is off, speaking still works.
- Bluetooth headsets: opening a Bluetooth mic switches the headset to call
  quality for all audio. When the output device is Bluetooth, the wake word uses
  the built-in mic. The input device is a setting.
- Audio device changes: the audio engine is rebuilt on the configuration change
  notification.

### Speaking

- Engine fallback: ElevenLabs, then Kokoro, then `say`. Kokoro keeps its v3 to
  legacy retry.
- Ducking fails or permission is denied: the line plays without ducking.

### Diagnostics

- Unified log, subsystem `com.earshot.app`, including the per-command signposts.
- Menu item "Copy diagnostics": versions, permissions, model state, and the last
  50 events. No transcripts and no prompt text.

## 6. Packaging, setup and settings

### Repo layout

- `app/EarshotKit/`: Swift package with every part from section 1. Tested with
  `swift test`.
- `app/Earshot/`: Xcode app target for the menu bar, settings, onboarding and
  Sparkle.
- `tts/`: the Kokoro helper moves onto the Kokoro engine in `EarshotKit`, so
  the app and plugin-only users share one engine.
- The plugin stays where it is. The app and the plugin have separate version
  numbers and share protocol version 1.

### Distribution

- Developer ID signing, hardened runtime, notarization with `notarytool`, and
  the audio input entitlement. No sandbox.
- A DMG on GitHub Releases and a Homebrew cask.
- Sparkle 2 with an EdDSA-signed appcast on GitHub.

### Config

- The app reads and writes `~/.config/earshot/config`, so the plugin fallback
  always matches the app.
- On first launch, existing settings are imported. The ElevenLabs key moves to
  Keychain.

### First launch

1. One screen on what Earshot does.
2. Voice: keeps the current choice, or Kokoro for new users.
3. Mic permission, and wake word on or off.
4. Hotkey: hold Right Option by default. Fn is avoided because dictation uses it.
5. Model download with progress. Speaking works during the download.
6. Lowering other audio: optional, explains the permission.
7. Try it: "Say: Hey Earshot, what's everyone doing?"

### Menu bar

- Icon states: idle, listening, speaking, holding during a call, muted.
- Menu: live sessions with their state, "Mute for 1 hour", Settings, Quit.

### Settings

- General: launch at login, level, style.
- Voice: engine, voice, speed.
- Listening: wake word, battery rule, sensitivity, hotkey, input device.
- Audio: lower other audio on or off, and how much.
- Diagnostics.

## 7. Testing

### Unit tests (`swift test`, Swift Testing)

- CommandParser grammar: a table of about 60 phrasings mapped to the expected
  `Command`, including no target, two-word names, and filler words ("um", "can
  you").
- SessionDirectory matching: misheard names ("fine brief", "billing services"),
  two sessions in one project, the 2-minute "last spoke about" rule.
- Names: the shortest unique name in each of the three cases, and the label rule
  on a list of real titles.
- SpeechOut: priority order, hold and catch-up order, barge-in, exactly-once
  delivery.
- Dispatcher: against a fake session socket. Checks the JSON line, `session_id`,
  priority, receipt timeout, and the broken-format switch.
- EventServer: protocol encode and decode, unknown version, slow client.

### Plugin tests (bash, same style as `tests/stuck-and-levels.sh`)

- `speak.sh` sends to a fake app socket and stays silent when the app accepts.
- `speak.sh` plays the line itself when there is no socket, when the answer is
  late, and when the version is rejected.
- The label rule and the shortest unique name in `speak.sh`.

### Model and audio evals (local scripts, need the Mac's models)

- Foundation Model parser: about 100 transcripts. Pass at 95% or better on
  action and target.
- Listener: recorded WAV files (wake phrase in a quiet room, with music, with
  other people talking, silence, commands with session names). Measures wake
  word hits and false wakes, and how often session names come out right with
  and without vocabulary boosting.

### Integration

- A script that starts a background session and a terminal session (as in the
  spike), sends through the Dispatcher, and checks that each one receives and
  answers the prompt.
- Manual check for a desktop app session.

### Performance

- A `powermetrics` script for the idle and wake word budgets.
- Latency from signposts over 20 hotkey commands: p50 under 1 s, p95 under
  1.5 s.

### Manual checklist before each release

Zoom and Meet hold and catch-up, AirPods connected, ducking with Music, Spotify
and a browser video, sleep and wake, Low Power Mode, first launch on a clean
user account, and an upgrade from the plugin only.

## 8. Build order

The plan starts with the three items that could change the design:

1. Measure the wake word spotter's power use. If it is over budget, switch to a
   dedicated wake word model.
2. Check whether a `priority: "now"` message interrupts a busy session (decides
   how Stop works).
3. Prototype ducking with a process tap on Music, a browser and AirPods.

Then:

4. EarshotKit core: EventServer, SpeechOut, engines, MicMonitor, Ducker.
5. Plugin handoff: `say`, `status` and `prompt` messages, fallback, Keychain key,
   spoken names.
6. App shell: menu bar, settings, onboarding, signing, Sparkle. Release as the
   app's first version: playback and ducking, no listening yet.
7. Listener: wake word, hotkey, transcription with boosting.
8. CommandParser, SessionDirectory, Dispatcher: the four commands.
9. Evals, performance budgets, manual checklist. Release with listening.
