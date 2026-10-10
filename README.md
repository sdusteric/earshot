# Earshot: voice notifications for Claude Code

Earshot is a Claude Code plugin that reads updates aloud with ElevenLabs
text-to-speech. Start a task, walk away, and hear when Claude needs your OK on a
permission prompt, gets stuck in a loop, or finishes, with a one-line summary of
what it did. It works in the terminal and in the Code tab of the Claude Mac app.

https://github.com/user-attachments/assets/f2c1f624-1941-436b-b3d9-a9229687f50c

You talk with Claude Code's built-in `/voice`. Earshot adds the other half: Claude
talks back with an ElevenLabs voice.

## What you hear

| When | Example |
|---|---|
| Every 3 minutes of work | "Still on billing service, about 6 minutes in. Latest step: run the invoice tests." |
| The same error comes back 3 times, even after edits | "Heads up, billing service keeps hitting the same error. It might be stuck." |
| The same step gives the same result 3 times in a row | "Heads up, billing service keeps running the same thing over and over. It might be stuck." |
| Two steps alternate 3 times | "Heads up, billing service keeps going back and forth between the same two steps. It might be stuck." |
| A permission prompt waits more than a few seconds | "Hey, billing service needs your OK to run the database migration." |
| You still haven't answered it | "Still waiting on you in billing service, 5 minutes now." (at 2, 5 and 10 minutes) |
| Claude asks you a question | "Hey, billing service has a question for you." |
| Claude ended on a question and you didn't reply | "Hey, billing service is still waiting on your answer." |
| The turn fails | "Something broke in billing service. Take a look when you can." |
| Claude finishes | One short line Claude writes for you, e.g. "Fixed the rounding bug, though the refund test is still flaky." |
| Your prompt arrives (level `all` only) | "On it." |

With several sessions open, you hear which one is talking. The finished line
starts with the project, like "billing service: Fixed the rounding bug." When two
sessions are open in the same project, Earshot adds the session's name, the one
you see in `/resume`: "Hey, billing service, refund rounding, needs your OK."

Earshot only speaks while `/voice` is on. It stops talking when you start, plays
repeated lines from a cache, and beeps if the voice fails. Reminders stop as soon
as you answer, including when you press Esc.

You choose how much Earshot says. `normal` is the default:

| Level | What you hear |
|---|---|
| `quiet` | Only when it needs you, might be stuck, something fails, or Claude finishes |
| `normal` | Quiet, plus a progress update every 3 minutes |
| `all` | Normal, plus "On it." when your prompt arrives |

Cost: about $8 a month with ElevenLabs v4 Turbo at roughly 100 spoken lines a day.

## Requirements

- A Mac.
- Claude Code in a terminal, or the Code tab of the Claude Mac app. Claude Code must be signed in with a Claude.ai account. `/voice` does not work with an API key, Bedrock, Vertex, or Foundry.
- An ElevenLabs API key with the Text to Speech permission. A free ElevenLabs account works with premade voices.
- `jq`. To install it, run `brew install jq`.
- Optional: `swiftc`. To install it, run `xcode-select --install`. Without `swiftc`, Earshot does not stop talking when you start to talk.

## Install

1. In Claude Code, run these two commands:

   ```
   /plugin marketplace add sdusteric/earshot
   /plugin install earshot@earshot
   ```

2. Run `/earshot:setup`. Claude asks you to choose a voice.
3. Copy your ElevenLabs API key to the clipboard. Tell Claude when you copied it. The setup script reads the key from the clipboard, so the key does not go into the chat.
4. Listen for the test line. When you hear it, the setup is complete.
5. Claude asks if Earshot can update itself. Answer yes to get new versions automatically.
6. Claude asks how much Earshot should say. Choose `quiet`, `normal`, or `all`.
7. Run `/voice`. Hold Space to talk.

### Install with a terminal

You can also do the setup in a terminal. The script asks for the key and shows a numbered list of voices.

1. Do step 1 of [Install](#install).
2. In a terminal, run:

   ```
   bash ~/.claude/plugins/marketplaces/earshot/scripts/setup.sh
   ```

To see all options, run the same command with `--help`.

## Change the voice

Use one of these methods:

- In Claude Code, run `/earshot:setup`. Choose a different voice.
- In a terminal, run `bash ~/.claude/plugins/marketplaces/earshot/scripts/setup.sh`. Type the number of a voice, or paste a voice ID.
- Run the same script with a voice ID: `bash ~/.claude/plugins/marketplaces/earshot/scripts/setup.sh --voice VOICE_ID`.

Each method plays a test line in the new voice. If the voice does not work, the script shows the reason and keeps your old voice.

To find a voice ID:

1. Open [elevenlabs.io](https://elevenlabs.io) and go to **Voices**.
2. Select a voice.
3. Copy its voice ID.

Premade voices work on all ElevenLabs plans. A voice from the Voice Library can need a paid plan. The setup script tells you when your plan cannot use a voice.

## Use

| Action | How |
|---|---|
| Turn voice on or off | Run `/voice`. |
| Talk | Hold Space. Talk. Release Space. |
| Send the prompt when you release Space | Set `"voice": { "autoSubmit": true }` in `~/.claude/settings.json`. `/earshot:setup` can set it for you. |
| Mute Earshot | Run `touch ~/.config/earshot/mute`. |
| Unmute Earshot | Run `rm ~/.config/earshot/mute`. |
| Change the voice or the key | Run `/earshot:setup`. See [Change the voice](#change-the-voice). |
| Change how much Earshot says | Run `bash ~/.claude/plugins/marketplaces/earshot/scripts/setup.sh --level quiet`. Use `quiet`, `normal`, or `all`. |
| Show the current setup | Run `bash ~/.claude/plugins/marketplaces/earshot/scripts/setup.sh --status`. |

## Update

If you turned on auto-update during setup, you do not need to do anything. Claude Code installs new versions a few minutes after a session starts, then shows `Plugin updated: earshot`.

To turn on auto-update later, run `bash ~/.claude/plugins/marketplaces/earshot/scripts/setup.sh --auto-update`. You can also use `/plugin`, then **Marketplaces**, then **earshot**, then **Enable auto-update**.

To update by hand:

1. In a terminal, run these two commands:

   ```
   claude plugin marketplace update earshot
   claude plugin update earshot@earshot
   ```

2. Start a new Claude Code session.

Your key and voice stay the same.

## Uninstall

1. In a terminal, run `claude plugin uninstall earshot@earshot`.
2. To remove your key and voice, run `rm -rf ~/.config/earshot`.

## How it works

The plugin adds hooks for these events: `SessionStart`, `SessionEnd`, `UserPromptSubmit`, `PreToolUse` (for
`AskUserQuestion` only), `PermissionRequest`, `PostToolUse`, `PostToolUseFailure`,
`Stop`, `StopFailure`, and `Notification` (for `permission_prompt` and
`idle_prompt`). Each hook runs `scripts/speak.sh` and returns in about 50 ms. The
speech runs in the background, so Earshot does not slow down Claude.

Earshot looks for three signs that Claude is stuck. It uses the same patterns as
the stuck detector in OpenHands:

- The same error comes back 3 times in one task, even if Claude edits code between the attempts. Earshot removes noise from the error before it compares, such as times, durations, process IDs, and line numbers. It keeps counts such as "3 failed", because a changed count means progress.
- The same step gives the same result 3 times in a row.
- Two steps alternate 3 times.

One slow command is never "stuck", because nothing repeats. Earshot ignores commands that wait on purpose, such as `sleep`, `watch`, and `gh run watch`. You hear at most one stuck warning for each task.

When a permission prompt or a question shows, Earshot starts a timer. The timer
speaks the reminders. Each reminder first checks that the prompt still waits. If
you answered, the timer stops.

Earshot keeps a list of open sessions in `/tmp/earshot-live`. A session that
closes, or that is quiet for 6 hours, leaves the list. When another session is
open, the finished line starts with the project name. When another session is
open in the same project, Earshot also says the session's name. It reads the
name from the session transcript: a `/rename` name first, then the name that
Claude Code made. A new session can have no name for its first minute.

When `/voice` is on, the prompt hook tells Claude to end each reply with one line
that starts with 🗣. When Claude stops, the `Stop` hook reads that line aloud.
Earshot does not change your `CLAUDE.md` or your `settings.json`.

Earshot keeps your key and voice in `~/.config/earshot/config`. Only your user
account can read this file. If you also set `ELEVENLABS_API_KEY` for other tools,
Earshot uses the key in its config file, not the environment variable.

## Settings

To change a setting, add a line to `~/.config/earshot/config`, for example
`EARSHOT_BEAT_SECS=300`.

| Setting | Default | What it controls |
|---|---|---|
| `EARSHOT_LEVEL` | `normal` | How much Earshot says: `quiet`, `normal`, or `all` |
| `EARSHOT_SESSION_NAME` | `auto` | When to say the session's name: `auto` (only when two sessions share a project), `always`, or `never`. `never` also removes the project name from the finished line. |
| `EARSHOT_MODEL` | `eleven_v4_turbo` | The ElevenLabs model that makes the speech |
| `EARSHOT_BEAT_SECS` | `180` | The number of seconds between "still on it" updates |
| `EARSHOT_LOOP_REPEATS` | `3` | The number of repeats that causes a "might be stuck" warning |
| `EARSHOT_REMIND_MINS` | `"2 5 10"` | The minutes after a prompt when Earshot reminds you that it still waits. Use quotes. |

## Troubleshooting

| Problem | What to do |
|---|---|
| You hear no voice and no beep | Run `setup.sh --status`. Make sure that `/voice` is on. Make sure that the file `~/.config/earshot/mute` does not exist. |
| You hear a beep but no voice | Read `/tmp/earshot.log`. Error 401 means that the key is not correct. Error 404 means that the voice ID is not correct. |
| The script says that your plan cannot use the voice | Choose a premade voice, or upgrade your ElevenLabs plan. ElevenLabs sells separate plans for ElevenCreative, ElevenAgents, and ElevenAPI. Make sure that your plan includes API access to Text to Speech. |
| Claude Code shows `Unknown command: /voice` | Run `/login` and sign in with a Claude.ai account. Remove `ANTHROPIC_API_KEY` from your environment. |
| `/voice` does not record | Open System Settings > Privacy & Security > Microphone. Turn on access for your terminal app. |

## Limits

- Hooks cannot tell if you typed or talked. When `/voice` is on, Earshot also speaks for prompts that you type.
- Earshot gives "still on it" updates only after a tool call ends. During one long command, Earshot is silent.
- If you ask Claude to run the same failing command several times on purpose, Earshot can say that Claude might be stuck.
- All Claude Code sessions use the same speaker. A new line stops the line that plays.
- If the owner of a Voice Library voice removes it, that voice stops working. Premade voices do not have this risk.

## FAQ

**How do I get notified when Claude Code needs permission?**
Install Earshot and turn on `/voice`. When a permission prompt waits, you hear
what Claude wants to do, like "billing service needs your OK to run the database
migration," and a reminder at 2, 5 and 10 minutes if you don't answer.

**Does it work in the Claude Mac app?**
Yes, in the Code tab. The Mac app shares your Claude Code settings and plugins.
Turn on `/voice` once in a terminal, and Earshot talks in both places. Sessions
that were open before you installed or updated Earshot need a restart.

**Can I tell which session is talking when I run several?**
Yes. With several sessions open, the summary starts with the project name. Two
sessions in the same project also get the session's name.

**Does it work on Linux or Windows?**
Not yet. Earshot plays audio with `afplay`, which only macOS has.

**Does it need an ElevenLabs subscription?**
No. A free ElevenLabs account works with premade voices. Some Voice Library
voices need a paid plan.

**How is it different from a notification sound?**
A sound tells you something happened. Earshot tells you what: which project,
what it wants to run, whether it looks stuck, and what it got done.

## License

MIT
