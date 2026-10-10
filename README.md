# Earshot

Spoken updates from Claude Code. Start a task, walk away, and hear when it
gets stuck, needs your OK, or finishes.

<!-- TODO: add a 20-30 second demo video or GIF here. -->

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

- macOS
- Claude Code signed in with a Claude.ai account (`/voice` doesn't work with an API key, Bedrock, Vertex or Foundry)
- An ElevenLabs API key with Text to Speech access. A free account works with premade voices.
- `jq` (`brew install jq`)
- Optional: `swiftc` (`xcode-select --install`), so Earshot stops talking when you start

## Install

In Claude Code:

```
/plugin marketplace add sdusteric/earshot
/plugin install earshot@earshot
/earshot:setup
```

`/earshot:setup` walks you through choosing a voice and saving your key. You copy
the key to your clipboard and the setup script reads it from there, so the key
never appears in the chat. You hear a test line when it works.

Then run `/voice` and hold Space to talk.

### Without Claude Code's help

Run the setup script in a terminal. It asks for the key and shows a numbered list
of voices:

```
bash ~/.claude/plugins/marketplaces/earshot/scripts/setup.sh
```

If that path doesn't exist on your machine, clone this repo and run
`bash scripts/setup.sh` from it. Run `setup.sh --help` for other options.

## Use

| Action | How |
|---|---|
| Turn voice on or off | `/voice` |
| Talk | Hold Space, talk, release |
| Send automatically on release | Set `"voice": { "autoSubmit": true }` in `~/.claude/settings.json` (setup can do this) |
| Mute for a while | `touch ~/.config/earshot/mute` |
| Unmute | `rm ~/.config/earshot/mute` |
| Change the voice or key | `/earshot:setup` again |
| See what's set up | `bash scripts/setup.sh --status` |

## How it works

The plugin adds five hooks: `UserPromptSubmit`, `PostToolUse`, `Stop`,
`StopFailure` and `Notification` (permission prompts). They all call
`scripts/speak.sh`.

While `/voice` is on, the prompt hook tells Claude to end each reply with one line
that starts with 🗣. When Claude finishes, the `Stop` hook reads that line aloud.
Nothing in your `CLAUDE.md` or `settings.json` is changed.

Your key and voice live in `~/.config/earshot/config`, readable only by you. A
saved config wins over any `ELEVENLABS_API_KEY` in your environment, so a key you
use for other tools doesn't get picked up by accident.

## Settings

Add any of these to `~/.config/earshot/config`:

| Setting | Default | Meaning |
|---|---|---|
| `EARSHOT_MODEL` | `eleven_v4_turbo` | ElevenLabs model |
| `EARSHOT_BEAT_SECS` | `180` | Seconds between "still on it" updates |
| `EARSHOT_LOOP_REPEATS` | `3` | Same step this many times in a row gives a warning |

## Troubleshooting

| Problem | Fix |
|---|---|
| No sound, no beep | Run `setup.sh --status`. Check that `/voice` is on and Earshot isn't muted. |
| A beep, no voice | Read `/tmp/earshot.log`. 401 means a bad key, 404 a bad voice ID. |
| "Your plan can't use this voice" | Voice Library voices can need a paid ElevenLabs plan. ElevenLabs sells separate plans for ElevenCreative, ElevenAgents and ElevenAPI, so check which one covers the API. Premade voices work on every plan. |
| `Unknown command: /voice` | Sign in with a Claude.ai account (`/login`) and remove `ANTHROPIC_API_KEY` from your environment. |
| No microphone | System Settings > Privacy & Security > Microphone, then turn on your terminal app. |

## Limits

- Hooks can't tell whether you typed or talked, so while `/voice` is on, typed prompts get spoken updates too.
- "Still on it" updates come only after a tool call finishes, so one long command stays silent.
- Several sessions share one speaker. A new line cuts off the one playing.
- If you use a community voice and its owner removes it, the voice stops working. Premade voices don't have this risk.

## License

MIT
