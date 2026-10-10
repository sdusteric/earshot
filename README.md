# Earshot

Spoken updates from Claude Code. Start a task, walk away, and hear when it
gets stuck, needs your OK, or finishes.

https://github.com/user-attachments/assets/f2c1f624-1941-436b-b3d9-a9229687f50c

You talk with Claude Code's built-in `/voice`. Earshot adds the other half: Claude
talks back with an ElevenLabs voice.

## What you hear

| When | Example |
|---|---|
| Your prompt arrives | "On it." |
| Every 3 minutes of work | "Still on billing service, about 6 minutes in. Latest step: run the invoice tests." |
| The same step runs 3 times in a row | "Heads up, billing service keeps running the same thing over and over. It might be stuck." |
| A permission prompt is waiting | "Hey, billing service needs your OK before it keeps going." |
| The turn fails | "Something broke in billing service. Take a look when you can." |
| Claude finishes | One short line Claude writes for you, e.g. "Fixed the rounding bug, though the refund test is still flaky." |

Earshot only speaks while `/voice` is on. It stops talking when you start, plays
repeated lines from a cache, and beeps if the voice fails.

Cost: about $8 a month with ElevenLabs v4 Turbo at roughly 100 spoken lines a day.

## Requirements

- A Mac.
- Claude Code, signed in with a Claude.ai account. `/voice` does not work with an API key, Bedrock, Vertex, or Foundry.
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
5. Run `/voice`. Hold Space to talk.

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
| Show the current setup | Run `bash ~/.claude/plugins/marketplaces/earshot/scripts/setup.sh --status`. |

## Update

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

The plugin adds five hooks: `UserPromptSubmit`, `PostToolUse`, `Stop`,
`StopFailure`, and `Notification` (for permission prompts). Each hook runs
`scripts/speak.sh`.

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
| `EARSHOT_MODEL` | `eleven_v4_turbo` | The ElevenLabs model that makes the speech |
| `EARSHOT_BEAT_SECS` | `180` | The number of seconds between "still on it" updates |
| `EARSHOT_LOOP_REPEATS` | `3` | The number of identical steps in a row that causes a "might be stuck" warning |

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
- All Claude Code sessions use the same speaker. A new line stops the line that plays.
- If the owner of a Voice Library voice removes it, that voice stops working. Premade voices do not have this risk.

## License

MIT
