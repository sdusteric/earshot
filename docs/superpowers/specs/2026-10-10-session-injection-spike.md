# Spike: sending a spoken command into a running session

Date: 2026-10-10. Claude Code 2.1.296 on macOS.

Question: can a process outside Claude Code put a prompt into a session that is
already running? This decides whether the orchestrator (sub-project D) and a
companion Mac app are worth building.

## Result

Yes, for every kind of session we tested.

| Target | Route | Result |
|---|---|---|
| Background session (`claude --bg`), idle | `claude --resume <id> --bg "prompt"` with no other flags | Works. With flags it starts a copy instead. Works even after `claude stop`. |
| Background session, idle | Messaging socket | Works |
| Interactive terminal session, idle at the prompt | Messaging socket | Works. The idle session wakes and answers. |
| Desktop app Code tab session | Messaging socket | Works. The message appears in the conversation. |
| Sender with no Claude process as parent (a plain shell) | Messaging socket | Works |

## The messaging socket

Each session binds a Unix socket at `/tmp/cc-socks/<pid>.sock` (mode 0600, owned
by the user). The session exports the path as `CLAUDE_CODE_MESSAGING_SOCKET` and
a token as `CLAUDE_CODE_MESSAGING_TOKEN`, to its own hooks and Bash. This is the
transport behind the documented cross-session messaging feature
(https://code.claude.com/docs/en/cross-session-messaging). The wire format is not
documented. We found it in the binary's own help text and parser.

Newline-delimited JSON. An optional auth line comes first:

```
{"type":"auth","token":"<CLAUDE_CODE_MESSAGING_TOKEN>"}
{"type":"user","from":"earshot","session_id":"<uuid>","priority":"next","message":{"role":"user","content":"run the tests"}}
```

- On macOS, auth is optional. Every test passed without the auth line.
- `session_id` is optional. When it is present and does not match, the session
  drops the message. Use it so that a reused pid never gets the wrong command.
- `priority` is `now`, `next` (default) or `later`.
- `from` is a free-form label.
- Other frames: `{"type":"control","action":"rename","name":...}`, and
  `notify_when_idle`, which may help roll call.

`claude agents --json` lists every live session, interactive and desktop ones
included, with `pid`, `sessionId`, `name`, `cwd`, `kind`, and `status`
(`busy`, `idle`, `waiting`, plus `waitingFor`). With the socket path pattern,
that is everything needed to address a session by its name.

Spike sender: a pid lookup through `claude agents --json`, then `jq` and `socat`.
About ten lines.

## Limits

- **The message counts as a peer, not as you.** The session sees "Another Claude
  session sent a message" and treats it as a teammate's request. It acts on
  ordinary work ("run the tests", "summarize what you did"). By design it will
  not treat a peer message as approval for a pending permission prompt, and it
  will not change its own settings. So "yes, approve it" by voice cannot go
  through this route. Spoken approvals need another way, for example an allow
  rule or the user pressing the key.
- **The format is undocumented.** The cross-session feature is documented, but
  the raw socket format could change in any release. A version check and a
  fallback (`--resume --bg` for background sessions) are needed.
- **Hooks see injected prompts.** `UserPromptSubmit` fires for them, so Earshot
  would say "On it" at level `all`. That is probably fine, but the orchestrator
  should know about it.
- **Not tested:** a busy session getting `priority: "now"`, a session waiting on
  a permission prompt, and VS Code sessions.

## What this means for the Mac app

The blocker is gone. A menu bar app can:
1. hear the wake word,
2. turn speech into a command and a target session ("in billing service, run the
   tests"),
3. find the session with `claude agents --json`,
4. write one JSON line to its socket.

The plugin still provides the events, and `agents --json` already covers much of
roll call.

## Follow-up probe: does `priority: "now"` interrupt? (2026-10-11)

No. A background session running `ping -c 40 127.0.0.1` got a `now` message
asking it to stop. The command ran to the end (about 40 seconds). The message
was delivered at the next step boundary, and Claude obeyed it: it replied
"STOPPED" and skipped its planned final reply. So `now` means "before anything
else, after the current tool call", not an interrupt.

Consequence for Stop: send a `now` message and say "Billing service will stop
after its current step." For background sessions, `claude stop <id>` stops at
once and the session can be resumed.
