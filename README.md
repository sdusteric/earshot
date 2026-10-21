# Kobi: voice notifications for Claude Code

Kobi is a Claude Code plugin that reads updates aloud. By default it uses
Kokoro, a voice model that runs on your Mac, so it is free and your lines never
leave the Mac. ElevenLabs is an option for a more expressive voice. Start a task, walk away, and hear when Claude needs your OK on a
permission prompt, gets stuck in a loop, or finishes, with a one-line summary of
what it did. It works in the terminal and in the Code tab of the Claude Mac app.

https://github.com/user-attachments/assets/f2c1f624-1941-436b-b3d9-a9229687f50c

You talk with Claude Code's built-in `/voice`. Kobi adds the other half: Claude
talks back.

## What you hear

| When | Example |
|---|---|
| Every 3 minutes of work, also during one long command, MCP call or web fetch | "Still on billing service, about 6 minutes in. Latest step: run the invoice tests." |
| The same error comes back 3 times, even after edits | "Heads up, billing service keeps hitting the same error. It might be stuck." |
| The same step gives the same result 3 times in a row | "Heads up, billing service keeps running the same thing over and over. It might be stuck." |
| Two steps alternate 3 times | "Heads up, billing service keeps going back and forth between the same two steps. It might be stuck." |
| A permission prompt waits more than a few seconds | "Hey, billing service needs your OK to run the database migration." |
| You still haven't answered it | "It's been 5 minutes. Billing service is still waiting on you." (at 2, 5 and 10 minutes) |
| Claude asks you a question | "Hey, billing service has a question for you." |
| An MCP server asks for input | "Hey, billing service needs your input for Linear." |
| Claude ended on a question and you didn't reply | "Hey, billing service is still waiting on your answer." |
| The turn fails | "Billing service hit an error. Take a look when you can." |
| Claude finishes | One short line Claude writes for you, e.g. "Fixed the rounding bug, though the refund test is still flaky." |
| You were on a call, or another app used the mic | Nothing until the mic is free. Then the lines you missed, most urgent first: "While you were on the mic: Hey, billing service needs your OK to run the database migration." |
| Your prompt arrives (level `all` only) | "On it." |

With several sessions open, you hear which one is talking. The finished line
starts with the project, like "From billing service: fixed the rounding bug." When
two sessions are open in the same project, Kobi names the session instead,
with a short form of the name you see in `/resume`: "Hey, the refund rounding
session needs your OK." When two open sessions would get the same short name, it
adds the project: "Hey, refund rounding in billing service needs your OK." Folder
names are said as words, so `billing_service` and `billingService` both sound
like "billing service".

Kobi only speaks while `/voice` is on. It stops talking when you start, plays
repeated lines from a cache, and beeps if the voice fails. Reminders stop as soon
as you answer, including when you press Esc.

Kobi also waits while another app uses the microphone, for example during a
Zoom, Meet, or FaceTime call, or while you dictate with `/voice`. When the mic
is free, you hear what you missed: lines that need you first, then stuck
warnings and failures, then finished lines. Progress updates are skipped, and a
prompt that you answered during the call is not read. After a short wait, such
as while you dictate, the line plays as usual.

You choose how much Kobi says. `normal` is the default:

| Level | What you hear |
|---|---|
| `quiet` | Only when it needs you, might be stuck, something fails, or Claude finishes |
| `normal` | Quiet, plus a progress update every 3 minutes |
| `all` | Normal, plus "On it." when your prompt arrives |

You also choose the tone of the finished line. `plain` is the default:

| Style | Example |
|---|---|
| `plain` | "Fixed the rounding bug, though the refund test is still flaky." |
| `upbeat` | "Fixed the rounding bug, nice one. The refund test is still flaky, though." |
| `cheeky` | "Rounding bug's fixed. The refund test is still flaky, as is tradition." |

Claude writes the line fresh each time, so the jokes don't repeat. The style
only changes the finished line. Alerts, reminders and stuck warnings stay plain.
When a task fails or Claude needs an answer from you, the finished line is plain too.

Cost: nothing with Kokoro. With ElevenLabs v4 Turbo, about $8 a month at roughly 100 spoken lines a day.

### Kokoro or ElevenLabs?

| | Kokoro (default) | ElevenLabs |
|---|---|---|
| Sound | Clear and natural, a little flat | The most natural and expressive. Listeners pick it over Kokoro in about 4 of 5 blind votes. |
| Cost | Free | About $8 a month |
| Privacy | Lines stay on your Mac | Each line goes to ElevenLabs |
| Speed for a new line | About 0.1 to 0.3 s | About 0.7 to 1.1 s |
| Needs | Apple Silicon, macOS 15 or later, the Command Line Tools | An API key and internet |

The blind votes are from the [Artificial Analysis Speech Arena](https://artificialanalysis.ai/text-to-speech/leaderboard) in October 2026: Eleven v4 Turbo ranked first of 96 models, and Kokoro about 50th. You can switch at any time. See [Change the voice](#change-the-voice).

## Requirements

- A Mac.
- Claude Code in a terminal, or the Code tab of the Claude Mac app. Claude Code must be signed in with a Claude.ai account. `/voice` does not work with an API key, Bedrock, Vertex, or Foundry.
- For Kokoro (the default): a Mac with Apple Silicon, macOS 15 or later, and the Command Line Tools. To install them, run `xcode-select --install`. The first setup builds a helper (about 2 minutes) and downloads the voice (about 460 MB on disk).
- For ElevenLabs instead: an ElevenLabs API key with the Text to Speech permission. A free ElevenLabs account works with premade voices.
- `jq`. To install it, run `brew install jq`.
- Optional: `swiftc`, which comes with the Command Line Tools. Without it, Kobi does not stop talking when you start to talk, and it does not wait while you are on a call.

## Kobi for Mac (optional)

Kobi for Mac is a menu bar app that works with the plugin. It needs a Mac
with Apple Silicon and macOS 26 or later. While it runs, it plays every line
instead of the plugin. When it is not running, the plugin speaks for itself.

**Menu bar panel.** It shows the status, your open sessions (the ones that need
you first), recent lines you can replay, and these items:

- Mute for 1 hour, until tomorrow morning, or until you unmute.
- Activity, Settings, and Quit.

**Orb.** A floating particle orb shows when Kobi is listening, working or
speaking. Drag it to move it, double-click to reset its position. You can change
its color or hide it in Settings, under Listening.

**Activity window.** A 24-hour Day Dial around the orb shows your day. It also
has a recap, search, and replay. Click the orb to talk.

**Voice commands.** Hold Right Option (the default hotkey), say "Hey Kobi"
(the wake word, off by default), or click the orb in Activity. "Hey Kobe"
sounds the same and wakes it too. Say the command in the same breath ("Hey
Kobi, stop billing"), or after the chime. "Kobi" alone, with no greeting, only
chimes: say the command after it. You can:

- send a session a prompt: "tell billing service to run the tests"
- ask what is going on: "what's everyone doing?" or "what's billing doing?"
- stop a session: "stop billing", or "stop billing now" for a background session
- start a session: "start a new session in blog to fix the header"
- answer a permission prompt: after "billing service needs your OK", say "yes" or "no"

**Settings** has four pages: Speaking, Voice, Listening and General. You choose
the speaker and the microphone there. Settings also checks for the Claude Code
plugin, and installs, enables or updates it with `claude plugin` commands.

**Other apps.**

- Full screen apps keep Kobi silent by default. Set `KOBI_FULLSCREEN` to
  `silent`, `answers` (speak only when you ask) or `speak`.
- Other apps are turned down only while Kobi's voice plays.

**Privacy.** See [PRIVACY.md](PRIVACY.md).

- Audio is never saved. It stays in memory, in a ring buffer of about 10 seconds.
- Kobi keeps what it said and what you said to it, as text, for 24 hours by
  default. The file is `~/Library/Application Support/Kobi/history.jsonl`
  (mode 0600, readable only by your account).
- In Settings, General, History, choose **For 24 hours**, **Until Kobi quits**
  or **Off** (`KOBI_HISTORY=day|session|off`). **Clear History** removes it now.
- History never goes into logs or Copy Diagnostics.
- Kokoro (the default) and the Mac's voice run on your Mac. ElevenLabs, when you
  choose it, receives the text of each line.
- Commands are understood on the Mac (Apple Intelligence, with a fixed set of
  phrases when it is off).

Listening needs the microphone permission, Input Monitoring for the hotkey, and
about 1 GB of speech models, downloaded once. Lowering other apps needs the
system audio capture permission.

To build it from this repo, run `bash scripts/release-app.sh --local`, then open
`app/build/release/Kobi.app`. It needs Xcode and XcodeGen
(`brew install xcodegen`).

## Install

1. In Claude Code, run these two commands:

   ```
   /plugin marketplace add sdusteric/kobi
   /plugin install kobi@kobi
   ```

2. Run `/kobi:setup`. Claude asks you to choose Kokoro or ElevenLabs, then a voice. If your Mac can't run Kokoro, Claude says why and offers ElevenLabs or the Mac's own voice.
3. Claude asks a few more questions together: whether to send dictation when you release Space, whether Kobi can update itself (answer yes to get new versions automatically), how much it should say (`quiet`, `normal`, or `all`), and the style (`plain`, `upbeat`, or `cheeky`).
4. Kokoro: wait while setup builds the helper (about 2 minutes) and downloads the voice. You can walk away. ElevenLabs: copy your API key to the clipboard and tell Claude when you copied it. The setup script reads the key from the clipboard, so the key does not go into the chat.
5. Listen for the test line. When you hear it, the setup is complete.
6. Run `/voice`. Hold Space to talk.

### Install with a terminal

You can also do the setup in a terminal. The script asks whether to use Kokoro or ElevenLabs and shows a numbered list of voices. For ElevenLabs, it also asks for the key.

1. Do step 1 of [Install](#install).
2. In a terminal, run:

   ```
   bash ~/.claude/plugins/marketplaces/kobi/plugin/scripts/setup.sh
   ```

To see all options, run the same command with `--help`.

## Change the voice

The easiest way: in Claude Code, run `/kobi:setup` and choose a different engine or voice.

In a terminal, run `bash ~/.claude/plugins/marketplaces/kobi/plugin/scripts/setup.sh` with one of these options:

| To | Options |
|---|---|
| Choose a Kokoro voice from a list | `--engine kokoro` |
| Use a specific Kokoro voice | `--engine kokoro --voice af_bella` |
| See all Kokoro voices | `--engine kokoro --list-voices` |
| Choose an ElevenLabs voice from a list | `--engine elevenlabs` |
| Use a specific ElevenLabs voice | `--engine elevenlabs --voice VOICE_ID` |

Kokoro voice names that start with `af` and `am` are American English, female and male. Names that start with `bf` and `bm` are British English.

Switching engines keeps your ElevenLabs key, so you can switch back without entering it again.

Each method plays a test line in the new voice. If the voice does not work, the script shows the reason and keeps your old voice.

To find an ElevenLabs voice ID:

1. Open [elevenlabs.io](https://elevenlabs.io) and go to **Voices**.
2. Select a voice.
3. Copy its voice ID.

Premade voices work on all ElevenLabs plans. A voice from the Voice Library can need a paid plan. The setup script tells you when your plan cannot use a voice.

## Use

| Action | How |
|---|---|
| Turn voice on or off | Run `/voice`. |
| Talk | Hold Space. Talk. Release Space. |
| Send the prompt when you release Space | Set `"voice": { "autoSubmit": true }` in `~/.claude/settings.json`. `/kobi:setup` can set it for you. |
| Mute Kobi | Run `touch ~/.config/kobi/mute`. |
| Unmute Kobi | Run `rm ~/.config/kobi/mute`. |
| Change the voice, the engine, or the key | Run `/kobi:setup`. See [Change the voice](#change-the-voice). |
| Change how much Kobi says | Run `bash ~/.claude/plugins/marketplaces/kobi/plugin/scripts/setup.sh --level quiet`. Use `quiet`, `normal`, or `all`. |
| Change the style | Run `bash ~/.claude/plugins/marketplaces/kobi/plugin/scripts/setup.sh --style cheeky`. Use `plain`, `upbeat`, or `cheeky`. |
| Show the current setup | Run `bash ~/.claude/plugins/marketplaces/kobi/plugin/scripts/setup.sh --status`. |

## Roll call

Ask what every open session is doing, and hear the ones that need you first:

> Three sessions. Billing service needs your OK to run the database migration.
> Invoice api is working, 12 minutes in. Docs site finished: fixed the broken links.

The roll call plays even when Kobi is muted, `/voice` is off, or you are on a call, because you asked for it.

- **In a session:** run `/kobi:rollcall`.
- **With a hotkey (no Claude turn, about a second):**
  1. Open the Shortcuts app and make a new shortcut.
  2. Add the action **Run Shell Script** with this script:
     `bash ~/.claude/plugins/marketplaces/kobi/plugin/scripts/speak.sh rollcall`
  3. In the shortcut's details, click **Add Keyboard Shortcut** and press the keys you want.

## Update

If you turned on auto-update during setup, you do not need to do anything. Claude Code installs new versions a few minutes after a session starts, then shows `Plugin updated: kobi`.

To turn on auto-update later, run `bash ~/.claude/plugins/marketplaces/kobi/plugin/scripts/setup.sh --auto-update`. You can also use `/plugin`, then **Marketplaces**, then **kobi**, then **Enable auto-update**.

To update by hand:

1. In a terminal, run these two commands:

   ```
   claude plugin marketplace update kobi
   claude plugin update kobi@kobi
   ```

2. Start a new Claude Code session.

Your key and voice stay the same.

## Uninstall

1. In a terminal, run `claude plugin uninstall kobi@kobi`.
2. To remove your settings and the Kokoro helper, run `rm -rf ~/.config/kobi`. To remove the Kokoro voice files too, run `rm -rf ~/.cache/fluidaudio`.

## How it works

The plugin adds hooks for these events: `SessionStart`, `SessionEnd`, `UserPromptSubmit`, `PreToolUse` (for
`AskUserQuestion`, and in the background for `Bash`, MCP tools, `WebFetch` and `WebSearch`), `PermissionRequest`, `PostToolUse`, `PostToolUseFailure`,
`Stop`, `StopFailure`, `Elicitation`, `ElicitationResult`, and `Notification` (for `permission_prompt`,
`idle_prompt`, `elicitation_dialog` and `elicitation_url_dialog`). Each hook runs `plugin/scripts/speak.sh` and returns in about 50 ms. The
speech runs in the background, so Kobi does not slow down Claude.

With Kokoro, a small helper keeps the voice model loaded while you work, so a
line is ready in about a quarter of a second. It starts with a session, or
with the first line, and quits after 10 minutes without a line to give its
memory (about 1 GB) back. If Kokoro or ElevenLabs fails, Kobi says the line
with the Mac's own voice and notes why in its log. If that fails too, you hear
a beep.

Each session keeps a short status (needs you, stuck, working, finished) in Kobi's
private folder. The roll call reads it.

No hook fires when you approve a permission prompt. Claude Code runs an approved
command in a shell under its own process, with the command in the shell's
arguments, so Kobi looks for it there: once the command runs, the reminders
stop, the roll call says the session is working, and "still on it" updates start.

A second `PermissionRequest` hook lets Kobi for Mac answer a prompt by voice.
When the app runs and can listen, the hook offers it the prompt and waits for
your spoken yes or no. The dialog stays on screen while it waits, and the first
answer wins: a click, Esc, or your voice. Without the app the hook ends at once.

Kobi looks for three signs that Claude is stuck. It uses the same patterns as
the stuck detector in OpenHands:

- The same error comes back 3 times in one task, even if Claude edits code between the attempts. Kobi removes noise from the error before it compares, such as times, durations, process IDs, and line numbers. It keeps counts such as "3 failed", because a changed count means progress.
- The same step gives the same result 3 times in a row.
- Two steps alternate 3 times.

One slow command is never "stuck", because nothing repeats. Kobi ignores commands that wait on purpose, such as `sleep`, `watch`, and `gh run watch`. You hear at most one stuck warning for each task.

When a permission prompt or a question shows, Kobi starts a timer. The timer
speaks the reminders. Each reminder first checks that the prompt still waits. If
you answered, the timer stops.

Kobi keeps a list of open sessions in its own folder. A session that
closes, or that is quiet for 6 hours, leaves the list. When another session is
open, the finished line starts with the project name. When another session is
open in the same project, Kobi says the session's name instead. It reads the
name from the session transcript: a `/rename` name first, then the name that
Claude Code made. A name of 3 words or fewer is said as it is. A longer one is
cut to its first few words, without a leading verb or "the": "Create guest
confirmation email with event details" becomes "guest confirmation email". A
new session can have no name for its first minute.

When `/voice` is on, the prompt hook tells Claude to end each reply with one line
that starts with 🗣. When Claude stops, the `Stop` hook reads that line aloud.
Kobi does not change your `CLAUDE.md` or your `settings.json`.

Kobi keeps your engine, voice and ElevenLabs key in `~/.config/kobi/config`. Only your user
account can read this file. If you also set `ELEVENLABS_API_KEY` for other tools,
Kobi uses the key in its config file, not the environment variable.

Everything else Kobi writes, such as the session list, reminder state, the log,
and cached audio, goes in your own private macOS folders, not the shared `/tmp`.
Other accounts on the Mac cannot read those files or plant files there.

## Settings

To change a setting, add a line to `~/.config/kobi/config`, for example
`KOBI_BEAT_SECS=300`.

| Setting | Default | What it controls |
|---|---|---|
| `KOBI_LEVEL` | `normal` | How much Kobi says: `quiet`, `normal`, or `all` |
| `KOBI_STYLE` | `plain` | The tone of the finished line: `plain`, `upbeat`, or `cheeky` |
| `KOBI_SESSION_NAME` | `auto` | When to say the session's name: `auto` (only when two sessions share a project), `always`, or `never`. `never` also removes the project name from the finished line. |
| `KOBI_ENGINE` | `kokoro` | `kokoro` (on your Mac), `elevenlabs`, or `say` (the Mac's own voice). A config from before 0.9.0 with an ElevenLabs key keeps `elevenlabs`. |
| `KOBI_KOKORO_VOICE` | `af_heart` | The Kokoro voice |
| `KOBI_KOKORO_IDLE_SECS` | `600` | Seconds without a line before Kokoro quits and frees its memory |
| `KOBI_MODEL` | `eleven_v4_turbo` | The ElevenLabs model that makes the speech (ElevenLabs only) |
| `KOBI_BEAT_SECS` | `180` | The number of seconds between "still on it" updates |
| `KOBI_LOOP_REPEATS` | `3` | The number of repeats that causes a "might be stuck" warning |
| `KOBI_REMIND_MINS` | `"2 5 10"` | The minutes after a prompt when Kobi reminds you that it still waits. Use quotes. |
| `KOBI_HOLD_ON_MIC` | `on` | `on` waits while another app uses the microphone and catches you up after. `off` speaks right away. |
| `KOBI_FULLSCREEN` | `silent` | Kobi for Mac only. What Kobi does while a full screen app is in front: `silent`, `answers` (speak only when you ask), or `speak`. |
| `KOBI_HISTORY` | `day` | Kobi for Mac only. How long text history is kept: `day` (24 hours), `session` (until Kobi quits), or `off`. |

## Troubleshooting

| Problem | What to do |
|---|---|
| You hear no voice and no beep | Run `setup.sh --status`. Make sure that `/voice` is on. Make sure that the file `~/.config/kobi/mute` does not exist. |
| You hear the Mac's own voice or a beep | Run `tail "$(getconf DARWIN_USER_TEMP_DIR)kobi/kobi.log"`. A `kokoro:` line says why Kokoro failed. To rebuild it, run `setup.sh --engine kokoro`. For ElevenLabs, error 401 means that the key is not correct, and error 404 means that the voice ID is not correct. |
| Setup says Kokoro can't run here | Kokoro needs a Mac with Apple Silicon and macOS 15 or later. On such a Mac, install the Command Line Tools with `xcode-select --install`, then run setup again. Or use ElevenLabs. `setup.sh --status` shows what is missing on the `Kokoro on this Mac` line. |
| Setup can't build the Kokoro helper | Run `xcode-select --install`, then setup again. The details are in `~/.config/kobi/kokoro-build.log`. Or use ElevenLabs: `setup.sh --engine elevenlabs`. |
| The script says that your plan cannot use the voice | Choose a premade voice, or upgrade your ElevenLabs plan. ElevenLabs sells separate plans for ElevenCreative, ElevenAgents, and ElevenAPI. Make sure that your plan includes API access to Text to Speech. |
| Claude Code shows `Unknown command: /voice` | Run `/login` and sign in with a Claude.ai account. Remove `ANTHROPIC_API_KEY` from your environment. |
| `/voice` does not record | Open System Settings > Privacy & Security > Microphone. Turn on access for your terminal app. |
| Kobi is silent, and lines come much later | Another app may be using the microphone. Run `~/.config/kobi/mic-in-use --list` to see which app. An app marked `counts` makes Kobi wait. |

## Limits

- Kokoro speaks English only, with fewer voices than ElevenLabs and less expression.
- After an update, Kobi rebuilds the Kokoro helper in the background. Until it is done, the old helper keeps working.
- Hooks cannot tell if you typed or talked. When `/voice` is on, Kobi also speaks for prompts that you type.
- No hook fires when you approve a permission prompt. For a shell command, Kobi notices the approval when the command starts. It cannot tell for a command without 10 plain characters in a row (like `ls`), or for an MCP tool or web fetch, so those count as waiting on you until they end.
- If you ask Claude to run the same failing command several times on purpose, Kobi can say that Claude might be stuck.
- All Claude Code sessions use the same speaker, so lines play one at a time. A line waits for the one that plays to finish. A line that waits more than a minute is dropped.
- If the owner of a Voice Library voice removes it, that voice stops working. Premade voices do not have this risk.
- Kobi cannot tell a call from other apps that use the microphone, such as a voice recorder. It waits for any of them. Siri and Voice Control do not count, and neither does macOS dictation (Fn Fn), because Voice Control uses the same process. Claude Code's `/voice` does count.
- A line held for more than 4 hours is dropped.
- Voice answers work for about an hour after a prompt shows. When subagents in one session ask at the same time, only the newest prompt can be answered by voice.
- Per-app microphone checks need macOS 14.2 or later. On older versions, Kobi does not wait during calls.
- After an update, Kobi rebuilds its microphone check in the background. If the build fails, for example because Xcode needs attention, Kobi does not wait during calls until you run `/kobi:setup` again. `setup.sh --status` shows when this happens.

## FAQ

**How do I get notified when Claude Code needs permission?**
Install Kobi and turn on `/voice`. When a permission prompt waits, you hear
what Claude wants to do, like "billing service needs your OK to run the database
migration," and a reminder at 2, 5 and 10 minutes if you don't answer.

**Does it work in the Claude Mac app?**
Yes, in the Code tab. The Mac app shares your Claude Code settings and plugins.
Turn on `/voice` once in a terminal, and Kobi talks in both places. Sessions
that were open before you installed or updated Kobi need a restart.

**Can I tell which session is talking when I run several?**
Yes. With several sessions open, the summary starts with the project name. Two
sessions in the same project are told apart by a short form of the session's
name.

**Does it work on Linux or Windows?**
Not yet. Kobi plays audio with `afplay`, which only macOS has.

**Does it need an ElevenLabs subscription?**
No. Kokoro, the default, is free and runs on your Mac. If you choose ElevenLabs,
a free ElevenLabs account works with premade voices. Some Voice Library voices
need a paid plan.

**Does my code leave my Mac?**
With Kokoro, no: Kobi makes the speech on your Mac. With ElevenLabs, each
spoken line (for example, a one-line summary of what Claude did) goes to
ElevenLabs to be turned into speech. Kobi for Mac keeps a text history on your Mac; see [PRIVACY.md](PRIVACY.md).

**How is it different from a notification sound?**
A sound tells you something happened. Kobi tells you what: which project,
what it wants to run, whether it looks stuck, and what it got done.

**Can I ask what all my sessions are doing?**
Yes. Press your roll call hotkey or run `/kobi:rollcall`. See [Roll call](#roll-call).

**Does it talk during my calls?**
No. While another app uses the microphone, Kobi waits. When the call ends,
you hear what you missed, with the lines that need you first.

## License

MIT. The software and models Kobi for Mac uses have their own licenses, listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md), which is also inside the app bundle.
