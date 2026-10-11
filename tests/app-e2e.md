# Earshot for Mac: end-to-end checklist

Run before each release of the app. Automated suites first, then the checks
that need the real app, real audio and a person.

## Automated

```bash
swift test --package-path app/EarshotKit
EARSHOT_TEST_DUCK=1 swift test --package-path app/EarshotKit --filter TapDuckerTests
EARSHOT_TEST_KOKORO=1 swift test --package-path app/EarshotKit --filter EngineTests
EARSHOT_TEST_MIC_HOG=<path to a program that opens the mic for N seconds> swift test --package-path app/EarshotKit --filter seesAnotherAppOpenTheMic
bash tests/stuck-and-levels.sh
bash tests/app-handoff.sh
bash tests/engines.sh
```

The playback tests skip themselves when the default output cannot start
playback within 3 seconds (a speaker in standby).

## With the real app

| Check | How | Expected |
|---|---|---|
| The app answers the plugin | Send a `say` line to the socket | `{"ok":true}`, log shows `line`, `ducking on`, `ducking off` |
| The plugin hands lines over | `bash scripts/speak.sh say "..."` | Plugin log: `the app took (alert)` |
| One instance only | Start a second copy | It exits at once |
| The plugin covers a dead app | Kill the app, run `speak.sh say` | The plugin says it (see `tests/app-handoff.sh`, crashed app case) |
| Holding during a call | Open the mic in another app, send a `need` line, close the mic | Log: `held need`; about 4 s after the mic closes, the line plays |
| Ducking with real audio | Play music, send a line | Music drops to the set level and comes back |
| Ducking with Bluetooth | Same, with AirPods or Bluetooth speakers | Same; switching output mid-line ends ducking |
| Ducking permission denied | Deny "System Audio Recording" for Earshot, play music, send a line | Music keeps playing at full volume; it must never go silent |
| Settings text fields | Type a voice name slowly | The config changes only on Return or leaving the field |
| Menu | Click the menu bar icon | Sessions, Mute for 1 Hour, Settings, Copy Diagnostics, Quit |
| Settings | Change level, voice, ducking | The config file changes; the next line uses it |
| First launch | New user account | Onboarding: three steps, test line, permission prompt for ducking |
| Sleep and wake | Sleep the Mac with the app running | After wake, lines still play |

## Results, 2026-10-11 (Claude, user away)

| Check | Result |
|---|---|
| Automated suites | All pass: EarshotKit 65, stuck-and-levels 126, app-handoff 16, engines 55. Hardware runs: ducking 3/3, Kokoro, mic. |
| The app answers the plugin | Pass |
| The plugin hands lines over | Pass |
| One instance only | Pass |
| The plugin covers a dead app | Pass (automated) |
| Holding during a call | Pass after a fix: the first run played a line at the start of a call, because Core Audio's change notifications came over a second late. `isBusy` now asks Core Audio directly. |
| Ducking with real audio | Ducking turned on and off around lines (log). Not heard: the user was away. |
| Ducking stuck | Found and fixed: `AVAudioPlayer.play()` blocked in Core Audio and the app stayed ducked for over an hour. Now a 30 s line timeout, a 45 s ducking cap, and teardown when the output device changes. |
| Speakers | Late in the run the default output (Audioengine 2+) could not start playback at all (`afplay`: AudioQueueStart failed, -66681, after 15 s). Outside Earshot; the app now survives it. |
| Menu, Settings, First launch, Sleep and wake | Not checked: needs a person at the Mac. |
