# Voice approvals: design

Date: 2026-10-11. Status: plugin side built on branch `voice-approvals`; the
app side waits for the Listener in Earshot for Mac.

## Goal

When Earshot says "Hey, billing service needs your OK to run the migration",
you say "yes" (or "no") and the prompt is answered. You don't switch windows.
It works in terminal sessions and in the desktop app.

This adds to `2026-10-11-mac-app-design.md`, which lists "approving
permission prompts by voice" as out of scope because a socket message is a peer
message. That stays true. Approvals take a different route: a
`PermissionRequest` hook, which Claude Code lets decide a prompt.

Roll call by voice is already the Status command in the Mac app design, so
nothing is added for it here.

## Decisions made with the user

- Earshot listens after it asks ("billing service needs your OK..."), for about
  6 seconds, and also takes answers after the hotkey.
- The listener is the Earshot for Mac menu bar app (the Listener part). The
  plugin has no mic.
- A clear "yes" approves at once, with a short sound. There is no read-back.
  When two prompts wait, a bare "yes" gets "Which one, billing or docs?"

## What the spike showed (Claude Code 2.1.296, 2026-10-10 and 11)

| Question | Terminal | Desktop app |
|---|---|---|
| Does the dialog show while a `PermissionRequest` hook waits? | Yes, at once | Yes, at once |
| Does the hook's `allow` close the dialog and run the tool? | Yes ("Allowed by PermissionRequest hook") | Yes, the dialog closed by itself |
| Click first: what happens to the hook? | It keeps running until it exits; its late answer is ignored | Not tested, same code |
| Does Earshot's "needs your OK" line still play while the hook waits? | Yes | Not tested |

Also tested and rejected for sending commands: an `asyncRewake` hook that waits
for a file and exits 2. It works in the terminal, but the desktop app runs it
at session start as a normal hook (the session hangs until it ends), and Opus in
the desktop app refuses the woken message because it is marked as not coming
from the user. The Mac app's messaging socket route is the right one for
commands.

## How it works

```
prompt shows --PermissionRequest--> speak.sh ask     (wait file, reminders: as today)
                                --> speak.sh decide  (new, waits up to an hour)
                                       | approval ->  Earshot.app  {"ok":true}?
                                       |   no: exit at once, nothing changes
                                       | yes: poll every 0.5 s for
                                       |   - answer-<session>-<id> (from the app): allow or deny
                                       |   - the prompt resolved some other way
~6 s later: notify --> "needs your OK ..." --> app plays it, then listens 6 s
you: "yes" --> app writes answer file --> decide prints allow --> dialog closes
```

### The `decide` hook (plugin)

A second command in the `PermissionRequest` entry of `hooks/hooks.json`, with
`"timeout": 3600`. It runs next to `ask`.

1. AskUserQuestion: exit. A question is not an approval.
2. The app is not up (`app_up` fails): exit before anything else runs, so a
   prompt costs nothing extra without the app.
3. Wait up to 3 seconds for `ask` (they start together). `ask` writes
   `prompt-<session>`: a hash of the tool name and input, and the time. Only
   when that matches this prompt is the wait file's token read. A wait file an
   earlier Esc left behind is never mistaken for this prompt's. No match: exit.
4. Make a random 128-bit secret and send `approval` to the app. If the app does
   not answer `{"ok":true}` within 0.2 s, exit; if it was reached at all (a
   late or negative answer), send `closed` with `by: "unclaimed"` first.
   Today's app answers `{"ok":false}` to unknown types, so until the Listener
   ships nothing changes.
5. Every 0.5 s, check in this order:
   - `answer-<session>-<id>` exists: read it, delete it. It counts only as a
     plain file you own that group and others cannot write, holding `allow`
     or `deny`, a space, and the secret. Then the hook prints the decision and
     exits. Anything else is ignored. Before
     it exits it clears the wait (stops the reminders, drops held "needs you"
     lines) and sets the status to `working`, because after a deny no tool
     runs and nothing else would.
   - The prompt is gone: the wait file is missing or has a new token (you
     clicked and the tool ran, or a newer prompt replaced it), or
     `still_waiting` says the transcript moved on (Esc or a click on No).
   - Every 4th round (2 s): `approved` says the Bash command is running (you
     clicked Yes on a long command).
   - The deadline (`EARSHOT_DECIDE_SECS`, default 3500 s) has passed.
6. On every exit after step 4, send `approval` with `state: "closed"` and
   `by` (`voice`, `screen`, `timeout` or `unclaimed`), so the app stops
   listening for it. Esc or No on the dialog makes Claude Code stop the hook
   (SIGTERM, found in the live test), so a trap, set before the first message,
   sends `closed` with `by: "screen"` in the foreground before the hook exits.

The decision printed:

```json
{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}
{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"The user said no by voice."}}}
```

A deny rule in settings still wins over an `allow` from a hook (Claude Code
rule). Earshot never adds allow rules ("always allow" stays a click).

### Messages (protocol version 1, added types)

Plugin to app:

```
{"v":1,"type":"approval","session":"<id>","id":"<prompt id>","name":"billing service","what":"to run the migration","answer":"<path>","secret":"<32 hex>","pid":12345}
{"v":1,"type":"approval","session":"<id>","id":"<prompt id>","state":"closed","by":"voice|screen|timeout|unclaimed"}
```

- `id` is unique per prompt (time, PID and a random number).
- `answer` is the file the app writes: `$STATE/answer-<session>-<id>`. The app
  writes `allow <secret>` or `deny <secret>` with mode 0600 to a temporary file
  in the same folder and renames it, so the plugin never reads half a file.
- `secret` is only ever in this socket message (the socket is 0600 in the
  app's own folder), never in a file name, so listing the state folder is not
  enough to approve a prompt.
- `app-send.zsh` adds `sent` (epoch ms) to every message. An `approval` the
  app reads late may be refused like a late `say` line (the hook then sends
  `closed unclaimed`), but a `closed` message must always be applied, however
  late: dropping it would leave the app listening for a prompt that is gone.
- `pid` is the waiting hook. If `closed` never arrives (the hook was killed
  with SIGKILL), the app can check it with `kill(pid, 0)` before it listens.
- The app answers `{"ok":true}` to the first message only when it can listen
  now: mic permission granted, listening not switched off. Otherwise
  `{"ok":false}` and the plugin stops waiting.

### The app side (for the Listener part of Earshot for Mac)

- **After the line.** When the app finishes playing a `need` line for a session
  with an open approval, it plays the listening chime and listens for 6 seconds
  without the wake word. Not during a call: the line is held then, and when the
  catch-up plays it, the same rule applies if the approval is still open.
- **After the hotkey.** "Yes billing", "approve billing", "no to billing" answer
  that session's approval.
- **Words.** Allow: yes, yeah, yep, allow, approve, go ahead, do it, sure, OK.
  Deny: no, nope, deny, don't, stop, cancel. Anything else, or silence: the
  prompt stays as it is, nothing is said.
- **Which prompt.** After the line: the approval the line was about. After the
  hotkey with no name: the only open approval; with two or more, "Which one,
  billing or docs?" and 6 more seconds for a name.
- **Confirming.** A short sound at once, then "Approved." or "Told it no."
  Only when the answer file was written while the approval was still open.
- **A late answer.** If `closed` arrived first, say nothing and write nothing.

### Safety

- Only a clear allow word approves. Silence, noise, or a sentence with other
  content does nothing.
- The listening window opens only right after Earshot asked, or after the
  hotkey. The wake word is not needed for approvals but does not approve on
  its own.
- The answer file lives in Earshot's state folder (`DARWIN_USER_TEMP_DIR`,
  readable only by you) and must carry the prompt's secret, which only the app
  gets. A program running as you would have to talk to the app's socket to
  learn it.
- Voice cannot approve a prompt Earshot did not announce, unless you name the
  session after the hotkey.

## Limits

- Parallel subagents in one session share one wait file (existing limit). A
  second prompt replaces the first, so the first one's `decide` stops and that
  prompt needs a click.
- The hook keeps a small bash process alive per open prompt, polling every
  0.5 s.
- If the prompt waits more than about an hour, voice answers stop for it.

## Testing (plugin side, `tests/voice-approvals.sh`)

With the fake app from `tests/fake-app.pl` and `EARSHOT_DRYRUN`:

- No app: `decide` exits in under 1 s, prints nothing, sends nothing.
- App rejects: exits at once, prints nothing.
- App takes it: the approval message has session, id, name, what, answer path.
- Answer `allow`: prints the allow decision; `deny`: the deny decision with its
  message; both send `closed` with `by: voice`.
- After a voice answer the wait file is gone, the reminder timer is stopped,
  and the status is `working`.
- Garbage in the answer file is ignored and removed; a later `allow` works.
- Answer file for another id, without the secret, with a wrong secret, as a
  symlink, or writable by others: ignored.
- A wait file left by an earlier Esc: decide still waits for this prompt.
- An app that answers after 0.2 s: decide ends and sends `closed unclaimed`.
- SIGTERM (Esc): `closed` with `by: screen`, nothing printed.
- Wait file removed (tool ran) or replaced (new token): exits silently,
  `closed` with `by: screen`.
- Transcript moved on (Esc): exits silently.
- The Bash command is running (approved on screen): exits silently.
- Deadline: exits silently, `closed` with `by: timeout`.
- AskUserQuestion: no approval message.
- `ask` and `decide` together keep today's lines: the "needs your OK" line is
  still said once.
