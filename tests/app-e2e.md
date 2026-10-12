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
| The plugin hands lines over | `bash plugin/scripts/speak.sh say "..."` | Plugin log: `the app took (alert)` |
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

## Listening (plan 2)

Release gate: the release waits for docs/superpowers/specs/2026-10-11-listening-probe.md (the Task 0 measurements) and the Task 21 eval output (`eval-parser.sh`, `eval-listener.sh`, the latency and power runs).

### Automated, with the models downloaded

```bash
EARSHOT_TEST_MODELS=1 swift test --package-path app/EarshotKit --filter FluidListeningTests
EARSHOT_TEST_FM=1 swift test --package-path app/EarshotKit --filter theRealModel
EARSHOT_TEST_MIC=1 swift test --package-path app/EarshotKit --filter recordsAboutOneSecond
bash scripts/eval-parser.sh
bash scripts/eval-listener.sh
bash scripts/send-integration.sh
```

### By hand

| Check | How | Expected |
|---|---|---|
| Hotkey command | Hold Right Option: "what's everyone doing", release | Chime, the orb pulses blue with your voice, turns violet while working, then pulses amber with the roll call |
| Tap and chord | Tap Right Option; type Option+e | Nothing: no chime, no orb |
| Wake word | Turn it on; "Hey Earshot, tell <a terminal session> to say hi" | "Sent to ..." and the terminal session answers |
| Desktop session | The same, naming a Code tab session in the Claude app | The message appears in that conversation |
| Two in one project | Two sessions in one folder; "tell <project> to run the tests" | "<Project> has two: ... Which one?", then a name works without the wake word |
| Voice approval | A session asks to run a command; after "needs your OK", say "yes" | Short sound, "Approved.", the dialog closes, the command runs |
| Late yes | Click the dialog, then say "yes" in the window | Nothing said, nothing written |
| Own voice | Play a "needs your OK" line through speakers with the wake word on | No wake, no approval |
| A call | FaceTime audio, then hold the hotkey | Nothing; the menu says another app uses the mic; lines wait for the catch-up |
| Barge-in | While Earshot reads a long roll call, hold the hotkey | It stops at once; the line is not said again |
| AirPods | Output on AirPods, wake word on | AirPods keep full quality (the built-in mic listens) |
| Sleep and lock | Lock the screen, unlock; sleep, wake | The mic closes while locked or asleep and comes back |
| Low Power Mode | Turn it on, on battery | The menu says the wake word is off in Low Power Mode; the hotkey still works |
| Start | "Start a new session in <trusted folder> to say hi" | "Started a session in ..."; `claude agents` lists it |
| Untrusted folder | Name a folder never opened in Claude | "... isn't trusted yet. Open it in Claude once first." |
| Stop | "Stop <busy session>" | "... will stop after its current step."; it stops at the next step |
| Secure input | In a password field, hold Right Option and type a character | No capture; a hold past 0.2 s plays the closed chime; the menu and the Listening settings say the hotkey is paused while another app uses secure keyboard entry |
| Orb with another app in front | Hold the hotkey while Safari or Terminal is frontmost | The orb shows at the top center |
| Orb moves | While the orb shows, drag it; next time it shows, double-click it | It stays where you dropped it and the app in front keeps focus; the double-click puts it back at the top center |
| Orb over a full screen app | Put an app in full screen, then hold the hotkey | The orb shows over the full screen app |
| Orb with Reduce Motion | Turn on Reduce Motion in Accessibility, then hold the hotkey and speak | The orb does not turn; it only brightens and grows a little with your voice |
| Orb with VoiceOver | Turn on VoiceOver, then hold the hotkey | VoiceOver says "Listening", then "Working on it" |
| First launch prompts | On a fresh install, start the app | No Input Monitoring prompt appears before onboarding's hotkey step |
| Chimes and own lines | Play the listening chime and Earshot's own lines through the speakers with the wake word on (the own-*.wav recordings in the listener eval include one with the chime) | Never wakes it (wake 0) |
| End of speech | Say a wake command, then stop talking | About 770 ms of silence ends it (the VAD's chunking; the spec's 600 ms was ruled to 770 ms) |
| Clients that hang up early | While the app runs, run `bash tests/app-handoff.sh` | The app is still running afterwards |
| A Mac locked while a prompt is open | A session asks for an OK; lock the screen before Earshot's line ends | No window opens and the mic stays closed |
| "Hey Earshot, yes" | With a prompt open, say "Hey Earshot, yes" after its approval window closed; then trigger a second prompt and say it inside that prompt's window (just after Earshot says it) | After the window closed: Earshot says "Hold the hotkey to answer it." and the prompt stays open. Inside the second prompt's window: it approves |
| A long hotkey command | Hold the hotkey and talk for more than 10 s | The closed chime at about 10 s, then "That was too long for me. Try a shorter command."; nothing is sent; letting go does nothing |
| A session named earshot | Run a session in a folder named earshot, with the wake word on; let it ask for an OK | Its "Hey, earshot needs your OK" alert never wakes Earshot; the approval window opens after the line |
| Upgrade onboarding | Start the app as a user who finished the 0.11 onboarding | Only the mic and wake word, hotkey, models and try it steps, once |
| Diagnostics | Copy Diagnostics | Listening, models, permissions and claude path; no transcripts, no prompts |
