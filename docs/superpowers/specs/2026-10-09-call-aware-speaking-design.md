# Call-aware speaking: design

Date: 2026-10-09
Status: implemented in 0.7.0

## Why

Research on ChatGPT Voice and other voice tools for coding agents found the
same complaint again and again: the voice talks over people. Users say it cut
into calls and into conversations in the room. No tool we found mutes itself
while you are on a call.

Earshot has this problem today. `play()` treats a mic that was already on as
"does not count", so that a Voice Control wake word does not mute Earshot
forever. The side effect is that during a Zoom or Meet call, Earshot reads
every line to you while you talk to other people.

## What the user gets

While any app uses the microphone, Earshot stays silent. When the mic has been
free for a few seconds, Earshot says what you missed, most urgent first:

> While you were on the mic: Hey, billing service needs your OK to run the
> database migration. Heads up, invoice api keeps hitting the same error. It
> might be stuck. billing service: Fixed the rounding bug.

A short hold, such as while you dictate with `/voice`, has no intro. The line
plays as soon as you stop talking.

## Decisions made with the user

- During a call, hold lines and give one catch-up after the call. No tone, no
  macOS notification.
- "On a call" means any app is capturing from the microphone, except
  always-on listeners (Siri, Voice Control). This includes Claude Code's own
  `/voice`, so a line that arrives while you dictate waits until you finish.
- Detection uses an on-demand watcher. There is no daemon and no launch agent.

## Detection: `scripts/mic-in-use.swift`

Today the helper asks one question: is the default input device running?
The new helper asks: is any app, other than an always-on listener, capturing
audio input?

- It reads `kAudioHardwarePropertyProcessObjectList`. For each process object
  it reads `kAudioProcessPropertyIsRunningInput` and
  `kAudioProcessPropertyBundleID`. A probe on macOS 27 ran in about 0.2 s and
  returned a bundle ID for most processes.
- Ignored bundle ID prefixes: `com.apple.corespeechd` (Siri) and the Voice
  Control recognizer. The exact Voice Control bundle ID is checked during
  implementation by turning Voice Control on and running the probe.
- Exit codes:
  - `0`: an app is capturing input. Earshot holds lines.
  - `1`: no app is capturing input.
  - `2`: the per-app list is not available (macOS before 14.2), and the
    device is running. Earshot cannot tell a call from a wake word, so it does
    not hold lines. It keeps today's behavior: it stops a line when the mic
    turns on during playback.

### Keeping the helper current

`setup.sh` builds the helper today, so users who update the plugin keep the
old binary. `speak.sh` rebuilds it when `mic-in-use.swift` is newer than the
binary. The rebuild runs in the background under a lock, so a hook never waits
on `swiftc`. Until the new binary exists, the old one keeps working.

## Holding lines

`tell` passes a kind to `say`, so a held line knows what it is:

| Kind | Lines | Kept in the catch-up |
|---|---|---|
| `need` | needs your OK, has a question, still waiting on you, waiting on your answer | yes, first |
| `alert` | might be stuck, something broke | yes, second |
| `done` | the finished line | yes, third |
| `beat` | still on it | no, stale after a call |
| `ack` | On it | no |

`say` checks the mic before it downloads audio. If the helper exits `0`, the
line goes into the held queue, and no ElevenLabs request is made. A line that is
dropped later costs nothing.

`play` checks again when the line gets the speaker, because a call can start
while a line waits in the queue. If the helper exits `0`, the line goes back
into the held queue instead of playing. Its audio is already cached, so the
catch-up does not download it again.

The held queue is one file, `$STATE/held`. Each entry is one line with these
fields, separated by `\x1f`: time, session ID, kind, text. Writes use the
same `lockf` pattern as the speaker.

### Lines that no longer matter

When you answer a prompt, `clear_wait` already stops its reminders. It now also
removes that session's held `need` lines. `start` (you sent a new prompt) does
the same. So a "needs your OK" for a prompt that you answered during the call
is not read afterwards.

## The catch-up: `speak.sh release`

The first held line starts a watcher, `bash speak.sh release`, in the
background. `lockf -t 0` on `$STATE/release.lock` keeps it to one watcher.

1. Every 2 seconds, run the helper.
2. When the mic has been free on two checks in a row (about 3 seconds),
   release the queue.
3. Move `held` to a private temporary file, so new lines start a new queue.
4. Drop `beat` and `ack` entries.
5. Keep only the newest entry for each session and kind. Three reminders
   for one prompt become the newest one.
6. Sort: `need`, then `alert`, then `done`. Within a kind, oldest first.
7. If the oldest entry waited 30 seconds or more, say "While you were on the
   mic:" first. It is a fixed phrase, so it plays from the cache.
8. Say at most 4 entries. If more are left, say "And N more." Each entry goes
   through `say` again, so a call that starts again holds them again.
9. Exit. A watcher that has waited 4 hours exits and empties the queue.

The 60 second speaker timeout still applies to each line, so a catch-up waits
for a line that is playing.

## Setting

| Setting | Default | What it controls |
|---|---|---|
| `EARSHOT_HOLD_ON_MIC` | `on` | `off` turns holding off and gives the old behavior |

## Unchanged

- If you talk while a line plays, the line stops and the lines queued behind
  it are dropped.
- Mute, levels, styles, and session names work as before.
- Without the helper (no `swiftc`), nothing is held.

## Testing

`tests/stuck-and-levels.sh` gets a new section. An `EARSHOT_MIC` variable
points `speak.sh` at a stub helper whose exit code the test controls.
`EARSHOT_DRYRUN` records lines after the hold decision, so held lines do not
show up until the release.

- Mic busy: a finished line is held, not spoken.
- Mic free: the same line is spoken right away.
- Release order: `need`, then `alert`, then `done`. `beat` is dropped.
- Three reminders for one session become one.
- A prompt answered during the hold is not read.
- A hold of 30 seconds or more gets the intro. A short hold does not.
- 6 entries give 4 lines and "And 2 more."
- Exit code `2` does not hold.
- `EARSHOT_HOLD_ON_MIC=off` does not hold.

A manual check on a real Mac: start a FaceTime or Meet call, trigger a
finished line in a test session, hang up, and hear the catch-up.

## Docs

- README: a "What you hear" row for the catch-up, a Settings row, a Limits
  note, and an FAQ answer: "Does it talk during my calls?"
- `plugin.json`: a version bump with the release.

## Out of scope

- A roll call ("what is everyone doing?") and the voice orchestrator. These are
  separate sub-projects, B and D.
- A local TTS engine. This is sub-project C.
- A user-editable ignore list. Add one only if the built-in list is not enough.
