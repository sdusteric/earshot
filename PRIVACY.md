# Privacy

This page describes what Kobi for Mac and the Kobi plugin keep, send and ask for.

## What stays on your Mac

- Listening, speech recognition and command understanding run on the Mac. Command
  understanding uses Apple Intelligence, or a fixed set of phrases when it is off.
- Kokoro (the default voice) and the Mac's own voice run on the Mac.
- Audio is never saved. While Kobi listens, it holds about 10 seconds of audio
  in memory and drops it. It does not write audio to disk or send it anywhere.
- Kobi lowers other apps by playing their audio back quieter. It never records
  or saves their audio.

## What is saved, and where

Kobi for Mac keeps a history of what it said and what you said to it, as text.
It is a list of lines, with no audio.

- File: `~/Library/Application Support/Kobi/history.jsonl`
- Permissions: mode 0600, so only your account can read it.
- Default: kept for 24 hours.
- It feeds the recent lines in the menu, and the recap, search and replay in Activity.
- It never goes into logs or Copy Diagnostics.

The plugin keeps its own files in private macOS folders for your user account:
session status, reminder state, a log, and cached audio of lines it spoke.
`~/.config/kobi/config` holds your settings and, if you use ElevenLabs, your API
key (readable only by your account). The app and the plugin both read the key from there.

## What is sent

- **ElevenLabs**, only when you choose it as the voice. It receives the text of each
  line Kobi speaks, such as "Fixed the rounding bug." It does not receive your
  microphone audio or your history.
- **Update checks.** The app uses Sparkle to fetch a small update feed from GitHub
  (`https://raw.githubusercontent.com/sdusteric/kobi/main/packaging/appcast.xml`).
  GitHub sees your IP address and the app version Sparkle reports. Once checks are
  allowed, Sparkle checks about once a day. Downloads of a new version also come from
  GitHub, and from Homebrew if you installed with the cask. The plugin updates through Claude Code.
- **Model downloads.** The first time you turn on listening or use the Kokoro voice, the
  app downloads speech models from Hugging Face through FluidAudio: Silero VAD, Parakeet
  CTC 110M and Parakeet TDT v2 (listening, about 1 GB together), and the Kokoro voice.
  Hugging Face sees your IP address and which files you request. Nothing else is sent.
  The listening models go to `~/Library/Application Support/FluidAudio/Models`. Kokoro goes
  to `~/.cache/fluidaudio/Models`, which the plugin shares. Credits and licenses for these
  models are in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
- Kokoro and the Mac's voice send nothing.

## What the app reads and runs on your Mac

- `~/.claude.json`, to list the folders Claude Code knows, and the `claude` command,
  which it starts to talk to your sessions in those folders. It also uses Claude Code's
  sockets in `/tmp/cc-socks` to reach running sessions. macOS may ask you to allow
  access to Documents, Desktop or Downloads when a project is in one of them.
- **Copy Diagnostics** in the menu copies settings, the bundle IDs of apps using the
  microphone, the path to `claude`, plugin status and recent events to the clipboard.
  Kobi sends it nowhere. You choose where to paste it.

## Turn off or clear history

In Kobi for Mac, open Settings, then General, then History:

- **Keep** has three choices: **For 24 hours** (the default), **Until Kobi quits**,
  and **Off**. The config key is `KOBI_HISTORY=day|session|off`.
- **Clear History** removes everything Kobi said and heard from this Mac.

You can also delete `~/Library/Application Support/Kobi/history.jsonl`.

## Permissions

| Permission | Why |
|---|---|
| Microphone | To hear your commands, with the hotkey or the wake word. |
| Input Monitoring | To see the hold-to-talk key (Right Option by default). Kobi sees modifier key changes to spot that key, and sees that another key was pressed (to cancel a hold) without reading which one. It stores and sends nothing from the keyboard. |
| System audio capture | To turn other apps down while Kobi talks or listens. Kobi plays their audio back quieter and never records or saves it. |

You can decline any of them. Without the microphone, Kobi still speaks but cannot
take commands. Without system audio capture, it does not lower other apps.
