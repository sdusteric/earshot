# Privacy

This page describes what Earshot for Mac and the Earshot plugin keep, send and ask for.

## What stays on your Mac

- Listening, speech recognition and command understanding run on the Mac. Command
  understanding uses Apple Intelligence, or a fixed set of phrases when it is off.
- Kokoro (the default voice) and the Mac's own voice run on the Mac.
- Audio is never saved. While Earshot listens, it holds about 10 seconds of audio
  in memory and drops it. It does not write audio to disk or send it anywhere.
- Earshot lowers other apps by playing their audio back quieter. It never records
  or saves their audio.

## What is saved, and where

Earshot for Mac keeps a history of what it said and what you said to it, as text.
It is a list of lines, with no audio.

- File: `~/Library/Application Support/Earshot/history.jsonl`
- Permissions: mode 0600, so only your account can read it.
- Default: kept for 24 hours.
- It feeds the recent lines in the menu, and the recap, search and replay in Activity.
- It never goes into logs or Copy Diagnostics.

The plugin keeps its own files in private macOS folders for your user account:
session status, reminder state, a log, and cached audio of lines it spoke.
`~/.config/earshot/config` holds your settings and, if you use ElevenLabs, your API
key (readable only by your account). The app and the plugin both read the key from there.

## What is sent

- **ElevenLabs**, only when you choose it as the voice. It receives the text of each
  line Earshot speaks, such as "Fixed the rounding bug." It does not receive your
  microphone audio or your history.
- **Update checks.** The app uses Sparkle to ask GitHub for the latest version
  (`https://github.com/sdusteric/earshot/releases/latest/download/appcast.xml`).
  The plugin updates through Claude Code.
- Kokoro and the Mac's voice send nothing.

## Turn off or clear history

In Earshot for Mac, open Settings, then General, then History:

- **Keep** has three choices: **For 24 hours** (the default), **Until Earshot quits**,
  and **Off**. The config key is `EARSHOT_HISTORY=day|session|off`.
- **Clear History** removes everything Earshot said and heard from this Mac.

You can also delete `~/Library/Application Support/Earshot/history.jsonl`.

## Permissions

| Permission | Why |
|---|---|
| Microphone | To hear your commands, with the hotkey or the wake word. |
| Input Monitoring | To see the hold-to-talk key (Right Option by default). Earshot reads only that key. |
| System audio capture | To turn other apps down while Earshot talks or listens. Earshot plays their audio back quieter and never records or saves it. |

You can decline any of them. Without the microphone, Earshot still speaks but cannot
take commands. Without system audio capture, it does not lower other apps.
