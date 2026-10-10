# Local voice: Kokoro by default, ElevenLabs as an option: design

Date: 2026-10-10
Status: draft, waiting for review

## Why

Earshot speaks through ElevenLabs. That needs an API key, costs about $8 a
month at list price, and sends every spoken line (summaries of your work) to a
third party. Sub-project C on the roadmap is a local voice.

## Decisions made with the user

- Engine: Kokoro-82M, run through FluidAudio (Swift, Apache 2.0, Core ML). No
  Python. Qwen3-TTS is out.
- Voice: `af_heart` on Kokoro's v3 runtime, at normal speed (1.0).
- Kokoro is the default for new setups. ElevenLabs stays as an option for
  Intel Macs, macOS before 15, and people who want a more expressive voice.
- The model stays loaded between lines, so lines are fast.

## Measurements (M5 Pro, macOS 27.0.1)

The same six Earshot lines; ElevenLabs v4 Turbo with the user's voice.

| Per line that is not cached | Kokoro v3, model loaded | Kokoro, new process | ElevenLabs |
|---|---|---|---|
| Time until the file is ready | 0.08 to 0.32 s | about 1.4 s | 0.7 to 1.1 s |
| CPU energy | about 0.7 J | about 8 J | about 0.04 J, plus Wi-Fi |
| Memory | 0.5 to 1 GB while loaded | about 1 GB while it runs | none |

- Loading v3 takes about 1.2 s and 7 J once. The first run on a Mac also
  downloads about 120 MB of models and compiles them (about 6 to 12 s).
- Stress test: 137 Earshot-style lines on v3 `af_heart`: no failures, median
  114 ms, slowest 436 ms.
- v3 failed on one sample line at speed 1.1 with
  `KokoroAneV3Error.invalidInput("Invalid audio output")`, every time. Speed
  1.0 is what we use, but the helper must handle that error.
- FluidAudio documents Core ML crashes on macOS 26.4 to 27.0. The ones that
  affect Macs are fixed or avoided in FluidAudio, but the list keeps changing.

## 1. Engines and the setting

A new config line, `EARSHOT_ENGINE`, with three values:

| Engine | Needs | Voice setting |
|---|---|---|
| `kokoro` | Apple Silicon, macOS 15 or later, the Swift tools to build the helper | `EARSHOT_KOKORO_VOICE`, default `af_heart` |
| `elevenlabs` | an API key | `EARSHOT_VOICE` (unchanged) |
| `say` | nothing | `EARSHOT_SAY_VOICE`, default: the system voice |

When `EARSHOT_ENGINE` is not set, Earshot picks `elevenlabs` if a key is saved
and `kokoro` if not. So existing installs keep ElevenLabs after the update, and
a new install with no config speaks with Kokoro once the helper is built.
Setup always writes `EARSHOT_ENGINE`, so this guess only covers configs from
before this change.

`speak.sh` no longer exits when there is no key. It exits only when the engine
is `elevenlabs` and the key or voice is missing.

## 2. The helper: `earshot-tts`

A Swift package in `tts/` (one target, one source file), pinned to FluidAudio
v0.17.7. Setup builds it, the way it builds the microphone check. One binary
does three jobs:

- `earshot-tts speak --out FILE [--voice NAME]` reads the line from stdin, so
  the text does not show up in the process list. It asks the server for the
  audio. If no server answers, it starts one in the background and waits up to
  5 seconds for it. If that fails too, it makes the line itself in this
  process. It exits 0 when FILE is a playable WAV, otherwise non-zero with one
  line on stderr.
- `earshot-tts serve` is the server. It listens on a Unix socket in Earshot's
  per-user state folder (mode 700), loads Kokoro v3 once, and warms it up with
  a long sentence, because the first long line after a short warm-up still
  took 0.6 s. Requests are handled one at a time. It exits after 10 minutes
  without a request (`EARSHOT_KOKORO_IDLE_SECS`), which gives the memory back.
  A second server that finds the socket in use exits at once.
- `earshot-tts voices` prints the English voices it can use, one per line.

When v3 throws on a line, the server retries that line once on Kokoro's legacy
runtime (loaded only then) before it reports an error. The protocol is one
line of JSON each way: `{"text": ..., "voice": ..., "out": ...}`, then
`{"ok": true}` or `{"ok": false, "error": ...}`.

The binary and FluidAudio's resource bundle go to `~/.config/earshot/kokoro/`.
Models stay in FluidAudio's cache, `~/.cache/fluidaudio/Models`.

## 3. speak.sh

The ElevenLabs block in `speak()` becomes `synth <engine> <line> <out>`, which
returns non-zero on failure. Then:

- Cache name: `md5("$MODEL $VOICE $line").mp3` for ElevenLabs (unchanged, so
  the cache stays valid), `md5("kokoro $KOKORO_VOICE $line").wav` for Kokoro,
  `md5("say $SAY_VOICE $line").aiff` for `say`. The monthly cleanup covers all
  three extensions.
- Fallbacks: if the engine fails, the line is made with `say`. If `say` fails
  too, the Basso tone plays, as before. Each failure goes to the log with the
  engine name, so a broken Kokoro does not go unnoticed. A `say` fallback is
  not cached, so the next try uses the real engine again.
- Kokoro gets 20 seconds per line, the same limit ElevenLabs has. The model
  download happens during setup, which has no limit, so hooks do not hit it.
- `say` reads the line from a file (`say -f`), not from its arguments.
- SessionStart (`begin`) starts the Kokoro server in the background, so the
  first line of a session does not wait for loading. A second session finds
  the server already running.
- Updates: like the microphone check, when `tts/` is newer than the built
  helper, a hook rebuilds it in the background. It stops the old server after a
  successful build, so the next line starts the new one. A failed build keeps
  the old helper and touches it, so the next hook does not try again.
- Test seams, the same idea as `EARSHOT_MIC`: `EARSHOT_TTS` (the helper),
  `EARSHOT_SAY` (the `say` command) and `EARSHOT_PLAYER` (`afplay`).

## 4. Setup

- `setup.sh` with no engine flag uses the saved engine, or Kokoro for a new
  setup. New flag `--engine kokoro|elevenlabs|say`.
- `--voice` sets the voice for the chosen engine: a Kokoro voice name or an
  ElevenLabs voice ID. `--list-voices` lists voices for the chosen engine.
- Kokoro setup checks for Apple Silicon and macOS 15, builds the helper with
  `swift build -c release` (about 2 minutes the first time), plays a test line
  (which downloads the models), and saves `EARSHOT_ENGINE=kokoro`. No key. If
  any step fails, it explains why, saves nothing, and suggests
  `--engine elevenlabs`.
- ElevenLabs setup works as it does today, plus `EARSHOT_ENGINE=elevenlabs`.
  Switching to Kokoro keeps the saved key, so switching back needs no new key.
- `--status` shows the engine, the voice, whether the Kokoro helper is built,
  and whether its server is running.
- `/earshot:setup` first asks for the engine: **Kokoro (Recommended)**: free,
  runs on your Mac, nothing leaves it. **ElevenLabs**: more expressive, many
  voices, needs a key, about $8 a month. For Kokoro it offers four voices:
  `af_heart` (Recommended), `af_bella`, `am_michael`, `bm_george`.

## 5. Docs and metadata

- README: the intro, Requirements, Install, Cost, Change the voice, Settings
  (`EARSHOT_ENGINE`, `EARSHOT_KOKORO_VOICE`), How it works, Troubleshooting,
  Limits, FAQ ("Do I need ElevenLabs?": no) and a privacy note: with Kokoro,
  spoken lines stay on the Mac.
- `plugin.json` and `marketplace.json`: the description names Kokoro and
  ElevenLabs; new keywords `kokoro` and `local-tts`. Version 0.9.0.
- The `setup` skill follows section 4.

## 6. Tests

- `tests/stuck-and-levels.sh` keeps passing. Its config sets
  `EARSHOT_ENGINE=elevenlabs`, so nothing changes for it.
- New `tests/engines.sh`, with stub helper, `say` and player:
  - no key and no engine means Kokoro, and lines are spoken;
  - a key and no engine means ElevenLabs. A new internal mode,
    `speak.sh engine`, prints the engine it would use, so the test makes no
    network request;
  - Kokoro fails, so the line is made with `say`, and the log names Kokoro;
  - Kokoro and `say` both fail, so the Basso tone plays;
  - a `say` fallback is not cached;
  - the Kokoro and ElevenLabs cache names differ for the same line.
- `tests/kokoro-smoke.sh` (needs the built helper and models, not part of the
  quick suite): starts a server, speaks three lines, checks the WAV files, kills
  the server in the middle of a request and checks that `speak` still returns a
  file.

## 7. After release, on this Mac

The installed plugin is 0.7.0, from this folder, and the config has an
ElevenLabs key, so it speaks with ElevenLabs. After 0.9.0: update the plugin
from the folder, then run `setup.sh --engine kokoro --voice af_heart`.

## Not in this change

- Streaming playback while Kokoro generates (lines are ready in under 0.4 s).
- Other local models with emotion tags (Chatterbox, Orpheus).
- A prebuilt, signed helper download instead of building on the Mac.
- Kokoro voices in other languages.
