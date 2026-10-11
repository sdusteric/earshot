# Voice approvals (plugin side) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A `PermissionRequest` hook that lets Earshot for Mac answer a permission prompt with a spoken yes or no.

**Architecture:** `speak.sh decide` runs next to `speak.sh ask`. It offers the prompt to the app with an `approval` message over the existing socket (`app_send`), then polls an answer file the app writes, and stops when the prompt is answered some other way. Without the app it exits at once.

**Tech Stack:** bash 3.2, jq, zsh socket helper (`scripts/app-send.zsh`), BSD userland.

**Spec:** `docs/superpowers/specs/2026-10-11-voice-approvals-design.md`

## Global Constraints

- Branch `voice-approvals`, based on `mac-app` at 227e451. Do not edit `app/`.
- In `speak.sh`, touch only the new `decide` case, a `DECIDE_SECS` setting, and nothing in the naming code (the mac-app branch changes it next).
- Hook timeout 3600 s; `EARSHOT_DECIDE_SECS` default 3500.
- Poll every 0.5 s; `approved` (a `ps` scan) only every 4th round.
- Background `app_send` calls redirect stdin, stdout and stderr, so Claude Code never waits on them.
- Prose: no em dashes, plain words.

## Review Focus

1. The decision JSON must reach stdout exactly once and nothing else may be printed there (a stray line breaks the hook's JSON).
2. A voice deny must stop the reminder timer, or Earshot keeps saying "needs your OK" for a prompt that is gone.
3. The prompt answered on screen must end the hook within about 2 s, so the app stops listening.
4. No app (the normal case today) must cost nothing beyond the usual hook start.
5. Answer files for another prompt id, or with other content, must never approve.

---

### Task 1: The `decide` hook

**Files:**
- Create: `tests/voice-approvals.sh`
- Modify: `scripts/speak.sh` (settings block near `LONG_MAX`; new case after `ask)`)
- Modify: `hooks/hooks.json` (second command in `PermissionRequest`)

**Interfaces:**
- Consumes: `app_up`, `app_send`, `wait_file`, `still_waiting`, `approved`, `clear_wait`, `set_status`, `asks_for`, `$who`, `$warned`.
- Produces: `speak.sh decide` (hook mode); message types `approval` (open, closed); answer file `$STATE/answer-<sid>-<id>` containing `allow` or `deny`.

- [ ] **Step 1: Write the failing tests** in `tests/voice-approvals.sh`, in the style of `tests/app-handoff.sh` (fake app, `EARSHOT_DRYRUN`, `EARSHOT_APP_SOCK`), one check per line of the spec's Testing section. `decide` runs in the background with its stdout in a file; the test plays the app by writing the answer file named in the logged `approval` message.
- [ ] **Step 2: Run them, expect failures** (`bash tests/voice-approvals.sh`: unknown mode prints nothing, so the decision checks fail).
- [ ] **Step 3: Implement** the `decide` case as the spec's steps 1 to 6, plus `DECIDE_SECS=${EARSHOT_DECIDE_SECS:-3500}`, plus the hooks.json entry:

```json
"PermissionRequest": [{"hooks": [
  {"type": "command", "command": "bash ${CLAUDE_PLUGIN_ROOT}/scripts/speak.sh ask"},
  {"type": "command", "command": "bash ${CLAUDE_PLUGIN_ROOT}/scripts/speak.sh decide", "timeout": 3600}
]}]
```

- [ ] **Step 4: Run the new tests and the old suites** (`tests/stuck-and-levels.sh`, `tests/app-handoff.sh`, `tests/engines.sh`). All pass.
- [ ] **Step 5: Commit.**

### Task 2: Live check and docs

**Files:**
- Modify: `README.md` (How it works, Limits)

- [ ] **Step 1: Live check in a real session** (tmux, Haiku, manual mode) with a 30-line fake app (`tests/fake-app.zsh ok`) and the worktree's hooks loaded through `--settings`: a prompt shows, the test writes `allow`, the command runs; a second prompt answered on screen ends `decide` within 2 s; a third with `deny` gets Claude's "said no" path and no reminder 2 minutes later (use `EARSHOT_REMIND` short values if available).
- [ ] **Step 2: README.** One paragraph under "How it works" and one line under Limits.
- [ ] **Step 3: Commit.**
