---
name: setup
description: Set up Earshot spoken updates for Claude Code. Saves the user's ElevenLabs key, lets them choose a voice, and plays a test line. Use when the user runs /earshot:setup, or asks to set up Earshot, change its voice, change its key, or find out why it is silent.
---

# Earshot setup

The setup script is `../../scripts/setup.sh` relative to this skill's base directory. Call it `SETUP` below and always run it with `bash "<absolute path>"`.

**Never ask the user to paste their API key into the chat, never print it, and never read `~/.config/earshot/config`.** The script reads the key from the clipboard itself.

1. Run `bash SETUP --status` and show the user the result in a short list.
   - If they only want to know why it is silent, explain from the status: no key, no voice, `/voice` off, or muted. If the status looks fine, read the last lines of `/tmp/earshot.log`: 401 means a bad key, 404 a bad voice ID. Stop here unless something needs fixing.
2. Ask the user to choose a voice with AskUserQuestion.
   - Run `bash SETUP --list-voices` to get `id<TAB>category<TAB>name` lines. With no saved key it lists premade voices.
   - Offer up to four. Put the current voice first if there is one, otherwise Roger (casual) first and marked "(Recommended)". The user can choose "Other" and give a voice ID from their ElevenLabs Voices page.
   - Mention that premade voices work on every ElevenLabs plan. Voices from the Voice Library can need a higher plan.
3. If the status says the key is missing, or the user wants a new key: ask them to copy the key to the clipboard (elevenlabs.io > Developers > API Keys, with Text to Speech access) and tell you when it's copied. Then run `bash SETUP --key-from-clipboard --voice <ID>`.
   Otherwise run `bash SETUP --voice <ID>`.
4. If the script fails, relay its message in plain words. Common cases: the plan can't use that voice (offer premade voices and go back to step 2), the key was rejected (ask them to copy it again), or out of credits.
5. When it succeeds the user hears a test line. Tell them to copy something else over the key on their clipboard.
6. Ask whether they want dictation sent automatically when they release Space. If yes, set `voice.autoSubmit` to `true` in `~/.claude/settings.json`, keeping every other setting as it is.
7. Ask whether Earshot should update itself (recommended: yes). Claude Code leaves auto-update off for plugins outside Anthropic's own marketplaces, so without this the user keeps the version they installed. If yes, run `bash SETUP --auto-update`. If the status from step 1 says auto-update is not needed (a local folder install), skip this step.
8. Tell them to run `/voice` and hold Space to talk. Earshot only speaks while `/voice` is on. To mute it for a while: `touch ~/.config/earshot/mute`; to unmute: `rm ~/.config/earshot/mute`.
