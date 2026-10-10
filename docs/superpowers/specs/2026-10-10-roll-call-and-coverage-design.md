# Roll call, MCP input dialogs, long commands, and catch-up polish: design

Date: 2026-10-10
Status: implemented in 0.8.0

## Why

After 0.7.0 we listed the gaps that remain. The user asked for these:

1. The Voice Control check (done: it found a bug).
2. MCP input dialogs: Claude waits, but Earshot says nothing.
3. Background agents finishing (see "Dropped" below).
4. Progress during one long command.
5. Three catch-up fixes from the reviews.
6. Roll call: "what is everyone doing?", sessions that need you first. The
   orchestrator (sub-project D) needs it later.

## Decisions made with the user

- Roll call has two triggers: a script you bind to a key in the Shortcuts app
  (instant, no Claude turn) and a `/earshot:rollcall` command.
- Roll call says everything, sessions that need you first.
- Background finishes: normal and all levels only. See "Dropped".

## 1. Voice Control

With Voice Control on, `mic-in-use --list` printed:

```
com.apple.inputmethod.ironwood counts
com.apple.SpeechRecognitionCore.speechrecognitiond ignored
```

`ironwood` is the macOS dictation input method, so with Voice Control on,
0.7.0 holds every line. The ignore list gets `com.apple.inputmethod.ironwood`.
Trade-off: macOS system dictation (Fn Fn) does not pause Earshot either.
Claude Code's `/voice` still does. The README Limits section says so.

## 2. MCP input dialogs

Claude Code has hook events for this:

- `Elicitation` (fires before the dialog, input has `mcp_server_name`). Earshot
  records a wait file of kind `input` with the server name and starts the
  reminder timer, the same as `PermissionRequest`. It prints nothing, so the
  dialog still opens.
- `Notification` with matcher `elicitation_dialog|elicitation_url_dialog`
  (fires after about 6 seconds without typing). Earshot says: "Hey, billing
  service needs your input for linear." The server name is cleaned the same
  way as MCP tool names in permission prompts.
- `ElicitationResult` (you answered): clears the wait file and the reminders.
- Reminders at 2, 5 and 10 minutes use the existing wording.
- During a call the line is held as `need` and skipped if you answered.

## 3. Dropped: background agents finishing

When a background agent or background command finishes, Claude Code starts a
new turn in that session, and that turn ends with a finished line, which
Earshot already speaks. A separate "background agent finished" line would say
the same thing twice. `SubagentStop` also fires for every foreground subagent,
which would be noise. Nothing to build.

## 4. Progress during one long command

Today "still on it" updates come only after a tool call ends, so one 10 minute
test run is silent.

- A new `PreToolUse` hook for `Bash` (skipped when `run_in_background` is
  true) writes `$STATE/running-$sid`: the `tool_use_id`, the spoken name, and
  the command's description. It starts a background timer.
- The timer sleeps until the next update is due (the last update time in the
  turn file plus `EARSHOT_BEAT_SECS`). If the same command still runs, it says
  the usual update: "Still on billing service, about 6 minutes in. Latest
  step: run the invoice tests." It records the update time and loops.
- `PostToolUse` and `PostToolUseFailure` remove the file and stop the timer,
  the same way an answer stops reminders.
- Level: `beat` (normal and all), the same as other progress updates.

## 5. Catch-up fixes

- **The useful line wins.** For `need` lines, the catch-up keeps the oldest
  line per session ("needs your OK to run the migration"), not the newest
  reminder ("It's been 10 minutes"). Other kinds keep the newest.
- **No orphaned lines.** The watcher is started with `lockf -t 5` instead of
  `-t 0`, so a hold that lands while the old watcher exits still gets a
  watcher. The 4 hour cap removes the queue under `held.lock`.
- **A log.** `earshot.log` gets one line when a line is held, when held lines
  are dropped at the cap, and when an answered prompt is skipped.

## 6. Roll call

### Status per session

A new file `$STATE/status-$sid` has 4 lines: state, since (epoch), the
spoken name (`$who`), detail. Hooks keep it current:

| Event | State | Detail |
|---|---|---|
| Prompt arrives (`start`) | `working` | |
| Permission prompt, question, MCP input | `needs` | "needs your OK to run X", "has a question for you", "needs your input for X" |
| A tool call after that (you answered) | `working` | |
| Stuck warning | `stuck` | |
| Turn ends on a question (`idle`) | `reply` | |
| Turn fails | `failed` | |
| Turn ends (`stop`) | `done` | the finished line, at most 15 words |
| Session ends | file removed | |

`tool` hooks only rewrite the file when the state is `needs`, so ordinary
tool calls stay fast. `stuck` stays until the turn ends.

### What it says

`speak.sh rollcall` reads the open sessions (the existing live list) and their
status files, and builds one line:

> Three sessions. Billing service needs your OK to run the migration. Invoice
> api might be stuck. The tax export session in billing service is working,
> 12 minutes in. Docs finished: fixed the broken links.

- Order: `needs` and `reply`, then `stuck` and `failed`, then `working`, then
  `done`. Oldest first within a group.
- At most 6 sessions, then "And N more."
- No sessions: "No Claude sessions are open."
- Counts one to nine are words; more are digits.
- It is one ElevenLabs request. It is never held: you asked for it, maybe
  with headphones on during a call.
- It plays even when muted or when `/voice` is off, because you asked for it.

### Triggers

- **Hotkey.** README steps: in the Shortcuts app, make a shortcut with
  "Run Shell Script" running
  `bash ~/.claude/plugins/marketplaces/earshot/scripts/speak.sh rollcall`,
  then give it a keyboard shortcut. Shortcuts runs scripts with a short
  `PATH`, so `speak.sh` adds `/opt/homebrew/bin` and `/usr/local/bin` for `jq`.
- **Command.** `skills/rollcall/SKILL.md` with `disable-model-invocation:
  true`. Its body runs `speak.sh rollcall --print` through the skill's
  inline shell feature, which speaks the roll call and prints the text, and
  asks Claude to show it. The `start` hook sees a prompt that starts with
  `/earshot:rollcall` and skips the "end with 🗣" instruction, so the roll
  call is not spoken twice.

## Testing

`tests/stuck-and-levels.sh`, with the fake mic and `EARSHOT_DRYRUN`:

- Ignore list: covered by the manual Voice Control run above.
- MCP input: `Elicitation` then `Notification elicitation_dialog` says "needs
  your input for linear"; `ElicitationResult` stops the reminder timer.
- Long command: with `EARSHOT_BEAT_SECS=1`, a `PreToolUse` Bash with no
  `PostToolUse` gives an update within 3 s; after `PostToolUse` no more
  updates come; `run_in_background` gives none; level `quiet` gives none.
- Catch-up: three `need` lines for one session give the oldest; a hold logs
  a line; the cap empties the queue under the lock.
- Roll call: four sessions in four states come out in the right order with
  the right count; no sessions gives "No Claude sessions are open"; seven
  sessions give 6 and "And 1 more"; a mic that is busy does not hold it;
  `--print` prints the line; `start` with `/earshot:rollcall` prints no 🗣
  instruction.

A manual check: bind the hotkey and press it with two sessions open.

## Docs and release

README: "What you hear" rows for MCP input, long commands and roll call; a
"Roll call" section with the Shortcuts steps; Limits updated (system
dictation, long command beats). Version 0.8.0 with a GitHub release.

## Out of scope

- Speaking roll call by voice command (needs the wake word, sub-project D).
- `claude agents --json` as a status source: Earshot's own hooks already see
  every session, including the desktop app's.
