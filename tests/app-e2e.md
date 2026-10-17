# Kobi for Mac: end-to-end checklist

Run before each release of the app. Automated suites first, then the checks
that need the real app, real audio and a person.

## Automated

```bash
swift test --package-path app/KobiKit
KOBI_TEST_DUCK=1 swift test --package-path app/KobiKit --filter TapDuckerTests
KOBI_TEST_KOKORO=1 swift test --package-path app/KobiKit --filter EngineTests
# compile once: swiftc -O tests/mic-hog.swift -o /tmp/mic-hog (opens the default input for N seconds)
KOBI_TEST_MIC_HOG=/tmp/mic-hog swift test --package-path app/KobiKit --filter seesAnotherAppOpenTheMic
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
| Ducking permission denied | Deny "System Audio Recording" for Kobi, play music, send a line | Music keeps playing at full volume; it must never go silent |
| Settings text fields | Type a voice name slowly | The config changes only on Return or leaving the field |
| Menu | Click the menu bar icon | Sessions, Mute for 1 Hour, Settings, Copy Diagnostics, Quit |
| Settings | Change level, voice, ducking | The config file changes; the next line uses it |
| First launch | New user account | Onboarding: three steps, test line, permission prompt for ducking |
| Sleep and wake | Sleep the Mac with the app running | After wake, lines still play |

## Results, 2026-10-11 (Claude, user away)

| Check | Result |
|---|---|
| Automated suites | All pass: KobiKit 65, stuck-and-levels 126, app-handoff 16, engines 55. Hardware runs: ducking 3/3, Kokoro, mic. |
| The app answers the plugin | Pass |
| The plugin hands lines over | Pass |
| One instance only | Pass |
| The plugin covers a dead app | Pass (automated) |
| Holding during a call | Pass after a fix: the first run played a line at the start of a call, because Core Audio's change notifications came over a second late. `isBusy` now asks Core Audio directly. |
| Ducking with real audio | Ducking turned on and off around lines (log). Not heard: the user was away. |
| Ducking stuck | Found and fixed: `AVAudioPlayer.play()` blocked in Core Audio and the app stayed ducked for over an hour. Now a 30 s line timeout, a 45 s ducking cap, and teardown when the output device changes. |
| Speakers | Late in the run the default output (Audioengine 2+) could not start playback at all (`afplay`: AudioQueueStart failed, -66681, after 15 s). Outside Kobi; the app now survives it. |
| Menu, Settings, First launch, Sleep and wake | Not checked: needs a person at the Mac. |

## Results, 2026-10-15 (automated only)

| Suite | Result |
|---|---|
| KobiKit | 603 pass |
| stuck-and-levels, app-handoff, engines | 132, 22 and 55 pass |
| Kokoro, ducking, mic recording, on-device model | Pass |
| Mic hog | Not run: needs a program that holds the mic open |
| FluidListeningTests | 23 of 24. The wake spotter woke on "Good morning everyone, the build passed." (macOS `say` voice) at sensitivity 5, the default |
| Wake word, found the same day | It woke on every sentence at every sensitivity. FluidAudio 0.17.7 copies a short clip into an uncleared 15 s buffer (issue #991), so the model read leftover memory, often NaN, and every clip scored the same (about -9.4). Fixed by padding clips with zeros to 15 s before the spotter and the name boost; the threshold was set again on six macOS voices (sensitivity 5 is -6.0, as finally judged). There it catches 10 of 18 "Hey Earshot" in the first 1.5 s and fires on 4 of 60 sentences without the word; a wake whose words lack the phrase sends nothing. FluidListeningTests 24 of 24 after. Needs real voices: run `eval-listener.sh record` |
| eval-parser | 65 of 100 (21 by the grammar). Bar 95%. Most misses are phrasings the grammar lacks that the on-device model answers as unknown ("let billing know...", "make billing stop", "absolutely not") |
| eval-parser, after the fixes the same day | 103 of 105 (the 100 plus 5 window phrases that must answer nothing). Held out, never tuned on: 56 of 60 and 58 of 60. The eval warms the model while you would be talking (1 s, `KOBI_EVAL_TALK_MS`), as the app does; without that wait, on a busy Mac, warm-up counts against the 3 s limit and the score falls to about 85%. The hearing bench (240 synthetic clips) is level: 144 right before, 145 after, still 0 unsafe; two cut clips moved from "didn't get it" to a harmless read (a roll call, or staying quiet). A review found casual phrases that would send or stop ("make it so", "will the blog be done soon", "stop billing, it's about to delete..." read as a prompt); all were fixed and have tests |
| eval-listener | Not run: needs recordings of your voice (`eval-listener.sh record`) |
| send-integration | Not run: Claude Code needs this folder trusted first (run `claude` here once) |

## Wake word bench, 2026-10-15 (synthetic voices, no recordings of yours)

This bench, its reviews and the experiment after it measured "Hey Earshot", the wake
phrase before the app was renamed Kobi. "Hey Kobi" is measured in the next section.

Method (tests/wake/README.md): 30 voices (every English Kokoro voice plus say
Samantha and Daniel) x 133 phrases (32 positives, 86 near-misses, 15 mentions) x 5 mic
conditions (clean, quiet, noise gate 0.2, 0.4, 0.6): 19950 clips. The split is by
voice, a third held out. Real human speech that must not wake: LibriSpeech
test-clean, 2620 clips, 5.4 h. Each clip is cut into segments as the listener cuts
them, the spotter scores each, and every fire goes through Apple's
SpeechTranscriber, Parakeet and the CTC model's own words. `wake-rescore` then
tries confirm rules on the saved text without running the audio again.

Decision: the spotter fires at -8.0 at sensitivity 5 (-7.0 at 1, -9.25 at 10,
0.25 a step). Apple's recognizer reads the fired window, and the wake passes
when its words start with the wake phrase in one of two tiers
(`Listener.wakeWords`, described below). Parakeet is asked only when Apple has
no answer and Parakeet is already loaded. A wake that no recognizer could judge
(no answer, or past the 0.75 s confirm limit) passes only at a spotter score of
-5.0 or more. The CTC model's own words are no use as a confirm: 2 of 17007 of
its looks passed.

Results at -8.0 (sensitivity 5), Apple's confirm and the finish rule as shipped, from
`wake-rescore ... --threshold -8` over 22570 files (19950 synthetic + 2620
LibriSpeech), end to end block. Tune is 20 voices, holdout 10. False wakes are
counted in two kinds: dispatch (words of the segment go out as a command, the
dangerous kind) and window (a chime that sends nothing and only opens the command
window).

Positives woken (chime) by split and condition. The tool counts a positive as
woken and does not split it into dispatch or window:

| Split | Clean | Quiet | Gate 0.2 | Gate 0.4 | Gate 0.6 | All |
|---|---|---|---|---|---|---|
| tune (of 640 each) | 555 (87%) | 319 (50%) | 243 (38%) | 26 (4%) | 2 (0%) | 1145/3200 (36%) |
| holdout (of 320 each) | 259 (81%) | 122 (38%) | 109 (34%) | 19 (6%) | 3 (1%) | 512/1600 (32%) |

False wakes at -8.0:

| Class (clips) | Dispatch tune | Dispatch holdout | Window tune | Window holdout |
|---|---|---|---|---|
| Near-miss (8600 tune, 4300 holdout) | 0 | 0 | 269 | 136 |
| Mention (1500 tune, 750 holdout) | 0 | 0 | 6 | 2 |

LibriSpeech (5.40 h): the spotter fires 142.6 times an hour; dispatch 0.00 an
hour, window 0.00 an hour (0 false wakes of either kind).

There are no dispatch false wakes at -8.0, -7.5 or -7.0. The 8 mention windows
are 2 clips in the 0.6 gate and 6 in the 0.4 gate: the gate seems to cut the
start of the sentence (an inference from what Apple heard), so Apple hears
"Earshot, ..." with no greeting. That wake is bare: it chimes and opens the
window and sends nothing of the segment.

For comparison, at -7.5: 1043/3200 tune and 457/1600 holdout positives, 213 and
108 near-miss windows, 4 and 2 mention windows, 70.6 fires an hour; at -7.0:
884/3200 and 405/1600, 179 and 91 windows, 2 and 1 mention windows, 29.1 fires
an hour. Dispatch false wakes are 0 and LibriSpeech dispatch and window are 0.00
an hour at all three.

The spotter alone, which the rule does not change:

| | Clean positives | Quiet positives | Near-miss audible |
|---|---|---|---|
| Spotter alone at -6.0 (before the confirm) | 73% | 17% | 505/4800 |
| Spotter alone at -5.0 (the no-answer fallback) | 52% | | 3% |

The spotter alone at -8.0 would chime about 140 times an hour of speech (142.6
fires an hour on LibriSpeech): that is why a wake no recognizer can judge needs
-5.0 (0 audible an hour on LibriSpeech).

Confirm latency (Apple, on fires at -8.0): 50.9 ms at the median, 58.6 ms at the
95th percentile (Parakeet, loaded: 34.8 and 37.0 ms; -7.5 and -7.0 are within 0.5 ms of Apple's). `Timing.confirmLimit` went
from 1.5 s to 0.75 s.

FluidAudio: the padding fix for issue #991 is merged upstream (PR #1003, merge
e05ab923) but not in a tagged release. An A/B of the 0.17.7 tag against e05ab923
was identical on the tests, the parser eval, the hearing bench and the spotter's
scores. Earshot stays on the 0.17.7 tag and moves to the first tag that includes
e05ab923. `CtcShared.fullLength` keeps padding clips to 15 s either way: without
it the scores move (309 of 1738 rows) and the thresholds were tuned with it.

First safety review:

- `Listener.wakeWords` takes no verb as a greeting (take, get, pay, my) and not
  "you shot" or "a shot" (sound key AXT) as the phrase: "Take a shot, run the
  test" fired the spotter at -7.9, Apple heard it word for word, and "Run the
  test." went out as a command. Greetings are hey, hi, high, hay, hate, eight,
  a, ok, okay.
- wake-eval (`scripts/eval-listener.sh`) runs the listener's path: spotter at
  sensitivity 5, Apple's confirm within the limit, the strict score with no
  answer, then the finish rule on the transcripts.

Second safety review: "your shot" and "earshot" have the same sound key (ARXT),
so "Okay, your shot. Approve it." passed the confirm and sent "Approve it.",
which can approve a pending permission prompt; and the finish looked for an
earshot-like word anywhere in the first three, so "did you ask earshot to run
the tests" sent "to run the tests". Now there are two tiers:

- Literal: the phrase written as such ("earshot", "earshots", "ear shot", "air
  shot"), right after a greeting or as the first word, never later. A bare
  "Earshot" first needs a comma or a stop after it, or nothing after it, at the
  confirm. Only this tier sends words as a command.
- Sound-alike: a greeting, then a word or two that sound like ARXT and end in
  "shot" but are spelled otherwise ("your shot", "you're shot", "year shot",
  "we're shot", "our shots"). It may chime; nothing said with it is sent.
- At finish, a wake passed on words (either tier) looks for the literal phrase,
  at the start or after a greeting, in the boosted transcript, then the plain
  one, then the second hearing (waited for even when Parakeet heard nothing).
  Found, the words after it are the command (none: Earshot waits for it, as
  after "Hey Earshot" alone). Not found, nothing of the segment is sent and
  Earshot waits for the command the same way, the chime already played. A wake
  passed on the strict score alone needs the literal phrase in the boosted
  transcript, or it is a false wake.
- wake-bench and wake-rescore count false wakes as dispatch or window, per class,
  and their end to end block runs the finish rule with Parakeet's head text as
  the boosted and plain transcript and Apple's as the second hearing (a
  stand-in: live, the finish hears the whole command).

Third safety review: the 5 mention dispatches above were "Earshot" first with no
greeting, from a mention whose start the noise gate cut off, and a session named
earshot let the boost write "earshot" over a sound-alike ("Okay, your shot. Stop
the build." became "Okay, earshot stop the blog"). Now (the numbers above are
from after this change):

- Literal is only a greeting, then the phrase written as such. "Earshot" or "ear
  shot" first with no greeting, standing apart ("Earshot, stop", "Ear shot. To
  run."), is bare: like a sound-alike, it chimes and opens the command window but
  sends nothing of its segment.
- At finish the literal tier is decided on the unboosted hearings only: the plain
  transcript (the boosted one when the boost changed nothing) and, for a wake
  passed on words, the second hearing. The command is the boosted words after the
  phrase when they have it too, else the unboosted words'. A wake passed on the
  strict score alone follows the same rule on the unboosted transcript. A wake's
  own clip is heard without names that spell the phrase ("earshot", "Earshot
  Spike", "airshot").
- After a window-only pass (bare, sound-alike, or a transcript without the
  literal phrase), the window takes only speech that starts after the chime: a
  sentence begun or said during the confirm is not the command. After "Hey
  Earshot" alone a command said during the confirm is still kept.
- The probe uses the same rule; its end to end stand-in takes Parakeet's head
  text as the unboosted transcript.

### Experiment, 2026-10-16: a second spotter term, "earshot" alone (not adopted)

The question: a noise gate that cuts the start of a wake loses the "Hey", and
the spotter's only phrase is "hey earshot". Would a second term, "earshot"
alone, with its own threshold, catch those wakes? Its fire would be window only
(it chimes and opens the command window, never sends the words said with it),
so dispatch false wakes stay 0 by construction.

Method: wake-bench now records the second term's score on the same pass of the
model (the bare column, `CtcWakeSpotter.wakeScores`; the listener does not use
it, and the phrase's scores are unchanged, 70 of 70 rows identical to the
earlier run). Run with `--confirmers apple` in 10 fresh processes of up to 1000
files: the gated positives (gate 0.2, 0.4 and 0.6, 2880), all mentions (2250), a
fixed random sample of 1500 near-misses and all of LibriSpeech (2620, 5.40 h).
`wake-rescore ... --threshold -8 --bare B` holds the phrase at -8.0 (sensitivity
5) with Apple's confirm and the listener's rule, and adds a bare fire wherever
the phrase did not fire: it passes only on Apple's words (any tier), never on no
answer, and counts as window.

The bare threshold was chosen on tune: -8.5 is the lowest where the tune
near-miss windows rise by under 1 point (33 to 42 of 968, +0.9 points; -8.75
and -9.0 are +1.0 and +1.1).

Positives woken, shipped wake against the bare term at -8.5:

| Split | Gate 0.2 | Gate 0.4 | Gate 0.6 |
|---|---|---|---|
| tune (of 640 each), shipped | 243 (38.0%) | 26 (4.1%) | 2 (0.3%) |
| tune, with "earshot" at -8.5 | 268 (41.9%) | 36 (5.6%) | 3 (0.5%) |
| holdout (of 320 each), shipped | 109 (34.1%) | 19 (5.9%) | 3 (0.9%) |
| holdout, with "earshot" at -8.5 | 119 (37.2%) | 21 (6.6%) | 3 (0.9%) |

False wakes at -8.5 against shipped: near-miss window tune 33 to 42 of 968,
holdout 17 to 22 of 532 (+0.9 points each); mention window tune 6 to 8 of 1500,
holdout 2 to 2 of 750; dispatch 0 everywhere; LibriSpeech 0.00 an hour of either
kind, but the spotter fires 253.2 times an hour instead of 142.6, so Apple's
confirm runs 78% more often on speech. Across the sweep, gate 0.4 (both splits)
goes from 45 to at most 61 of 960 (bare -9.0, near-miss tune +1.1 points) and
gate 0.6 from 5 to 6.

Decision: not adopted. The conditions the term was for barely move (gate 0.4 +10
of 640 on tune and +2 of 320 on holdout, gate 0.6 +1 and 0), for as many extra
near-miss chimes and a 78% busier confirm. The spotter is not what misses these
wakes. At -8.0 the phrase alone already fires on 412 of 960 gate 0.4 positives
and 271 of 960 gate 0.6, but only 45 and 5 wake: Apple hears the cut wake as
"your shot", "for shot" or "shot, tell ..." (no greeting, so no tier passes), or
"Earshot tell ..." with no comma (not bare), and at 0.6 the head is often the
command alone ("tell the ...", "how many ..."). A gain here would have to come
from the confirm rule, at the cost of the window false wakes those shapes
bring. The bench keeps the bare column and the sweep (tests/wake/README.md, The
bare term) to measure such a change.

Left to do: the listening power run (`scripts/listen-power.sh`, needs sudo), and
a check with a real voice in a real room (`scripts/eval-listener.sh record`).
The noise-gate conditions 0.4 and 0.6 are mostly missed; how often a real mic
does that is for the real voice check.

## Wake word bench, 2026-10-17 ("Hey Kobi")

The same method (tests/wake/README.md has the full tables): 30 voices x 122
phrases (32 positives, 62 near-misses, 18 mentions, 10 collisions) x 5
conditions, 18300 clips, a third of the voices held out, and LibriSpeech
test-clean (5.4 h). Collisions are names said the same as "Kobi" ("Hey Kobe,
run the tests", "Hey Coby, stop"): they wake, and are reported apart.

Decisions:

- The spotter scores "hey kobi" and "hey kobe" on one pass and wakes on the
  higher. Apple's recognizer wrote "Kobe" for most "Kobi"s and "Kobi" almost
  never, with or without "Kobi" as contextual text.
- Literal: a greeting (hey, hi, high, hay, hate, eight, 8, a, i, k, ok, okay),
  then "kobi", "kobe" or "koby". Window only: the name first, standing apart.
  No sound-alike tier: "Colby" won 30 tune positives for 169 near-miss windows.
- Sensitivity 5 stays at -8.0. The strict score for a wake no recognizer could
  judge goes from -5.0 to -4.0 (clean positives 52%, near-misses 2%,
  LibriSpeech 0 an hour, on the spotter alone).

At -8.0, end to end, positives that chime (tune + holdout, of 960 each), with
"Hey Earshot" at -8.0 in brackets: clean 919 (814), quiet 764 (441), gate 0.2
462 (352), gate 0.4 64 (45), gate 0.6 5 (5). Of the positives with a greeting
and a command, 97% in clean and 84% in quiet sent the command in the same
breath. Dispatch false wakes: 0 of 9300 near-misses, 0 of 2700 mentions, 0.00
an hour on LibriSpeech. Window false wakes: 13 of 9300 near-misses, 22 of 2700
mentions (20 in the gates), 0.00 an hour on LibriSpeech. Collisions woke 645
of 1500, 308 of them dispatching.

## Listening (plan 2)

Release gate: the release waits for docs/superpowers/specs/2026-10-11-listening-probe.md (the Task 0 measurements) and the Task 21 eval output (`eval-parser.sh`, `eval-listener.sh`, the latency and power runs).

### Automated, with the models downloaded

```bash
KOBI_TEST_MODELS=1 swift test --package-path app/KobiKit --filter FluidListeningTests
KOBI_TEST_FM=1 swift test --package-path app/KobiKit --filter theRealModel
KOBI_TEST_MIC=1 swift test --package-path app/KobiKit --filter recordsAboutOneSecond
bash scripts/eval-parser.sh
bash scripts/eval-listener.sh
bash scripts/send-integration.sh
```

### By hand

| Check | How | Expected |
|---|---|---|
| Hotkey command | Hold Right Option: "what's everyone doing", release | Chime, the orb pulses blue with your voice, turns violet while working, then pulses amber with the roll call |
| Tap and chord | Tap Right Option; type Option+e | Nothing: no chime, no orb |
| Wake word | Turn it on; "Hey Kobi, tell <a terminal session> to say hi" | "Sent to ..." and the terminal session answers |
| Desktop session | The same, naming a Code tab session in the Claude app | The message appears in that conversation |
| Two in one project | Two sessions in one folder; "tell <project> to run the tests" | "<Project> has two: ... Which one?", then a name works without the wake word |
| Voice approval | A session asks to run a command; after "needs your OK", say "yes" | Short sound, "Approved.", the dialog closes, the command runs |
| Late yes | Click the dialog, then say "yes" in the window | Nothing said, nothing written |
| Own voice | Play a "needs your OK" line through speakers with the wake word on | No wake, no approval |
| A call | FaceTime audio, then hold the hotkey | Nothing; the menu says another app uses the mic; lines wait for the catch-up |
| Barge-in | While Kobi reads a long roll call, hold the hotkey | It stops at once; the line is not said again |
| AirPods | Output on AirPods, wake word on | AirPods keep full quality (the built-in mic listens) |
| Sleep and lock | Lock the screen, unlock; sleep, wake | The mic closes while locked or asleep and comes back |
| Low Power Mode | Turn it on, on battery | The menu says the wake word is off in Low Power Mode; the hotkey still works |
| Start | "Start a new session in <trusted folder> to say hi" | "Started a session in ..."; `claude agents` lists it |
| Untrusted folder | Name a folder never opened in Claude | "... isn't trusted yet. Open it in Claude once first." |
| Stop | "Stop <busy session>" | "... will stop after its current step."; it stops at the next step |
| Secure input | In a password field, hold Right Option and type a character | No capture; a hold past 0.2 s plays the closed chime; the menu and the Listening settings say the hotkey is paused while another app uses secure keyboard entry |
| Orb with another app in front | Hold the hotkey while Safari or Terminal is frontmost | The orb shows at the top center |
| Orb moves | While the orb shows, drag it; next time it shows, double-click it | It stays where you dropped it and the app in front keeps focus; the double-click puts it back at the top center |
| Full screen is silent by default | Put an app in full screen; have a session finish; hold the hotkey | Nothing is said, no orb shows, the hotkey does nothing; the line plays a few seconds after you leave full screen |
| Asking in full screen | Settings, Speaking: "Answer only when I ask". In a full screen app, hold the hotkey: "what's everyone doing" | The orb shows over the full screen app and the roll call plays; a session update still waits |
| Orb color and visibility | Settings, Listening, Orb: pick Green, then hide the orb | The orb turns green on its dark glass over light and dark windows; hidden, it never shows |
| No voice, no lowering | Turn off or unplug the output while a session finishes | Other apps keep their volume; they are lowered only while Kobi's voice really plays |
| Orb with Reduce Motion | Turn on Reduce Motion in Accessibility, then hold the hotkey and speak | The orb does not turn; it only brightens and grows a little with your voice |
| Orb with VoiceOver | Turn on VoiceOver, then hold the hotkey | VoiceOver says "Listening", then "Working on it" |
| First launch prompts | On a fresh install, start the app | No Input Monitoring prompt appears before onboarding's hotkey step |
| Chimes and own lines | Play the listening chime and Kobi's own lines through the speakers with the wake word on (the own-*.wav recordings in the listener eval include one with the chime) | Never wakes it (wake 0) |
| End of speech | Say a wake command, then stop talking | About 770 ms of silence ends it (the VAD's chunking; the spec's 600 ms was ruled to 770 ms) |
| Clients that hang up early | While the app runs, run `bash tests/app-handoff.sh` | The app is still running afterwards |
| A Mac locked while a prompt is open | A session asks for an OK; lock the screen before Kobi's line ends | No window opens and the mic stays closed |
| "Hey Kobi, yes" | With a prompt open, say "Hey Kobi, yes" after its approval window closed; then trigger a second prompt and say it inside that prompt's window (just after Kobi says it) | After the window closed: Kobi says "Hold the hotkey to answer it." and the prompt stays open. Inside the second prompt's window: it approves |
| A long hotkey command | Hold the hotkey and talk for more than 10 s | The closed chime at about 10 s, then "That was too long for me. Try a shorter command."; nothing is sent; letting go does nothing |
| A session named kobi | Run a session in a folder named kobi, with the wake word on; let it ask for an OK | Its "Hey, kobi needs your OK" alert never wakes Kobi; the approval window opens after the line |
| Upgrade onboarding | Start the app as a user who finished the 0.11 onboarding | Only the mic and wake word, hotkey, models and try it steps, once |
| Diagnostics | Copy Diagnostics | Listening, models, permissions and claude path; no transcripts, no prompts |
| Menu bar panel | Click the menu bar icon | The panel shows the status line, sessions with whoever needs you first, the last four lines, and Activity, Settings, Quit |
| Replay a line | In the panel, click play on a session's last line | Kobi says it again; it is not added to the history twice |
| Activity window | Panel, Activity; pick a session in the sidebar; search for a word | Only that session's lines; search narrows them; Clear History asks first |
| History settings | Settings, General, History: Until Kobi quits, then quit and reopen | The history is empty after the restart and no history file is left |
| Mute choices | Panel, the speaker button: Mute Until I Unmute | The icon shows the slash until you unmute; the plugin's fallback voice stays quiet too |
| Activity orb | Open Activity and leave Kobi idle; then click the orb and say "what's everyone doing" | The orb turns slowly in white; the click chimes, the orb changes color while it listens, and the roll call plays |
| Plugin missing | Disable the plugin (claude plugin disable kobi@kobi), then open the panel | The panel says the plugin is turned off with a Turn On button; after it, Settings, General shows Connected |
| Plugin install on a fresh Mac | With no kobi marketplace or plugin, click Install in the welcome steps | Claude Code adds the marketplace and installs the plugin; the row shows Connected |
| Interrupted model download | Quit Kobi while the speech models download, then reopen | The panel says the download didn't finish, with Finish Download |
| Recap | Lock the screen for 10 minutes while one session finishes and another asks for an OK, then unlock | One line: "While you were away: ... needs you. ... finished." |
| Recap during a call | The same, but join a call before you unlock | Nothing until the call ends; then the recap, and the lines it named are not said again one by one |
| No recap | Lock for 5 minutes with a session finishing; or lock for 10 minutes while muted | Nothing is said when you unlock |
| Banner while muted | Mute, then have a session ask for an OK | The first time, macOS asks to allow notifications; then one banner with the session's name and the line; its reminders add no second banner; nothing is said |
| Banner click | Click the banner | The Activity window opens |
| Banner in a call or full screen | In a call, or in a full screen app, have a session ask something | One banner; a session that finishes without a question shows none |
| Banners off | Settings, Speaking: turn off the banner, mute, have a session ask for an OK | No banner |
