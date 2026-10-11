# Earshot for Mac, plan 2: listening and commands Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Earshot for Mac hears "Hey Earshot" or a held hotkey, turns what you say into one of four commands (send, status, stop, start) or a yes/no answer to a permission prompt, carries it out in the right Claude Code session, and says what it did.

**Architecture:** Every non-UI part goes into `EarshotKit` behind small protocols, so the logic is tested with fakes and `swift test`. The `Listener` actor runs the cascade (energy gate, Silero VAD, a CTC keyword spotter once per speech segment, Parakeet TDT on the finished clip). `CommandParser` tries a fixed grammar first and Apple's on-device Foundation Model second. `SessionDirectory` merges `claude agents --json` with the plugin's status messages and the spoken names. `Dispatcher` writes to `/tmp/cc-socks/<pid>.sock` or runs `claude`, and `VoiceLoop` ties them to `SpeechOut`. The app target adds the hotkey event tap, the orb panel, settings and onboarding.

**Tech Stack:** Swift 6.4 toolchain (language mode 6), macOS 26 SDK features (deployment target 26.0), Swift Testing, FluidAudio 0.17.7 (Silero VAD, Parakeet CTC 110M keyword spotting, Parakeet TDT v2, vocabulary boosting), FoundationModels, AVFoundation, Core Audio, CoreGraphics event taps, SwiftUI and AppKit, bash for scripts.

**Spec:** `docs/superpowers/specs/2026-10-11-mac-app-design.md` (sections 2, 3, 4, 5 "Sending into sessions" and "Hearing", 6 "First launch", 7, 8 items 1, 7, 8, 9) and `docs/superpowers/specs/2026-10-11-voice-approvals-design.md` ("The app side"). Plan 1 (`docs/superpowers/plans/2026-10-11-mac-app-playback.md`) is done and merged; this plan builds on its code.

**Checked while planning:** applying every task's code to a copy of main (3eb2c4a plus the plugin move) builds the package, the probe and the app, and passes 235 tests with the opt-in hardware and model tests skipped. The opt-in tests and the evals (Tasks 0, 9, 11, 18, 21) need the user's Mac, mic and models and were not run.

**Repo layout note:** since plan 1, the plugin lives in `plugin/` (`plugin/scripts/speak.sh`, `plugin/hooks/hooks.json`, `plugin/skills/`, `plugin/tts/`). `scripts/` at the root holds `release-app.sh` and two forwarders. Plugin tests stay in `tests/`.

## Global Constraints

- macOS 26 or later for the app (`platforms: [.macOS(.v26)]`, deployment target 26.0). Swift language mode 6 for `EarshotKit` and the app.
- App socket protocol version stays 1: `~/Library/Application Support/Earshot/earshot.sock`, mode 0600, one JSON object per line, field `"v": 1`. New message type: `approval`.
- Session sockets: `/tmp/cc-socks/<pid>.sock`. Each message is one line: `{"type":"user","from":"earshot","session_id":"<uuid>","priority":"next|now","message":{"role":"user","content":"<text>"}}`. `session_id` is always set. `from` is always `"earshot"`.
- Earshot never sends approvals or settings changes through a session socket. Voice approvals go only through the answer file of the `decide` hook.
- Audio stays in memory: a ring buffer of about 10 seconds. It is never written to disk and never leaves the Mac. The only exception is `earshot-probe record`, a developer tool the user runs by hand.
- Transcripts and prompt text never go into the event log, the unified log at `.public`, or "Copy Diagnostics".
- Latency target: end of speech to the start of the spoken confirmation, p50 under 1 s and p95 under 1.5 s over 20 hotkey commands.
- End of speech: 600 ms of silence after speech. Wake word then silence: closing chime after 8 s. Follow-up windows (approval, "which one?"): 6 s. A hotkey hold shorter than 0.2 s, or with another key pressed during the hold, does nothing.
- Receipt timeout for an idle session: 5 s. Two misses in a row mark socket sending broken for that Claude Code version.
- "Last spoke about" counts for 2 minutes. Unknown target lists at most 3 open sessions.
- Ducking while listening uses the same level and fades as speaking (default 30%, 200 ms).
- Transcription and Kokoro unload after 10 idle minutes and on a memory pressure warning. The VAD and the keyword spotter stay loaded while the wake word may listen.
- Config file `~/.config/earshot/config`, shell `KEY=value` lines, mode 0600, shared with the plugin. New keys are listed in Task 3.
- Copy rules: no em dashes anywhere (code comments, UI text, spoken lines, docs). Plain wording.
- Bundle ID `com.earshot.app`, Team ID `8N9KUZLT8N`, unified log subsystem `com.earshot.app`.

## Review Focus

- **Earshot hears itself.** A line Earshot speaks must not wake it and must not answer a prompt. The approval window opens only after the line has finished playing, and the eval set includes Earshot's own lines through the speakers. Pinned in Task 17 (`approvalWindowOpensOnlyAfterTheLineFinished`) and Task 21 (own-lines eval, 0 wakes).
- **A late "yes".** You click the dialog while the 6 s window is open, then say "yes": nothing is written and nothing is said. Pinned in Task 2 (`answerAfterCloseWritesNothing`) and Task 17 (`yesAfterTheDialogClosedSaysNothing`).
- **Right Option as a normal key.** Some keyboard layouts type characters with Right Option. A chord or a tap must never chime, duck, open the mic or send. Pinned in Task 6 (`chordCancels`, `tapIsIgnored`) and Task 7 (`aShortHoldNeverChimes`).
- **A call starts mid-command.** Another app opens the mic while Earshot captures a command: the capture is dropped, nothing is sent, and the mic closes. Pinned in Task 7 (`aCallDropsTheCapture`).
- **A misheard or empty command is never sent.** "Tell billing to" with nothing after it, noise, or an unmatched sentence with the model unavailable gives "Sorry, I didn't get that." and sends nothing. Pinned in Task 10 (`emptyPromptIsNoCommand`) and Task 16 (`unknownCommandSendsNothing`).

## Deviations from the spec (decided while planning)

- **Transcription is batch, not streaming.** FluidAudio's streaming engines either have no vocabulary boosting (`StreamingEouAsrManager`, English `StreamingNemotronAsrManager`) or wait about 2 s per chunk (`StreamingUnifiedAsrManager`). The Listener keeps the whole command in the ring buffer anyway, so after end of speech it runs `AsrManager` (TDT v2, English) once on the clip, then `VocabularyBoostingSession.rescore` with the live session names. Task 0 measures this; the budget is 150 ms for an 8 s clip.
- **The wake word spotter runs once per speech segment.** FluidAudio has no wake word API. `CtcKeywordSpotter` pads every call to a 15 s encoder pass, so it runs once per speech segment: when the segment reaches 1.5 s, or when it ends, whichever is first. Task 0 measures the cost; if it is over budget the plan stops there (see Task 0, step 7).
- **Receipts come from the existing status message.** The plugin already sends `status` with `state: "working"` from its `UserPromptSubmit` hook, which fires for injected prompts (spike notes). That is the receipt, with `claude agents --json` showing the session `busy` as the second source (it works with `/voice` off). No `prompt` message and no plugin change.
- **The ElevenLabs key stays in the config file.** Plan 1 deferred the Keychain move; it is still out of scope here, because it needs a Keychain access list for `/usr/bin/security` and is unrelated to listening. It gets its own small plan.
- **The wake word is off until you turn it on** (in onboarding or Settings). An always-open mic should be a choice. The hotkey is on by default (hold Right Option).
- **Start finds folders in `~/.claude.json`.** Its `projects` object lists every folder Claude Code knows, with `hasTrustDialogAccepted`. Live session folders are added to it.
- **A new line kind, `confirm`,** for Earshot's own answers ("Sent to billing service."). App only. It goes to the front of the queue, is never held, and is dropped during a call.
- **FluidAudio's listening models live in `~/Library/Application Support/FluidAudio/Models`** (VAD `silero-vad`, keyword spotter `parakeet-ctc-110m-coreml`, transcription `parakeet-tdt-0.6b-v2`). Kokoro's stay in `~/.cache/fluidaudio`.
- **App Nap** is disabled while the mic is open (wake word armed or capturing) and while speaking, because a napping process delays the audio processing task.

## File map

```
app/EarshotKit/
  Package.swift                              + executable target earshot-probe
  Sources/earshot-probe/main.swift           Task 0: measure the listening cascade (new)
  Sources/EarshotKit/
    Protocol/AppMessage.swift                + approval messages (modified)
    Core/ApprovalBook.swift                  open prompts, answer files (new)
    Core/EarshotCore.swift                   approvals, canListen (modified)
    Config/EarshotConfig.swift               + listening keys (modified)
    Listen/SampleRing.swift                  10 s ring buffer, energy gate (new)
    Listen/ListenPolicy.swift                when the mic may open, menu reasons (new)
    Listen/HotkeyDetector.swift              hold, release, chord, tap (new)
    Listen/Listener.swift                    the cascade state machine (new)
    Listen/ListenParts.swift                 protocols: AudioInput, SpeechGate, WakeSpotter, Transcriber, Chimes (new)
    Listen/MicInput.swift                    AVAudioEngine 16 kHz mono input, device choice (new)
    Listen/FluidListening.swift              Silero gate, CTC spotter, Parakeet transcriber, model store (new)
    Listen/SystemChimes.swift                listening, closed, confirm sounds (new)
    Listen/SystemWatch.swift                 lock, sleep, battery, Low Power Mode (new)
    Speech/SpeechOut.swift                   listening pause, confirm lines, line events (modified)
    Protocol/AppMessage.swift (LineKind)     + confirm (modified)
    Commands/Command.swift                   the Command type (new)
    Commands/Grammar.swift                   fixed grammar, approval words (new)
    Commands/CommandParser.swift             grammar, then Foundation Model (new)
    Sessions/ClaudeCLI.swift                 find and run claude, agents JSON (new)
    Sessions/SpokenNames.swift               project names, labels, shortest unique name (new)
    Sessions/Labeler.swift                   model labels, live file line 3 (new)
    Sessions/SessionDirectory.swift          merged live sessions, matching, known folders (new)
    Sessions/RollCall.swift                  the roll call text (new)
    Sessions/SessionTransport.swift          /tmp/cc-socks writer (new)
    Commands/Dispatcher.swift                the four commands and answers (new)
    Core/VoiceLoop.swift                     ties listener, parser, dispatcher, speech (new)
    Core/ListenStack.swift                   builds the live listening stack (new)
  Tests/EarshotKitTests/                     one test file per new source file
app/Earshot/
  HotkeyTap.swift                            CGEventTap for the hotkey (new)
  OrbPanel.swift                             floating panel while listening or speaking (new)
  AppModel.swift, MenuContent.swift, SettingsView.swift, OnboardingView.swift (modified)
  Earshot.entitlements                       + audio input (modified)
app/project.yml                              + NSMicrophoneUsageDescription (modified)
scripts/
  listen-power.sh                            powermetrics for the probe and the app (new)
  latency.sh                                 p50/p95 from the app's latency log (new)
  eval-parser.sh, eval-listener.sh           model and audio evals (new)
  send-integration.sh                        real sessions receive a dispatched prompt (new)
tests/
  app-e2e.md                                 listening checks (modified)
  eval/parser-cases.tsv                      100 transcripts and expected commands (new)
docs/superpowers/specs/
  2026-10-11-listening-probe.md              Task 0 results (new)
```

---
### Task 0: Measure the listening cascade (decision gate)

The spec's biggest unknown is the cost of keeping the wake word on. This task builds a small command line tool on the real FluidAudio models, measures the cascade on this Mac, and writes the numbers down. Every later task assumes the numbers pass. If they do not, stop at step 7.

**Files:**
- Modify: `app/EarshotKit/Package.swift`
- Create: `app/EarshotKit/Sources/earshot-probe/main.swift`
- Create: `scripts/listen-power.sh`
- Create: `docs/superpowers/specs/2026-10-11-listening-probe.md`

**Interfaces:**
- Produces: `swift run --package-path app/EarshotKit -c release earshot-probe <command>` with `record SECS OUT.wav`, `spot WAV...`, `transcribe WAV [TERM...]`, `listen MINUTES`. Task 21's evals call `spot` and `transcribe`.

- [ ] **Step 1: Add the executable target**

In `app/EarshotKit/Package.swift`, replace the `products` and `targets` lists:

```swift
    products: [
        .library(name: "EarshotKit", targets: ["EarshotKit"]),
        .executable(name: "earshot-probe", targets: ["earshot-probe"]),
    ],
```

```swift
    targets: [
        .target(name: "EarshotKit", dependencies: [.product(name: "FluidAudio", package: "FluidAudio")]),
        .executableTarget(name: "earshot-probe", dependencies: [.product(name: "FluidAudio", package: "FluidAudio")]),
        .testTarget(name: "EarshotKitTests", dependencies: ["EarshotKit"]),
    ]
```

- [ ] **Step 2: Write the probe**

`app/EarshotKit/Sources/earshot-probe/main.swift`:

```swift
// earshot-probe: measures Earshot's listening cascade on this Mac (plan 2, task 0).
//   record SECS OUT.wav      records the mic at 16 kHz mono, for evals
//   spot WAV...              VAD, then the keyword spotter once per speech segment
//   transcribe WAV [TERM...] Parakeet TDT v2, then vocabulary rescoring with TERMs
//   listen MINUTES           the live cascade on the mic, with CPU use per minute
import AVFoundation
import Darwin
@preconcurrency import FluidAudio
import Foundation

let wakePhrase = "hey earshot"
let segmentSpotAt = 24_000          // 1.5 s: spot a segment this long, or when it ends
let spotWindow = 32_000             // the first 2 s of a segment
let energyThreshold: Float = 0.008  // RMS; below it the VAD does not run

@main struct Probe {
    static func main() async throws {
        let a = Array(CommandLine.arguments.dropFirst())
        switch a.first {
        case "record" where a.count == 3: try await record(seconds: Double(a[1]) ?? 5, to: URL(fileURLWithPath: a[2]))
        case "spot" where a.count >= 2: try await spot(a.dropFirst().map { URL(fileURLWithPath: $0) })
        case "transcribe" where a.count >= 2: try await transcribe(URL(fileURLWithPath: a[1]), terms: Array(a.dropFirst(2)))
        case "listen": try await listen(minutes: Double(a.count > 1 ? a[1] : "5") ?? 5)
        default:
            print("usage: earshot-probe record SECS OUT.wav | spot WAV... | transcribe WAV [TERM...] | listen MINUTES")
            exit(2)
        }
    }
}

// MARK: - Helpers

func ms(_ start: ContinuousClock.Instant) -> Int {
    let d = ContinuousClock.now - start
    return Int(d.components.seconds * 1000 + d.components.attoseconds / 1_000_000_000_000_000)
}

func cpuSeconds() -> Double {
    var u = rusage()
    getrusage(RUSAGE_SELF, &u)
    return Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec) + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1e6
}

func rms(_ s: ArraySlice<Float>) -> Float {
    guard !s.isEmpty else { return 0 }
    return (s.reduce(0) { $0 + $1 * $1 } / Float(s.count)).squareRoot()
}

/// The mic as 16 kHz mono Float chunks.
func micStream() throws -> (AVAudioEngine, AsyncStream<[Float]>) {
    let engine = AVAudioEngine()
    let input = engine.inputNode
    let converter = AudioConverter()
    let (stream, cont) = AsyncStream<[Float]>.makeStream()
    input.installTap(onBus: 0, bufferSize: 4096, format: input.outputFormat(forBus: 0)) { buffer, _ in
        if let s = try? converter.resampleBuffer(buffer) { cont.yield(s) }
    }
    try engine.start()
    return (engine, stream)
}

struct Spotter {
    let spotter: CtcKeywordSpotter
    let vocab: CustomVocabularyContext

    static func load() async throws -> Spotter {
        let models = try await CtcModels.downloadAndLoad(variant: .ctc110m)
        let tokenizer = try await CtcTokenizer.load(from: CtcModels.defaultCacheDirectory(for: .ctc110m))
        let term = CustomVocabularyTerm(text: wakePhrase, ctcTokenIds: tokenizer.encode(wakePhrase))
        return Spotter(spotter: CtcKeywordSpotter(models: models, blankId: models.vocabulary.count),
                       vocab: CustomVocabularyContext(terms: [term]))
    }

    /// The best score for the wake phrase, or nil when it was not found.
    func score(_ samples: [Float]) async throws -> Float? {
        let r = try await spotter.spotKeywordsWithLogProbs(audioSamples: samples, customVocabulary: vocab, minScore: -30)
        return r.detections.map(\.score).max()
    }
}

/// Energy gate and VAD over a sample stream. Calls `onSegment` once per speech
/// segment with its first 2 s, at 1.5 s or at its end.
actor Segmenter {
    let vad: VadManager
    var state: VadStreamState
    var pending: [Float] = []
    var all: [Float] = []
    var segmentStart: Int?
    var spotted = false
    var vadRuns = 0
    var quietChunks = 0
    let config = VadSegmentationConfig(minSilenceDuration: 0.6)

    init(vad: VadManager) async {
        self.vad = vad
        state = await vad.makeStreamState()
    }

    func feed(_ samples: [Float], onSegment: ([Float]) async -> Void) async throws {
        pending += samples
        while pending.count >= VadManager.chunkSize {
            let chunk = Array(pending.prefix(VadManager.chunkSize))
            pending.removeFirst(VadManager.chunkSize)
            all += chunk
            if all.count > 160_000 {   // keep about 10 s
                let drop = all.count - 160_000
                all.removeFirst(drop)
                if let s = segmentStart { segmentStart = max(0, s - drop) }
            }
            // The energy gate: quiet chunks skip the VAD, unless a segment is open.
            if rms(chunk[...]) < energyThreshold && segmentStart == nil {
                quietChunks += 1
                if quietChunks == 8 { state = await vad.makeStreamState() }
                continue
            }
            quietChunks = 0
            vadRuns += 1
            let r = try await vad.processStreamingChunk(chunk, state: state, config: config)
            state = r.state
            if r.event?.kind == .speechStart { segmentStart = max(0, all.count - VadManager.chunkSize * 2); spotted = false }
            if let s = segmentStart, !spotted, all.count - s >= segmentSpotAt || r.event?.kind == .speechEnd {
                spotted = true
                await onSegment(Array(all[s..<min(all.count, s + spotWindow)]))
            }
            if r.event?.kind == .speechEnd { segmentStart = nil }
        }
    }
}

// MARK: - Commands

func record(seconds: Double, to url: URL) async throws {
    let (engine, stream) = try micStream()
    var samples: [Float] = []
    let target = Int(seconds * 16_000)
    print("Recording \(seconds) s...")
    for await chunk in stream {
        samples += chunk
        if samples.count >= target { break }
    }
    engine.stop()
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
    buffer.frameLength = AVAudioFrameCount(samples.count)
    samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    try file.write(from: buffer)
    print("Wrote \(url.path)")
}

func spot(_ files: [URL]) async throws {
    var t = ContinuousClock.now
    let vad = try await VadManager()
    let spotter = try await Spotter.load()
    print("models loaded in \(ms(t)) ms")
    for url in files {
        let samples = try AudioConverter().resampleAudioFile(url)
        let seg = await Segmenter(vad: vad)
        var calls: [Int] = []
        var best: Float?
        try await seg.feed(samples + [Float](repeating: 0, count: 8 * VadManager.chunkSize)) { window in
            t = ContinuousClock.now
            let s = try? await spotter.score(window)
            calls.append(ms(t))
            if let s { best = max(best ?? -.infinity, s) }
        }
        print("\(url.lastPathComponent)\tsegments=\(calls.count)\tbest=\(best.map { String(format: "%.1f", $0) } ?? "none")\tms=\(calls)")
    }
}

func transcribe(_ url: URL, terms: [String]) async throws {
    var t = ContinuousClock.now
    let models = try await AsrModels.downloadAndLoad(version: .v2)
    let asr = AsrManager(config: .default)
    try await asr.loadModels(models)
    let ctc = try await CtcModels.downloadAndLoad(variant: .ctc110m)
    print("models loaded in \(ms(t)) ms")
    let samples = try AudioConverter().resampleAudioFile(url)
    for run in 1...3 {
        t = ContinuousClock.now
        var state = TdtDecoderState.make()
        let result = try await asr.transcribe(samples, decoderState: &state)
        let asrMs = ms(t)
        var text = result.text
        if !terms.isEmpty, let timings = result.tokenTimings {
            t = ContinuousClock.now
            let session = try await VocabularyBoostingSession(
                vocabulary: CustomVocabularyContext(terms: terms.map { CustomVocabularyTerm(text: $0) }), ctcModels: ctc)
            if let out = await session.rescore(text: text, tokenTimings: timings, audioSamples: samples) { text = out.text }
            print("run \(run): asr \(asrMs) ms, rescore \(ms(t)) ms: \(text)")
        } else {
            print("run \(run): asr \(asrMs) ms: \(text)")
        }
    }
}

func listen(minutes: Double) async throws {
    let vad = try await VadManager()
    let spotter = try await Spotter.load()
    let seg = await Segmenter(vad: vad)
    let (engine, stream) = try micStream()
    print("Listening for \(minutes) min. Say \"Hey Earshot\" now and then.")
    let end = Date().addingTimeInterval(minutes * 60)
    var minuteStart = Date(), cpuStart = cpuSeconds()
    var segments = 0, wakes = 0, spotMs: [Int] = []
    for await chunk in stream {
        try await seg.feed(chunk) { window in
            segments += 1
            let t = ContinuousClock.now
            let s = try? await spotter.score(window)
            spotMs.append(ms(t))
            if let s, s > -15 { wakes += 1; print("  wake (score \(String(format: "%.1f", s)))") }
        }
        if Date().timeIntervalSince(minuteStart) >= 60 {
            let cpu = (cpuSeconds() - cpuStart) / Date().timeIntervalSince(minuteStart) * 100
            let runs = await seg.vadRuns
            print(String(format: "minute: cpu %.1f%%, vad runs %d, segments %d, wakes %d, spot ms max %d",
                         cpu, runs, segments, wakes, spotMs.max() ?? 0))
            minuteStart = Date(); cpuStart = cpuSeconds()
        }
        if Date() > end { break }
    }
    engine.stop()
}
```

- [ ] **Step 3: Build it**

Run: `swift build --package-path app/EarshotKit -c release --product earshot-probe`
Expected: builds. If a FluidAudio call does not compile, check its signature in `app/EarshotKit/.build/checkouts/FluidAudio/Sources/FluidAudio` (the spotter in `ASR/Parakeet/SlidingWindow/CustomVocabulary/WordSpotting/`, the TDT manager in `ASR/Parakeet/SlidingWindow/TDT/AsrManager.swift`) and fix the call, not the behavior.

- [ ] **Step 4: Write the power script**

`scripts/listen-power.sh`:

```bash
#!/bin/bash
# listen-power.sh <process name> [minutes]: Energy Impact and CPU of one
# process from powermetrics, one sample every 5 seconds. Needs sudo.
# Run it next to "earshot-probe listen" or the app with the wake word on.
name=${1:?process name, e.g. earshot-probe or Earshot}; mins=${2:-5}
n=$(( mins * 12 ))
sudo powermetrics --samplers tasks --show-process-energy -i 5000 -n "$n" 2>/dev/null \
  | awk -v name="$name" '
      $0 ~ name { cpu += $3; energy += $NF; samples++ }
      END { if (samples) printf "%s: %d samples, mean CPU %.1f ms/s, mean energy impact %.2f\n", name, samples, cpu / samples, energy / samples
            else print "no samples for " name }'
```

Run: `chmod +x scripts/listen-power.sh`

- [ ] **Step 5: Measure (the user runs the mic parts)**

Ask the user to run these and paste the output. Each needs the mic, and the first run downloads about 1 GB of models.

```bash
P="swift run --package-path app/EarshotKit -c release earshot-probe"
$P record 3 /tmp/wake-1.wav        # say "Hey Earshot, what's everyone doing?"
$P record 3 /tmp/wake-2.wav        # say "Hey Earshot, tell billing service to run the tests"
$P record 3 /tmp/no-wake.wav       # say "Hey, are you there? I'll be right back"
$P spot /tmp/wake-1.wav /tmp/wake-2.wav /tmp/no-wake.wav
$P transcribe /tmp/wake-2.wav "billing service" finebrief earshot
$P listen 10                       # 5 quiet minutes, then 5 with talk or a video playing
```

In a second terminal during `listen`: `bash scripts/listen-power.sh earshot-probe 10`.

- [ ] **Step 6: Record the results and check the budgets**

Write `docs/superpowers/specs/2026-10-11-listening-probe.md` with the date, the Mac model, each command's output, and this table filled in:

| Budget | Limit | Measured | Pass |
|---|---|---|---|
| CPU, quiet room | under 2% | | |
| CPU, people talking or a video | under 10% | | |
| Energy impact, quiet room | "Low" (under 5 in powermetrics) | | |
| One spotter call | under 80 ms | | |
| Transcription of a 3 s clip | under 150 ms | | |
| Vocabulary rescoring | under 60 ms | | |
| Wake phrase recordings with a score above -15 | 2 of 2 | | |
| `no-wake.wav` above -15 | 0 | | |
| False wakes during 5 minutes of talk or video | 0 | | |

The -15 line is the spotter's default threshold (`ContextBiasingConstants.defaultMinSpotterScore`); Task 18 maps the sensitivity slider around it, so also note the lowest score of a real wake and the highest score of a non-wake.

- [ ] **Step 7: Decide**

If every row passes, commit and go on to Task 1.

If the spotter is over budget or misses, stop here and tell the user, with the numbers. The fallback is a small dedicated wake word model on the Neural Engine, which needs its own short spec. Tasks 1 to 17 do not depend on the spotter and can still be built; Task 18 cannot.

If only transcription is over budget, try `AsrModelVersion.phonon2` (English) in `transcribe`, record both, and use the faster one in Task 18.

- [ ] **Step 8: Commit**

```bash
git add app/EarshotKit/Package.swift app/EarshotKit/Sources/earshot-probe scripts/listen-power.sh docs/superpowers/specs/2026-10-11-listening-probe.md
git commit -m "Probe: what the listening cascade costs on this Mac"
```

---
### Task 1: Approval messages and the confirm line kind

**Files:**
- Modify: `app/EarshotKit/Sources/EarshotKit/Protocol/AppMessage.swift`
- Test: `app/EarshotKit/Tests/EarshotKitTests/AppMessageTests.swift`

**Interfaces:**
- Produces: `AppMessage.approval(AppMessage.Approval)`; `AppMessage.Approval` with `session`, `id`, `state: String?`, `by: String?`, `name: String?`, `what: String?`, `answer: String?`, `secret: String?`, `pid: Int32?`, `sent: Double?`, and `isClosed: Bool`. `LineKind.confirm` (not held, catch-up rank 2).

- [ ] **Step 1: Write the failing tests**

Append to `AppMessageTests`:

```swift
    @Test func decodesAnOpenApproval() throws {
        let m = try decode(#"{"v":1,"type":"approval","session":"s1","id":"1790000000-123-456","name":"billing service","what":"to run the migration","answer":"/t/earshot/answer-s1-1790000000-123-456","secret":"0123456789abcdef0123456789abcdef","pid":123,"sent":1790000000000}"#)
        guard case .approval(let a) = m else { Issue.record("not an approval"); return }
        #expect(a.session == "s1")
        #expect(a.id == "1790000000-123-456")
        #expect(a.name == "billing service")
        #expect(a.what == "to run the migration")
        #expect(a.secret == "0123456789abcdef0123456789abcdef")
        #expect(a.pid == 123)
        #expect(!a.isClosed)
    }

    @Test func decodesAClosedApproval() throws {
        let m = try decode(#"{"v":1,"type":"approval","session":"s1","id":"x","state":"closed","by":"screen"}"#)
        guard case .approval(let a) = m else { Issue.record("not an approval"); return }
        #expect(a.isClosed)
        #expect(a.by == "screen")
        #expect(a.secret == nil)
    }

    @Test func confirmLinesAreNeverHeld() {
        #expect(!LineKind.confirm.isHeld)
        #expect(LineKind.confirm.catchUpRank == 2)
    }
```

- [ ] **Step 2: Run them to see them fail**

Run: `swift test --package-path app/EarshotKit --filter AppMessageTests`
Expected: FAIL to compile: `approval` and `confirm` are not members.

- [ ] **Step 3: Add the kind and the message**

In `LineKind`, add the case (keep the doc comment style):

```swift
public enum LineKind: String, Codable, Sendable, CaseIterable {
    /// confirm: Earshot's own answer to a voice command. App only.
    case need, reply, alert, done, beat, ack, roll, intro, confirm
```

`isHeld` and `catchUpRank` already return `false` and `2` for it through their `default` branches.

In `AppMessage`, add the case and the struct:

```swift
    case approval(Approval)
```

```swift
    /// A permission prompt the plugin's decide hook waits on, or its end.
    /// See docs/superpowers/specs/2026-10-11-voice-approvals-design.md.
    public struct Approval: Codable, Sendable, Equatable {
        public var session: String
        public var id: String
        /// nil while the prompt is open, "closed" when it ended.
        public var state: String?
        /// How it ended: voice, screen, timeout or unclaimed.
        public var by: String?
        public var name: String?
        public var what: String?
        /// The file the app writes "allow <secret>" or "deny <secret>" to.
        public var answer: String?
        public var secret: String?
        /// The waiting hook, to check it still runs.
        public var pid: Int32?
        public var sent: Double?

        public init(session: String, id: String, state: String? = nil, by: String? = nil, name: String? = nil,
                    what: String? = nil, answer: String? = nil, secret: String? = nil, pid: Int32? = nil,
                    sent: Double? = nil) {
            self.session = session; self.id = id; self.state = state; self.by = by; self.name = name
            self.what = what; self.answer = answer; self.secret = secret; self.pid = pid; self.sent = sent
        }

        public var isClosed: Bool { state == "closed" }
    }
```

In `decode`, add the branch before `default`:

```swift
        case "approval":
            guard let a = try? d.decode(Approval.self, from: line) else { throw .badMessage }
            return .approval(a)
```

- [ ] **Step 4: Make the core compile again**

`EarshotCore.start()` switches over `AppMessage`. Add a branch that ignores approvals for now (Task 2 replaces it):

```swift
                case .approval:
                    break
```

- [ ] **Step 5: Run the tests**

Run: `swift test --package-path app/EarshotKit`
Expected: PASS, all suites.

- [ ] **Step 6: Commit**

```bash
git add app/EarshotKit/Sources/EarshotKit/Protocol/AppMessage.swift app/EarshotKit/Sources/EarshotKit/Core/EarshotCore.swift app/EarshotKit/Tests/EarshotKitTests/AppMessageTests.swift
git commit -m "Protocol: approval messages, and a confirm kind for Earshot's own answers"
```

---

### Task 2: ApprovalBook, and the core takes approvals

The app keeps the prompts the plugin's `decide` hook waits on and writes the answer file. It takes a new prompt only when it can listen now; it applies a `closed` message however late it is.

**Files:**
- Create: `app/EarshotKit/Sources/EarshotKit/Core/ApprovalBook.swift`
- Modify: `app/EarshotKit/Sources/EarshotKit/Core/EarshotCore.swift`
- Test: `app/EarshotKit/Tests/EarshotKitTests/ApprovalBookTests.swift`
- Test: `app/EarshotKit/Tests/EarshotKitTests/CoreTests.swift`

**Interfaces:**
- Consumes: `AppMessage.Approval` (Task 1).
- Produces:
  - `public struct OpenApproval: Sendable, Equatable` with `session`, `id`, `name`, `what`, `answerPath`, `pid: Int32?`, `opened: Date`.
  - `public actor ApprovalBook` with `init(stateDir: String = ApprovalBook.defaultStateDir, isAlive: @escaping @Sendable (Int32) -> Bool = ApprovalBook.processRuns, clock: @escaping @Sendable () -> Date = Date.init)`, `func apply(_ a: AppMessage.Approval) -> Bool`, `var current: [OpenApproval]` (oldest first), `func latest(session: String) -> OpenApproval?`, `func isOpen(_ id: String) -> Bool`, `func answer(_ id: String, allow: Bool) -> ApprovalBook.AnswerResult` (`.written`, `.closed`, `.failed`), `func changes() -> AsyncStream<[OpenApproval]>`.
  - `public final class ListenAvailability: Sendable` with `var canListen: Bool` (lock protected), set by the app.
  - `EarshotCore.init(socketPath:speech:sessions:events:approvals:availability:)`; `EarshotCore.approvals`.

- [ ] **Step 1: Write the failing tests**

`app/EarshotKit/Tests/EarshotKitTests/ApprovalBookTests.swift`:

```swift
import Darwin
import Foundation
import Testing
@testable import EarshotKit

@Suite struct ApprovalBookTests {
    let dir: String = {
        let d = NSTemporaryDirectory() + "ek-approvals-\(UUID().uuidString.prefix(6))"
        try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
        return d
    }()
    let secret = "0123456789abcdef0123456789abcdef"

    func message(_ id: String = "1790000000-1-2", session: String = "s1", pid: Int32? = 77) -> AppMessage.Approval {
        .init(session: session, id: id, name: "billing service", what: "to run the migration",
              answer: "\(dir)/answer-\(session)-\(id)", secret: secret, pid: pid)
    }

    func book(alive: Bool = true) -> ApprovalBook { ApprovalBook(stateDir: dir, isAlive: { _ in alive }) }

    @Test func keepsAnOpenPromptAndWritesTheAnswer() async throws {
        let b = book()
        #expect(await b.apply(message()))
        #expect(await b.current.map(\.id) == ["1790000000-1-2"])
        #expect(await b.answer("1790000000-1-2", allow: true) == .written)
        let path = "\(dir)/answer-s1-1790000000-1-2"
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "allow \(secret)\n")
        var st = stat()
        stat(path, &st)
        #expect(st.st_mode & 0o777 == 0o600)
        #expect(await b.current.isEmpty)   // answered once
    }

    @Test func denyWritesDeny() async throws {
        let b = book()
        _ = await b.apply(message())
        #expect(await b.answer("1790000000-1-2", allow: false) == .written)
        #expect(try String(contentsOfFile: "\(dir)/answer-s1-1790000000-1-2", encoding: .utf8) == "deny \(secret)\n")
    }

    @Test func answerAfterCloseWritesNothing() async {
        let b = book()
        _ = await b.apply(message())
        _ = await b.apply(.init(session: "s1", id: "1790000000-1-2", state: "closed", by: "screen"))
        #expect(await b.answer("1790000000-1-2", allow: true) == .closed)
        #expect(!FileManager.default.fileExists(atPath: "\(dir)/answer-s1-1790000000-1-2"))
    }

    /// The closed message can overtake the open one (both are sent in the
    /// background). The prompt must not come back.
    @Test func aLateOpenAfterItsCloseIsRefused() async {
        let b = book()
        _ = await b.apply(.init(session: "s1", id: "1790000000-1-2", state: "closed", by: "screen"))
        #expect(await b.apply(message()) == false)
        #expect(await b.current.isEmpty)
    }

    @Test func refusesAnAnswerPathOutsideTheStateFolder() async {
        let b = book()
        var m = message()
        m.answer = "/tmp/answer-s1-1790000000-1-2"
        #expect(await b.apply(m) == false)
        m = message()
        m.answer = "\(dir)/../answer-s1-1790000000-1-2"
        #expect(await b.apply(m) == false)
    }

    @Test func refusesABadSecretOrUnsafeNames() async {
        let b = book()
        var m = message()
        m.secret = "short"
        #expect(await b.apply(m) == false)
        #expect(await b.apply(message("../x")) == false)
        #expect(await b.apply(message(session: "a/b")) == false)
    }

    /// A hook killed with SIGKILL never sends closed: its prompt goes once
    /// its process is gone.
    @Test func aPromptWhoseHookIsGoneIsDropped() async {
        let b = book(alive: false)
        _ = await b.apply(message())
        #expect(await b.current.isEmpty)
        #expect(await b.answer("1790000000-1-2", allow: true) == .closed)
    }

    @Test func latestIsPerSession() async {
        let b = book()
        _ = await b.apply(message("1790000000-1-2", session: "s1"))
        _ = await b.apply(message("1790000001-1-3", session: "s2"))
        _ = await b.apply(message("1790000002-1-4", session: "s1"))
        #expect(await b.latest(session: "s1")?.id == "1790000002-1-4")
        #expect(await b.current.count == 3)
    }

    /// The answer file is written next to it and renamed, so the hook never
    /// reads half a file, and an existing link at the path is not followed.
    @Test func doesNotFollowALinkAtTheAnswerPath() async throws {
        let b = book()
        _ = await b.apply(message())
        let target = "\(dir)/target"
        FileManager.default.createFile(atPath: target, contents: Data("keep".utf8))
        try FileManager.default.createSymbolicLink(atPath: "\(dir)/answer-s1-1790000000-1-2", withDestinationPath: target)
        #expect(await b.answer("1790000000-1-2", allow: true) == .written)
        #expect(try String(contentsOfFile: target, encoding: .utf8) == "keep")
    }
}
```

Append to `CoreTests` (it already has `path()` and `send(_:_:)`; the speech parts come from `SpeechOutTests`):

```swift
    func core(_ p: String, canListen: Bool, book: ApprovalBook) -> EarshotCore {
        let availability = ListenAvailability()
        availability.canListen = canListen
        let speech = SpeechOut(synth: FakeSynth(), player: FakePlayer(), mic: FakeMic(), ducker: FakeDucker())
        return EarshotCore(socketPath: p, speech: speech, sessions: SessionStore(), events: EventLog(),
                           approvals: book, availability: availability)
    }

    func approvalJSON(_ dir: String, sent: Double) -> String {
        #"{"v":1,"type":"approval","session":"s1","id":"1-2-3","name":"blog","what":"to run tests","answer":"\#(dir)/answer-s1-1-2-3","secret":"0123456789abcdef0123456789abcdef","pid":1,"sent":\#(Int(sent))}"#
    }

    @Test func takesAnApprovalOnlyWhenItCanListen() async throws {
        let dir = NSTemporaryDirectory() + "ek-ap-\(UUID().uuidString.prefix(6))"
        let now = Date().timeIntervalSince1970 * 1000
        for (canListen, expected) in [(true, #"{"ok":true}"#), (false, #"{"ok":false,"reason":"not listening"}"#)] {
            let p = path()
            let book = ApprovalBook(stateDir: dir, isAlive: { _ in true })
            let c = core(p, canListen: canListen, book: book)
            try await c.start()
            #expect(try send(p, approvalJSON(dir, sent: now)) == expected)
            try await Task.sleep(for: .milliseconds(100))
            #expect(await book.current.count == (canListen ? 1 : 0))
            c.stop()
        }
    }

    /// A closed message is applied however late it is read: dropping it would
    /// leave the app listening for a prompt that is gone.
    @Test func aLateClosedIsStillApplied() async throws {
        let dir = NSTemporaryDirectory() + "ek-ap-\(UUID().uuidString.prefix(6))"
        let p = path()
        let book = ApprovalBook(stateDir: dir, isAlive: { _ in true })
        let c = core(p, canListen: true, book: book)
        try await c.start()
        _ = try send(p, approvalJSON(dir, sent: Date().timeIntervalSince1970 * 1000))
        try await Task.sleep(for: .milliseconds(100))
        #expect(try send(p, #"{"v":1,"type":"approval","session":"s1","id":"1-2-3","state":"closed","by":"screen","sent":1000}"#) == #"{"ok":true}"#)
        try await Task.sleep(for: .milliseconds(100))
        #expect(await book.current.isEmpty)
        c.stop()
    }

    @Test func aLateOpenApprovalIsRefused() async throws {
        let dir = NSTemporaryDirectory() + "ek-ap-\(UUID().uuidString.prefix(6))"
        let p = path()
        let book = ApprovalBook(stateDir: dir, isAlive: { _ in true })
        let c = core(p, canListen: true, book: book)
        try await c.start()
        #expect(try send(p, approvalJSON(dir, sent: Date().timeIntervalSince1970 * 1000 - 1000)) == #"{"ok":false,"reason":"late"}"#)
        c.stop()
    }
```

- [ ] **Step 2: Run them to see them fail**

Run: `swift test --package-path app/EarshotKit --filter "ApprovalBookTests|CoreTests"`
Expected: FAIL to compile: `ApprovalBook`, `ListenAvailability` and the new `EarshotCore.init` do not exist.

- [ ] **Step 3: Write ApprovalBook**

`app/EarshotKit/Sources/EarshotKit/Core/ApprovalBook.swift`:

```swift
import Darwin
import Foundation
import Synchronization

public struct OpenApproval: Sendable, Equatable {
    public let session: String
    public let id: String
    /// The session as Earshot says it: "billing service".
    public let name: String
    /// What it asks for: "to run the migration".
    public let what: String
    public let answerPath: String
    let secret: String
    public let pid: Int32?
    public let opened: Date
}

/// Permission prompts the plugin's decide hook waits on. The app answers one
/// by writing "allow <secret>" or "deny <secret>" to its answer file.
public actor ApprovalBook {
    public enum AnswerResult: Sendable, Equatable {
        case written
        /// The prompt ended before the answer (a click, Esc, a timeout).
        case closed
        case failed
    }

    /// speak.sh's STATE: $(getconf DARWIN_USER_TEMP_DIR)earshot
    public static var defaultStateDir: String {
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        let n = confstr(_CS_DARWIN_USER_TEMP_DIR, &buf, buf.count)
        let base = n > 0 ? String(cString: buf) : NSTemporaryDirectory()
        return (base.hasSuffix("/") ? base : base + "/") + "earshot"
    }

    public static let processRuns: @Sendable (Int32) -> Bool = { pid in kill(pid, 0) == 0 || errno == EPERM }

    private var open: [String: OpenApproval] = [:]
    /// Recently closed ids: an open message that arrives after its close is refused.
    private var closed: [String] = []
    private let stateDir: String
    private let isAlive: @Sendable (Int32) -> Bool
    private let clock: @Sendable () -> Date
    private var conts: [UUID: AsyncStream<[OpenApproval]>.Continuation] = [:]

    public init(stateDir: String = ApprovalBook.defaultStateDir,
                isAlive: @escaping @Sendable (Int32) -> Bool = ApprovalBook.processRuns,
                clock: @escaping @Sendable () -> Date = Date.init) {
        self.stateDir = (stateDir as NSString).standardizingPath
        self.isAlive = isAlive
        self.clock = clock
    }

    /// Applies an open or closed message. Returns false when an open message
    /// was refused: bad names or secret, an answer path that is not this
    /// prompt's file in the state folder, or a prompt that already closed.
    @discardableResult
    public func apply(_ a: AppMessage.Approval) -> Bool {
        if a.isClosed {
            open[a.id] = nil
            closed.append(a.id)
            if closed.count > 64 { closed.removeFirst(closed.count - 64) }
            publish()
            return true
        }
        guard !closed.contains(a.id), Self.safe(a.session), Self.safe(a.id),
              let secret = a.secret, secret.count == 32, secret.allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
              let answer = a.answer, answer == "\(stateDir)/answer-\(a.session)-\(a.id)"
        else { return false }
        open[a.id] = OpenApproval(session: a.session, id: a.id, name: a.name ?? "a session", what: a.what ?? "",
                                  answerPath: answer, secret: secret, pid: a.pid, opened: clock())
        publish()
        return true
    }

    /// Open prompts, oldest first. A prompt whose hook is gone is dropped.
    public var current: [OpenApproval] {
        pruneDead()
        return open.values.sorted { $0.opened < $1.opened }
    }

    public func latest(session: String) -> OpenApproval? {
        current.last { $0.session == session }
    }

    public func isOpen(_ id: String) -> Bool { current.contains { $0.id == id } }

    /// Writes the answer, once. The file is written next to its final path
    /// and renamed over it, so the hook never reads half a file, and a link
    /// at the path is replaced, not followed.
    public func answer(_ id: String, allow: Bool) -> AnswerResult {
        pruneDead()
        guard let a = open.removeValue(forKey: id) else { return .closed }
        publish()
        let tmp = "\(stateDir)/.answer-\(a.id)-\(UUID().uuidString)"
        let fd = Darwin.open(tmp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return .failed }
        let text = Array("\(allow ? "allow" : "deny") \(a.secret)\n".utf8)
        let written = text.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        close(fd)
        guard written == text.count, rename(tmp, a.answerPath) == 0 else {
            unlink(tmp)
            return .failed
        }
        return .written
    }

    public func changes() -> AsyncStream<[OpenApproval]> {
        let (stream, cont) = AsyncStream<[OpenApproval]>.makeStream()
        let id = UUID()
        conts[id] = cont
        cont.yield(current)
        cont.onTermination = { [weak self] _ in Task { await self?.remove(id) } }
        return stream
    }

    private func remove(_ id: UUID) { conts[id] = nil }

    private func publish() {
        let list = open.values.sorted { $0.opened < $1.opened }
        conts.values.forEach { $0.yield(list) }
    }

    private func pruneDead() {
        let dead = open.values.filter { a in a.pid.map { !isAlive($0) } ?? false }.map(\.id)
        guard !dead.isEmpty else { return }
        dead.forEach { open[$0] = nil }
        publish()
    }

    static func safe(_ s: String) -> Bool {
        !s.isEmpty && s.utf8.count <= 128 && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }
}

/// Whether the app can listen right now: mic permission granted, the models
/// on this Mac, and listening not switched off. The app sets it; the plugin
/// socket reads it for each approval, on its own queue.
public final class ListenAvailability: Sendable {
    private let value = Mutex(false)
    public init() {}
    public var canListen: Bool {
        get { value.withLock { $0 } }
        set { value.withLock { $0 = newValue } }
    }
}
```

- [ ] **Step 4: Wire approvals into EarshotCore**

In `EarshotCore`, add the stored properties next to `events`:

```swift
    public let approvals: ApprovalBook
    public let availability: ListenAvailability
```

Replace the `init` signature and the handler body:

```swift
    public init(socketPath: String = EarshotCore.socketPath, speech: SpeechOut, sessions: SessionStore, events: EventLog,
                approvals: ApprovalBook = ApprovalBook(), availability: ListenAvailability = ListenAvailability()) {
        self.speech = speech
        self.sessions = sessions
        self.events = events
        self.approvals = approvals
        self.availability = availability
        let (stream, inbox) = AsyncStream<AppMessage>.makeStream()
        self.stream = stream
        self.inbox = inbox
        server = LineServer(path: socketPath) { (line: Data) -> LineServer.Answer in
            let message: AppMessage
            do {
                message = try AppMessage.decode(line)
            } catch AppMessage.DecodeError.version {
                return LineServer.Answer(reply: AppReply(ok: false, reason: "version").encoded)
            } catch {
                return LineServer.Answer(reply: AppReply(ok: false, reason: "unreadable").encoded)
            }
            let late: (Double?) -> Bool = { sent in
                guard let sent else { return false }
                return Date().timeIntervalSince1970 * 1000 - sent > EarshotCore.lateAfterMs
            }
            switch message {
            case .say(let s):
                // The plugin waits 0.2 s, then says the line itself. A line read
                // later than this was (or is about to be) said already.
                if late(s.sent) { return LineServer.Answer(reply: AppReply(ok: false, reason: "late").encoded) }
            case .approval(let a) where !a.isClosed:
                // The hook stops waiting after 0.2 s; it then sends closed.
                if late(a.sent) { return LineServer.Answer(reply: AppReply(ok: false, reason: "late").encoded) }
                if !availability.canListen {
                    return LineServer.Answer(reply: AppReply(ok: false, reason: "not listening").encoded)
                }
            default:
                break   // status, and closed approvals, however late
            }
            // Kept only once the plugin has the answer: if it stopped waiting,
            // it says the line itself.
            return LineServer.Answer(reply: AppReply(ok: true).encoded) { inbox.yield(message) }
        }
    }
```

In `start()`, capture `approvals` with the others and replace the placeholder branch from Task 1:

```swift
        let (stream, speech, sessions, events, approvals) = (self.stream, self.speech, self.sessions, self.events, self.approvals)
```

```swift
                case .approval(let a):
                    let taken = await approvals.apply(a)
                    await events.add(a.isClosed ? "approval closed (\(a.by ?? "?"))" : (taken ? "approval open" : "approval refused"))
```

Note: an open approval that `apply` refuses after the plugin got `{"ok":true}` (a bad path) makes the hook wait until the prompt ends on screen. That is safe: the dialog stays clickable.

- [ ] **Step 5: Run the tests**

Run: `swift test --package-path app/EarshotKit`
Expected: PASS, all suites.

- [ ] **Step 6: Run the plugin's approval tests against the real protocol shape**

Run: `bash tests/voice-approvals.sh`
Expected: `52 passed, 0 failed` (the plugin side is unchanged; this checks nothing regressed in the shared fixtures).

- [ ] **Step 7: Commit**

```bash
git add app/EarshotKit/Sources/EarshotKit/Core app/EarshotKit/Tests/EarshotKitTests/ApprovalBookTests.swift app/EarshotKit/Tests/EarshotKitTests/CoreTests.swift
git commit -m "Approvals: keep the prompts the decide hook waits on, and write the answer file"
```

---

### Task 3: Listening settings in the config

**Files:**
- Modify: `app/EarshotKit/Sources/EarshotKit/Config/EarshotConfig.swift`
- Test: `app/EarshotKit/Tests/EarshotKitTests/EarshotConfigTests.swift`

**Interfaces:**
- Produces, on `EarshotConfig`:
  - `wakeWord: Bool` (`EARSHOT_WAKE`, `on` or `off`, default off)
  - `wakeOnBattery: WakeBattery` (`EARSHOT_WAKE_BATTERY`: `always`, `power`, `lowpower`; default `lowpower`, meaning on battery it listens unless Low Power Mode is on)
  - `wakeSensitivity: Int` (`EARSHOT_WAKE_SENSITIVITY`, 1 to 10, default 5)
  - `hotkey: Hotkey` (`EARSHOT_HOTKEY`: `right_option`, `right_command`, `off`; default `right_option`)
  - `inputDevice: String?` (`EARSHOT_INPUT`, a Core Audio device UID; nil means automatic)
  - `public enum WakeBattery: String, Sendable, CaseIterable { case always, power, lowpower }`
  - `public enum Hotkey: String, Sendable, CaseIterable { case rightOption = "right_option", rightCommand = "right_command", off }`

- [ ] **Step 1: Write the failing tests**

Append to `EarshotConfigTests`:

```swift
    @Test func listeningDefaults() {
        let c = EarshotConfig(text: "")
        #expect(c.wakeWord == false)
        #expect(c.wakeOnBattery == .lowpower)
        #expect(c.wakeSensitivity == 5)
        #expect(c.hotkey == .rightOption)
        #expect(c.inputDevice == nil)
    }

    @Test func listeningValues() {
        let c = EarshotConfig(text: """
        EARSHOT_WAKE=on
        EARSHOT_WAKE_BATTERY=power
        EARSHOT_WAKE_SENSITIVITY=12
        EARSHOT_HOTKEY=right_command
        EARSHOT_INPUT='BuiltInMicrophoneDevice'
        """)
        #expect(c.wakeWord)
        #expect(c.wakeOnBattery == .power)
        #expect(c.wakeSensitivity == 10)   // clamped
        #expect(c.hotkey == .rightCommand)
        #expect(c.inputDevice == "BuiltInMicrophoneDevice")
    }

    @Test func unknownListeningValuesFallBack() {
        let c = EarshotConfig(text: "EARSHOT_WAKE_BATTERY=sometimes\nEARSHOT_HOTKEY=fn\nEARSHOT_WAKE_SENSITIVITY=x\n")
        #expect(c.wakeOnBattery == .lowpower)
        #expect(c.hotkey == .rightOption)
        #expect(c.wakeSensitivity == 5)
    }
```

- [ ] **Step 2: Run them to see them fail**

Run: `swift test --package-path app/EarshotKit --filter EarshotConfigTests`
Expected: FAIL to compile.

- [ ] **Step 3: Add the values**

In `EarshotConfig`, next to `Engine`:

```swift
    public enum WakeBattery: String, Sendable, CaseIterable { case always, power, lowpower }
    public enum Hotkey: String, Sendable, CaseIterable {
        case rightOption = "right_option", rightCommand = "right_command", off
    }
```

After `duckLevel`:

```swift
    /// App only: listen for "Hey Earshot". Off until you turn it on.
    public var wakeWord: Bool { self["EARSHOT_WAKE"] == "on" }
    /// App only: on battery, listen always, never (power), or unless Low Power Mode is on.
    public var wakeOnBattery: WakeBattery { nonEmpty("EARSHOT_WAKE_BATTERY").flatMap(WakeBattery.init) ?? .lowpower }
    /// App only: 1 (fewer false wakes) to 10 (fewer missed wakes).
    public var wakeSensitivity: Int {
        guard let s = self["EARSHOT_WAKE_SENSITIVITY"], let v = Int(s) else { return 5 }
        return min(max(v, 1), 10)
    }
    /// App only: the key you hold to talk.
    public var hotkey: Hotkey { nonEmpty("EARSHOT_HOTKEY").flatMap(Hotkey.init) ?? .rightOption }
    /// App only: the mic's Core Audio UID; nil picks one (see MicInput).
    public var inputDevice: String? { nonEmpty("EARSHOT_INPUT") }
```

- [ ] **Step 4: Run the tests**

Run: `swift test --package-path app/EarshotKit --filter EarshotConfigTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/EarshotKit/Sources/EarshotKit/Config/EarshotConfig.swift app/EarshotKit/Tests/EarshotKitTests/EarshotConfigTests.swift
git commit -m "Config: wake word, battery rule, sensitivity, hotkey and input device"
```

---
### Task 4: The ring buffer, the energy gate and the chunker

**Files:**
- Create: `app/EarshotKit/Sources/EarshotKit/Listen/SampleRing.swift`
- Test: `app/EarshotKit/Tests/EarshotKitTests/SampleRingTests.swift`

**Interfaces:**
- Produces:
  - `public struct SampleRing: Sendable` with `init(seconds: Double = 10, rate: Int = 16_000)`, `mutating func append(_ s: [Float])`, `var total: Int` (samples ever appended), `var oldest: Int` (absolute index of the oldest kept sample), `func samples(from: Int, to: Int? = nil) -> [Float]` (absolute indices, clamped to what is kept).
  - `public struct EnergyGate: Sendable` with `init(threshold: Float = 0.008, hangover: Int = 8)`, `mutating func admit(_ chunk: [Float]) -> Bool`, `static func rms(_ c: [Float]) -> Float`.
  - `public struct Chunker: Sendable` with `init(size: Int = 4096)`, `mutating func push(_ s: [Float]) -> [[Float]]`, `mutating func drain() -> [Float]`.

- [ ] **Step 1: Write the failing tests**

`app/EarshotKit/Tests/EarshotKitTests/SampleRingTests.swift`:

```swift
import Testing
@testable import EarshotKit

@Suite struct SampleRingTests {
    @Test func keepsTheNewestSamples() {
        var r = SampleRing(seconds: 1, rate: 10)   // 10 samples
        r.append((0..<7).map(Float.init))
        r.append((7..<15).map(Float.init))
        #expect(r.total == 15)
        #expect(r.oldest == 5)
        #expect(r.samples(from: 0) == (5..<15).map(Float.init))
        #expect(r.samples(from: 8, to: 11) == [8, 9, 10])
        #expect(r.samples(from: 14, to: 99) == [14])
        #expect(r.samples(from: 20).isEmpty)
    }

    @Test func aLongAppendKeepsItsTail() {
        var r = SampleRing(seconds: 1, rate: 4)
        r.append((0..<10).map(Float.init))
        #expect(r.samples(from: 0) == [6, 7, 8, 9])
    }

    @Test func gateOpensOnSoundAndStaysOpenBriefly() {
        var g = EnergyGate(threshold: 0.1, hangover: 2)
        let quiet = [Float](repeating: 0.01, count: 100), loud = [Float](repeating: 0.5, count: 100)
        do { let r = g.admit(quiet); #expect(!r) }
        do { let r = g.admit(loud); #expect(r) }
        do { let r = g.admit(quiet); #expect(r) }
        do { let r = g.admit(quiet); #expect(r) }
        do { let r = g.admit(quiet); #expect(!r) }
    }

    @Test func chunkerCutsFixedChunksAndDrainsTheRest() {
        var c = Chunker(size: 4)
        do { let r = c.push([1, 2, 3]); #expect(r.isEmpty) }
        do { let r = c.push([4, 5, 6, 7, 8, 9]); #expect(r == [[1, 2, 3, 4], [5, 6, 7, 8]]) }
        do { let r = c.drain(); #expect(r == [9]) }
        do { let r = c.drain(); #expect(r.isEmpty) }
    }
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `swift test --package-path app/EarshotKit --filter SampleRingTests`
Expected: FAIL to compile.

- [ ] **Step 3: Write the code**

`app/EarshotKit/Sources/EarshotKit/Listen/SampleRing.swift`:

```swift
/// The last few seconds of mic audio, in memory only. Positions are absolute
/// sample counts since the mic opened, so a segment can be cut out later.
public struct SampleRing: Sendable {
    public let capacity: Int
    private var buffer: [Float]
    private var head = 0   // where the next sample goes
    public private(set) var total = 0

    public init(seconds: Double = 10, rate: Int = 16_000) {
        capacity = max(1, Int(seconds * Double(rate)))
        buffer = [Float](repeating: 0, count: capacity)
    }

    public var oldest: Int { max(0, total - capacity) }

    public mutating func append(_ s: [Float]) {
        for x in s.suffix(capacity) {
            buffer[head] = x
            head = (head + 1) % capacity
        }
        total += s.count
    }

    /// Samples from `from` up to, not including, `to` (default: the newest).
    public func samples(from: Int, to: Int? = nil) -> [Float] {
        let lo = max(from, oldest), hi = min(to ?? total, total)
        guard lo < hi else { return [] }
        let startSlot = (head - (total - lo) + capacity * 2) % capacity
        return (0..<(hi - lo)).map { buffer[(startSlot + $0) % capacity] }
    }
}

/// Stage 1 of the cascade: lets audio through to the VAD only when it is
/// louder than a quiet room, and for a few chunks after.
public struct EnergyGate: Sendable {
    public var threshold: Float
    public var hangover: Int
    private var quiet = Int.max / 2

    public init(threshold: Float = 0.008, hangover: Int = 8) {
        self.threshold = threshold
        self.hangover = hangover
    }

    public mutating func admit(_ chunk: [Float]) -> Bool {
        if Self.rms(chunk) >= threshold {
            quiet = 0
            return true
        }
        quiet += 1
        return quiet <= hangover
    }

    public static func rms(_ c: [Float]) -> Float {
        guard !c.isEmpty else { return 0 }
        var sum: Float = 0
        for x in c { sum += x * x }
        return (sum / Float(c.count)).squareRoot()
    }
}

/// Cuts a stream of any chunk sizes into the fixed chunks the VAD needs.
public struct Chunker: Sendable {
    public let size: Int
    private var pending: [Float] = []

    public init(size: Int = 4096) { self.size = size }

    public mutating func push(_ s: [Float]) -> [[Float]] {
        pending += s
        var out: [[Float]] = []
        while pending.count >= size {
            out.append(Array(pending.prefix(size)))
            pending.removeFirst(size)
        }
        return out
    }

    /// What is left over, for example when the hotkey is released.
    public mutating func drain() -> [Float] {
        defer { pending.removeAll() }
        return pending
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `swift test --package-path app/EarshotKit --filter SampleRingTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/EarshotKit/Sources/EarshotKit/Listen/SampleRing.swift app/EarshotKit/Tests/EarshotKitTests/SampleRingTests.swift
git commit -m "Listening: a 10 second ring buffer, the energy gate and the VAD chunker"
```

---

### Task 5: When the mic may open

Stage 0 of the cascade: a pure rule that says whether the wake word may listen now, whether a command or a voice answer may be heard, and what the menu says when not.

**Files:**
- Create: `app/EarshotKit/Sources/EarshotKit/Listen/ListenPolicy.swift`
- Test: `app/EarshotKit/Tests/EarshotKitTests/ListenPolicyTests.swift`

**Interfaces:**
- Consumes: `EarshotConfig.WakeBattery`, `EarshotConfig.Hotkey` (Task 3).
- Produces:
  - `public struct ListenInputs: Sendable, Equatable` with `var` fields `micAllowed`, `modelsReady`, `modelProgress: Double?`, `wakeWord`, `battery: EarshotConfig.WakeBattery`, `onBattery`, `lowPower`, `liveSessions: Int`, `locked`, `asleep`, `micInUse`, `hotkey: EarshotConfig.Hotkey`, and `init()` with all false, zero, `.lowpower`, `.rightOption`, nil.
  - `public enum ListenBlock: Sendable, Equatable { case micPermission, models(Double?), wakeOff, asleep, locked, micInUse, lowPower, battery, noSessions }`
  - `public enum ListenPolicy` with `static func wakeBlock(_:) -> ListenBlock?`, `static func commandBlock(_:) -> ListenBlock?`, `static func canListen(_:) -> Bool`, `static func menuLine(_:) -> String`.

- [ ] **Step 1: Write the failing tests**

`app/EarshotKit/Tests/EarshotKitTests/ListenPolicyTests.swift`:

```swift
import Testing
@testable import EarshotKit

@Suite struct ListenPolicyTests {
    /// Everything allows listening; each test changes one thing.
    var ok: ListenInputs {
        var i = ListenInputs()
        i.micAllowed = true; i.modelsReady = true; i.wakeWord = true; i.liveSessions = 1
        return i
    }

    @Test func allClear() {
        #expect(ListenPolicy.wakeBlock(ok) == nil)
        #expect(ListenPolicy.commandBlock(ok) == nil)
        #expect(ListenPolicy.canListen(ok))
    }

    @Test func oneThingBlocksTheWakeWord() {
        let cases: [(WritableKeyPath<ListenInputs, Bool>, Bool, ListenBlock)] = [
            (\.micAllowed, false, .micPermission),
            (\.wakeWord, false, .wakeOff),
            (\.asleep, true, .asleep),
            (\.locked, true, .locked),
            (\.micInUse, true, .micInUse),
            (\.lowPower, true, .lowPower),
        ]
        for (key, value, block) in cases {
            var i = ok
            i[keyPath: key] = value
            #expect(ListenPolicy.wakeBlock(i) == block)
        }
    }

    @Test func modelsBlockWithProgress() {
        var i = ok
        i.modelsReady = false; i.modelProgress = 0.4
        #expect(ListenPolicy.wakeBlock(i) == .models(0.4))
        #expect(ListenPolicy.commandBlock(i) == .models(0.4))
        #expect(ListenPolicy.menuLine(.models(0.4)) == "Listening starts when the speech models finish downloading (40%).")
    }

    @Test func noSessionsBlocksOnlyTheWakeWord() {
        var i = ok
        i.liveSessions = 0
        #expect(ListenPolicy.wakeBlock(i) == .noSessions)
        #expect(ListenPolicy.commandBlock(i) == nil)   // "start a session in blog" still works
    }

    @Test func batteryRules() {
        var i = ok
        i.onBattery = true
        i.battery = .always
        #expect(ListenPolicy.wakeBlock(i) == nil)
        i.battery = .power
        #expect(ListenPolicy.wakeBlock(i) == .battery)
        i.battery = .lowpower
        #expect(ListenPolicy.wakeBlock(i) == nil)
        i.lowPower = true
        #expect(ListenPolicy.wakeBlock(i) == .lowPower)
        i.battery = .always
        #expect(ListenPolicy.wakeBlock(i) == nil)
    }

    /// The hotkey and voice answers do not follow the wake word's rules, but
    /// they never take the mic from a call, and never while the Mac is locked.
    @Test func commandsFollowFewerRules() {
        var i = ok
        i.wakeWord = false; i.lowPower = true; i.onBattery = true; i.battery = .power
        #expect(ListenPolicy.commandBlock(i) == nil)
        i.micInUse = true
        #expect(ListenPolicy.commandBlock(i) == .micInUse)
        i.micInUse = false; i.locked = true
        #expect(ListenPolicy.commandBlock(i) == .locked)
    }

    @Test func canListenNeedsATrigger() {
        var i = ok
        i.wakeWord = false; i.hotkey = .off
        #expect(!ListenPolicy.canListen(i))
        i.hotkey = .rightCommand
        #expect(ListenPolicy.canListen(i))
    }

    @Test func everyBlockHasAMenuLineWithoutEmDashes() {
        let all: [ListenBlock] = [.micPermission, .models(nil), .models(0.5), .wakeOff, .asleep, .locked, .micInUse,
                                  .lowPower, .battery, .noSessions]
        for b in all {
            let line = ListenPolicy.menuLine(b)
            #expect(!line.isEmpty)
            #expect(!line.contains("\u{2014}"))
        }
    }
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `swift test --package-path app/EarshotKit --filter ListenPolicyTests`
Expected: FAIL to compile.

- [ ] **Step 3: Write the rule**

`app/EarshotKit/Sources/EarshotKit/Listen/ListenPolicy.swift`:

```swift
/// What decides whether Earshot may open the mic.
public struct ListenInputs: Sendable, Equatable {
    public var micAllowed = false
    public var modelsReady = false
    /// 0 to 1 while the models download.
    public var modelProgress: Double?
    public var wakeWord = false
    public var battery: EarshotConfig.WakeBattery = .lowpower
    public var onBattery = false
    public var lowPower = false
    /// Open Claude Code sessions the plugin reported.
    public var liveSessions = 0
    public var locked = false
    public var asleep = false
    /// Another app captures from the mic (a call, dictation).
    public var micInUse = false
    public var hotkey: EarshotConfig.Hotkey = .rightOption

    public init() {}
}

public enum ListenBlock: Sendable, Equatable {
    case micPermission
    case models(Double?)
    case wakeOff
    case asleep
    case locked
    case micInUse
    case lowPower
    case battery
    case noSessions
}

/// Stage 0 of the cascade. Pure, so the menu and the listener agree.
public enum ListenPolicy {
    /// Why the wake word may not listen now, or nil when it may. The order
    /// is the order the menu explains it in: the first reason wins.
    public static func wakeBlock(_ i: ListenInputs) -> ListenBlock? {
        if let b = commonBlock(i) { return b }
        if !i.wakeWord { return .wakeOff }
        if i.battery != .always, i.lowPower { return .lowPower }
        if i.battery == .power, i.onBattery { return .battery }
        if i.liveSessions == 0 { return .noSessions }
        return nil
    }

    /// Why a command after the hotkey, or a follow-up answer, cannot be heard now.
    public static func commandBlock(_ i: ListenInputs) -> ListenBlock? { commonBlock(i) }

    /// For approvals: the app takes a prompt only when it could hear the answer.
    public static func canListen(_ i: ListenInputs) -> Bool {
        commandBlock(i) == nil && (i.wakeWord || i.hotkey != .off)
    }

    private static func commonBlock(_ i: ListenInputs) -> ListenBlock? {
        if !i.micAllowed { return .micPermission }
        if !i.modelsReady { return .models(i.modelProgress) }
        if i.asleep { return .asleep }
        if i.locked { return .locked }
        if i.micInUse { return .micInUse }
        return nil
    }

    public static func menuLine(_ b: ListenBlock) -> String {
        switch b {
        case .micPermission: "Listening is off: Earshot can't use the mic. Allow it in System Settings, Privacy & Security, Microphone."
        case .models(let p):
            "Listening starts when the speech models finish downloading" + (p.map { " (\(Int($0 * 100))%)." } ?? ".")
        case .wakeOff: "The wake word is off. Hold the hotkey to talk."
        case .asleep, .locked: "Not listening while the Mac is locked."
        case .micInUse: "Not listening while another app uses the mic."
        case .lowPower: "Not listening for the wake word in Low Power Mode."
        case .battery: "Not listening for the wake word on battery."
        case .noSessions: "Listening for the wake word once a session is open."
        }
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `swift test --package-path app/EarshotKit --filter ListenPolicyTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/EarshotKit/Sources/EarshotKit/Listen/ListenPolicy.swift app/EarshotKit/Tests/EarshotKitTests/ListenPolicyTests.swift
git commit -m "Listening: one rule for when the mic may open, and what the menu says"
```

---

### Task 6: The hotkey detector

Hold Right Option (or Right Command) to talk. The detector turns modifier events into down, up and cancel. A tap, a chord (another key pressed while it is held), or a press while another modifier is held is not a hold.

**Files:**
- Create: `app/EarshotKit/Sources/EarshotKit/Listen/HotkeyDetector.swift`
- Test: `app/EarshotKit/Tests/EarshotKitTests/HotkeyDetectorTests.swift`

**Interfaces:**
- Consumes: `EarshotConfig.Hotkey` (Task 3).
- Produces:
  - `public enum KeyEvent: Sendable, Equatable { case flagsChanged(keyCode: UInt16, flags: UInt64), keyDown }`. `flags` is the raw `CGEventFlags` value after the change.
  - `public struct HotkeyDetector: Sendable` with `init(hotkey: EarshotConfig.Hotkey, minHold: Double = 0.2)` and `mutating func handle(_ e: KeyEvent, at seconds: Double) -> HotkeyDetector.Action?`; `public enum Action: Sendable, Equatable { case down, up, cancel }`.

Raw values used (from `CGEventFlags` and `IOLLEvent.h`): `maskAlternate = 0x80000`, `maskCommand = 0x100000`, `maskShift = 0x20000`, `maskControl = 0x40000`, `maskSecondaryFn = 0x800000`; device bits right option `0x40`, right command `0x10`. Key codes: right option 61, right command 54.

- [ ] **Step 1: Write the failing tests**

`app/EarshotKit/Tests/EarshotKitTests/HotkeyDetectorTests.swift`:

```swift
import Testing
@testable import EarshotKit

@Suite struct HotkeyDetectorTests {
    // Right Option down: the option mask plus the right option device bit.
    let rOptDown = KeyEvent.flagsChanged(keyCode: 61, flags: 0x80000 | 0x40)
    let rOptUp = KeyEvent.flagsChanged(keyCode: 61, flags: 0)

    @Test func holdGivesDownThenUp() {
        var d = HotkeyDetector(hotkey: .rightOption)
        do { let r = d.handle(rOptDown, at: 0); #expect(r == .down) }
        do { let r = d.handle(rOptUp, at: 1.0); #expect(r == .up) }
    }

    @Test func tapIsIgnored() {
        var d = HotkeyDetector(hotkey: .rightOption)
        do { let r = d.handle(rOptDown, at: 0); #expect(r == .down) }
        do { let r = d.handle(rOptUp, at: 0.1); #expect(r == .cancel) }
    }

    /// Option+2 types "@" on some layouts: never a command.
    @Test func chordCancels() {
        var d = HotkeyDetector(hotkey: .rightOption)
        _ = d.handle(rOptDown, at: 0)
        do { let r = d.handle(.keyDown, at: 0.3); #expect(r == .cancel) }
        do { let r = d.handle(rOptUp, at: 0.5); #expect(r == nil) }
    }

    @Test func anotherModifierDuringTheHoldCancels() {
        var d = HotkeyDetector(hotkey: .rightOption)
        _ = d.handle(rOptDown, at: 0)
        do { let r = d.handle(.flagsChanged(keyCode: 56, flags: 0x80000 | 0x40 | 0x20000), at: 0.3); #expect(r == .cancel) }
    }

    @Test func pressWhileAnotherModifierIsHeldIsNotAHold() {
        var d = HotkeyDetector(hotkey: .rightOption)
        do { let r = d.handle(.flagsChanged(keyCode: 61, flags: 0x80000 | 0x40 | 0x100000), at: 0); #expect(r == nil) }
        do { let r = d.handle(rOptUp, at: 1); #expect(r == nil) }
    }

    @Test func leftOptionIsNotTheHotkey() {
        var d = HotkeyDetector(hotkey: .rightOption)
        do { let r = d.handle(.flagsChanged(keyCode: 58, flags: 0x80000 | 0x20), at: 0); #expect(r == nil) }
    }

    @Test func rightCommand() {
        var d = HotkeyDetector(hotkey: .rightCommand)
        do { let r = d.handle(.flagsChanged(keyCode: 54, flags: 0x100000 | 0x10), at: 0); #expect(r == .down) }
        do { let r = d.handle(.flagsChanged(keyCode: 54, flags: 0), at: 0.5); #expect(r == .up) }
        do { let r = d.handle(rOptDown, at: 1); #expect(r == nil) }
    }

    @Test func offNeverFires() {
        var d = HotkeyDetector(hotkey: .off)
        do { let r = d.handle(rOptDown, at: 0); #expect(r == nil) }
        do { let r = d.handle(rOptUp, at: 1); #expect(r == nil) }
    }
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `swift test --package-path app/EarshotKit --filter HotkeyDetectorTests`
Expected: FAIL to compile.

- [ ] **Step 3: Write the detector**

`app/EarshotKit/Sources/EarshotKit/Listen/HotkeyDetector.swift`:

```swift
/// A key event from the event tap, reduced to what the hotkey needs.
public enum KeyEvent: Sendable, Equatable {
    /// A modifier went down or up. `flags` is the raw CGEventFlags after the change.
    case flagsChanged(keyCode: UInt16, flags: UInt64)
    /// Any other key was pressed.
    case keyDown
}

/// Turns key events into a hold of one modifier key. A tap shorter than
/// `minHold`, a chord, or a press with another modifier held is not a hold.
public struct HotkeyDetector: Sendable {
    public enum Action: Sendable, Equatable { case down, up, cancel }

    static let alternate: UInt64 = 0x80000, command: UInt64 = 0x100000, shift: UInt64 = 0x20000,
               control: UInt64 = 0x40000, function: UInt64 = 0x800000
    static let rightOptionBit: UInt64 = 0x40, rightCommandBit: UInt64 = 0x10

    private let keyCode: UInt16?
    private let sideBit: UInt64
    private let ownMask: UInt64
    private let minHold: Double
    private var downAt: Double?
    private var cancelled = false

    public init(hotkey: EarshotConfig.Hotkey, minHold: Double = 0.2) {
        self.minHold = minHold
        switch hotkey {
        case .rightOption: keyCode = 61; sideBit = Self.rightOptionBit; ownMask = Self.alternate
        case .rightCommand: keyCode = 54; sideBit = Self.rightCommandBit; ownMask = Self.command
        case .off: keyCode = nil; sideBit = 0; ownMask = 0
        }
    }

    public mutating func handle(_ e: KeyEvent, at seconds: Double) -> Action? {
        guard let keyCode else { return nil }
        let others = (Self.alternate | Self.command | Self.shift | Self.control | Self.function) & ~ownMask
        switch e {
        case .keyDown:
            return cancelHold()
        case .flagsChanged(let code, let flags):
            if code != keyCode { return cancelHold() }
            let pressed = flags & sideBit != 0
            if pressed {
                guard downAt == nil, flags & others == 0 else { return nil }
                downAt = seconds
                cancelled = false
                return .down
            }
            guard let start = downAt else { return nil }
            downAt = nil
            if cancelled { cancelled = false; return nil }
            return seconds - start < minHold ? .cancel : .up
        }
    }

    /// Another key while the hotkey is held: the hold is over, and its release does nothing.
    private mutating func cancelHold() -> Action? {
        guard downAt != nil, !cancelled else { return nil }
        cancelled = true
        return .cancel
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `swift test --package-path app/EarshotKit --filter HotkeyDetectorTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/EarshotKit/Sources/EarshotKit/Listen/HotkeyDetector.swift app/EarshotKit/Tests/EarshotKitTests/HotkeyDetectorTests.swift
git commit -m "Listening: a hotkey hold, never a tap or a chord"
```

---
### Task 7: The Listener

The cascade as a state machine, on protocols so it is tested with fakes. Three ways in: the wake word (spotted once per speech segment), a hotkey hold, and a follow-up window that needs no wake word (after Earshot asks a question).

**Files:**
- Create: `app/EarshotKit/Sources/EarshotKit/Listen/ListenParts.swift`
- Create: `app/EarshotKit/Sources/EarshotKit/Listen/Listener.swift`
- Test: `app/EarshotKit/Tests/EarshotKitTests/ListenerTests.swift`

**Interfaces:**
- Consumes: `SampleRing`, `EnergyGate`, `Chunker` (Task 4).
- Produces (`ListenParts.swift`):
  - `public protocol AudioInput: Sendable { func start() async throws -> AsyncStream<[Float]>; func stop() async }` (16 kHz mono, any chunk length; `stop` finishes the stream)
  - `public enum SpeechEdge: Sendable, Equatable { case start, end }`
  - `public protocol SpeechGate: Sendable { func reset() async; func feed(_ chunk: [Float]) async -> SpeechEdge? }` (4096-sample chunks; `end` after 600 ms of silence)
  - `public protocol WakeSpotter: Sendable { func heardWake(_ samples: [Float], sensitivity: Int) async -> Bool }`
  - `public protocol Transcriber: Sendable { func transcribe(_ samples: [Float], vocabulary: [String]) async throws -> String; func prewarm() async }`
  - `public enum Chime: Sendable, Equatable { case listening, closed, confirm }`, `public protocol Chimes: Sendable { func play(_ chime: Chime) async }`
  - `public protocol ListenObserver: Sendable { func captureBegan(_ trigger: Listener.Trigger) async; func captureEnded(heard: Bool) async }` (`heard`: an utterance follows on `utterances`)
- Produces (`Listener.swift`): `public actor Listener` with
  - `enum Trigger: Sendable, Equatable { case wake, hotkey, followUp(FollowUp) }`, `enum FollowUp: Sendable, Equatable { case approval(id: String), reply }`
  - `struct Utterance: Sendable, Equatable { let text: String; let trigger: Trigger; let endedAt: ContinuousClock.Instant }`
  - `enum Phase: Sendable, Equatable { case off, waiting, capturing(Trigger), transcribing }`
  - `struct Timing: Sendable` (`wakeSilence`, `followUp`, `minHold`, `maxCommandSamples`, `preRollSamples`, `spotAtSamples`, `spotWindowSamples`, `minClipSamples`) with spec defaults
  - `init(input:gate:spotter:transcriber:chimes:timing:)`, `func setObserver(_ o: any ListenObserver)`
  - `nonisolated let utterances: AsyncStream<Utterance>` (one consumer: `VoiceLoop`), `func phaseChanges() -> AsyncStream<Phase>`
  - `func setWakeArmed(_ on: Bool) async`, `func setSensitivity(_ s: Int)`, `func setVocabulary(_ v: [String])`
  - `func hotkeyDown() async`, `func hotkeyUp() async`, `func hotkeyCancel() async`
  - `func listenFollowUp(_ f: FollowUp, within: Duration? = nil) async`
  - `func setMicBusy(_ busy: Bool) async`
  - `static func stripWake(_ text: String) -> String?` (nil when the text does not start with the wake phrase)

- [ ] **Step 1: Write the protocols**

`app/EarshotKit/Sources/EarshotKit/Listen/ListenParts.swift`:

```swift
/// The mic, as 16 kHz mono samples.
public protocol AudioInput: Sendable {
    /// Opens the mic. Chunks can be any length.
    func start() async throws -> AsyncStream<[Float]>
    /// Closes it and finishes the stream.
    func stop() async
}

public enum SpeechEdge: Sendable, Equatable { case start, end }

/// Stage 2: voice activity detection.
public protocol SpeechGate: Sendable {
    func reset() async
    /// One 4096-sample chunk. `end` comes after about 600 ms of silence.
    func feed(_ chunk: [Float]) async -> SpeechEdge?
}

/// Stage 3: "Hey Earshot" in the first seconds of a speech segment.
public protocol WakeSpotter: Sendable {
    /// sensitivity 1 (fewer false wakes) to 10 (fewer misses).
    func heardWake(_ samples: [Float], sensitivity: Int) async -> Bool
}

/// Stage 4: the command as text.
public protocol Transcriber: Sendable {
    /// The clip as text, with these names boosted. Throws when the model can't run.
    func transcribe(_ samples: [Float], vocabulary: [String]) async throws -> String
    /// Loads the model, so the next command is not slow.
    func prewarm() async
}

public enum Chime: Sendable, Equatable { case listening, closed, confirm }

public protocol Chimes: Sendable {
    func play(_ chime: Chime) async
}

/// Told when Earshot starts and stops hearing a command, so the speaker can
/// stop talking and lower other audio meanwhile.
public protocol ListenObserver: Sendable {
    func captureBegan(_ trigger: Listener.Trigger) async
    /// heard: an utterance follows on `utterances`, so keep other audio low
    /// until its answer has been said.
    func captureEnded(heard: Bool) async
}
```

- [ ] **Step 2: Write the failing tests**

`app/EarshotKit/Tests/EarshotKitTests/ListenerTests.swift`. Chunks are 4096 samples of one value: `0` is silence, `1` is speech, `2` is speech with the wake phrase, `3` is speech that the fake transcriber reads as a status question.

```swift
import Foundation
import Testing
@testable import EarshotKit

func chunk(_ v: Float) -> [Float] { [Float](repeating: v, count: 4096) }

actor FakeInput: AudioInput {
    private var cont: AsyncStream<[Float]>.Continuation?
    private(set) var starts = 0, stops = 0
    var isOpen: Bool { cont != nil }
    func start() async throws -> AsyncStream<[Float]> {
        starts += 1
        let (s, c) = AsyncStream<[Float]>.makeStream()
        cont = c
        return s
    }
    func stop() async { stops += 1; cont?.finish(); cont = nil }
    func push(_ values: [Float]) { for v in values { cont?.yield(chunk(v)) } }
}

/// Speech is any chunk above 0.5. Two quiet chunks end it.
actor FakeGate: SpeechGate {
    private var inSpeech = false, quiet = 0
    func reset() async { inSpeech = false; quiet = 0 }
    func feed(_ c: [Float]) async -> SpeechEdge? {
        if (c.first ?? 0) > 0.5 {
            quiet = 0
            if !inSpeech { inSpeech = true; return .start }
            return nil
        }
        guard inSpeech else { return nil }
        quiet += 1
        if quiet >= 2 { inSpeech = false; return .end }
        return nil
    }
}

actor FakeSpotter: WakeSpotter {
    private(set) var calls = 0
    func heardWake(_ s: [Float], sensitivity: Int) async -> Bool { calls += 1; return s.contains(2) }
}

actor FakeTranscriber: Transcriber {
    private(set) var vocabularies: [[String]] = []
    func transcribe(_ s: [Float], vocabulary: [String]) async throws -> String {
        vocabularies.append(vocabulary)
        var words: [String] = []
        if s.contains(2) { words.append("Hey Earshot,") }
        if s.contains(3) { words.append("what's everyone doing?") } else if s.contains(1) { words.append("run the tests") }
        return words.joined(separator: " ")
    }
    func prewarm() async {}
}

actor FakeChimes: Chimes {
    private(set) var played: [Chime] = []
    func play(_ c: Chime) async { played.append(c) }
}

actor FakeObserver: ListenObserver {
    private(set) var events: [String] = []
    func captureBegan(_ t: Listener.Trigger) async { events.append("began") }
    private(set) var heard: [Bool] = []
    func captureEnded(heard h: Bool) async { events.append("ended"); heard.append(h) }
}

actor Collected<T: Sendable> {
    private(set) var items: [T] = []
    func add(_ x: T) { items.append(x) }
}

/// Waits up to a second for a condition that other tasks make true.
func eventually(_ check: @escaping @Sendable () async -> Bool) async -> Bool {
    for _ in 0..<100 {
        if await check() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await check()
}

@Suite struct ListenerTests {
    let input = FakeInput(), gate = FakeGate(), spotter = FakeSpotter(), transcriber = FakeTranscriber()
    let chimes = FakeChimes(), observer = FakeObserver()
    let heard = Collected<Listener.Utterance>()

    func make(_ t: Listener.Timing = .forTests) async -> Listener {
        let l = Listener(input: input, gate: gate, spotter: spotter, transcriber: transcriber, chimes: chimes, timing: t)
        await l.setObserver(observer)
        let heard = self.heard
        Task { for await u in l.utterances { await heard.add(u) } }
        return l
    }

    @Test func wakeAndCommandInOneBreath() async {
        let l = await make()
        await l.setWakeArmed(true)
        #expect(await eventually { await input.isOpen })
        await input.push([2, 3, 3, 3, 3, 3, 3, 0, 0])
        #expect(await eventually { await heard.items.count == 1 })
        let u = await heard.items.first
        #expect(u?.text == "what's everyone doing?")
        #expect(u?.trigger == .wake)
        #expect(await spotter.calls == 1)   // once per segment
        #expect(await chimes.played == [.listening])
        #expect(await observer.events == ["began", "ended"])
        #expect(await observer.heard == [true])
    }

    @Test func speechWithoutTheWakePhraseIsIgnored() async {
        let l = await make()
        await l.setWakeArmed(true)
        _ = await eventually { await input.isOpen }
        await input.push([1, 1, 1, 1, 1, 1, 1, 1, 0, 0])
        #expect(await eventually { await spotter.calls == 1 })
        try? await Task.sleep(for: .milliseconds(100))
        #expect(await heard.items.isEmpty)
        #expect(await chimes.played.isEmpty)
        #expect(await observer.events.isEmpty)
    }

    @Test func wakeThenAPauseThenTheCommand() async {
        let l = await make()
        await l.setWakeArmed(true)
        _ = await eventually { await input.isOpen }
        await input.push([2, 2, 0, 0])
        #expect(await eventually { await chimes.played == [.listening] })
        await input.push([1, 1, 1, 0, 0])
        #expect(await eventually { await heard.items.count == 1 })
        #expect(await heard.items.first?.text == "run the tests")
        #expect(await observer.events == ["began", "ended"])
    }

    @Test func wakeThenSilenceCloses() async {
        let l = await make()
        await l.setWakeArmed(true)
        _ = await eventually { await input.isOpen }
        await input.push([2, 2, 0, 0])
        #expect(await eventually { await chimes.played == [.listening, .closed] })
        #expect(await heard.items.isEmpty)
        #expect(await observer.events == ["began", "ended"])
    }

    @Test func hotkeyHoldCapturesUntilRelease() async {
        let l = await make()
        await l.setVocabulary(["billing service"])
        await l.hotkeyDown()
        #expect(await eventually { await input.isOpen })
        try? await Task.sleep(for: .milliseconds(60))   // longer than minHold
        await input.push([1, 1, 1])
        try? await Task.sleep(for: .milliseconds(30))
        await l.hotkeyUp()
        #expect(await eventually { await heard.items.count == 1 })
        #expect(await heard.items.first?.text == "run the tests")
        #expect(await heard.items.first?.trigger == .hotkey)
        #expect(await chimes.played == [.listening])
        #expect(await transcriber.vocabularies == [["billing service"]])
        #expect(await eventually { await !input.isOpen })   // opened for this command only
    }

    @Test func aShortHoldNeverChimes() async {
        let l = await make()
        await l.hotkeyDown()
        await l.hotkeyUp()
        try? await Task.sleep(for: .milliseconds(80))
        #expect(await chimes.played.isEmpty)
        #expect(await observer.events.isEmpty)
        #expect(await heard.items.isEmpty)
        #expect(await eventually { await !input.isOpen })
    }

    @Test func aCancelledHoldSendsNothing() async {
        let l = await make()
        await l.hotkeyDown()
        try? await Task.sleep(for: .milliseconds(60))
        await input.push([1, 1])
        await l.hotkeyCancel()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await heard.items.isEmpty)
        #expect(await observer.events == ["began", "ended"])
    }

    @Test func aCallDropsTheCapture() async {
        let l = await make()
        await l.hotkeyDown()
        try? await Task.sleep(for: .milliseconds(60))
        await input.push([1, 1])
        await l.setMicBusy(true)
        await l.hotkeyUp()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await heard.items.isEmpty)
        #expect(await observer.events == ["began", "ended"])
        #expect(await observer.heard == [false])
        #expect(await eventually { await !input.isOpen })
    }

    @Test func followUpNeedsNoWakeWord() async {
        let l = await make()
        await l.listenFollowUp(.approval(id: "a1"))
        #expect(await eventually { await input.isOpen })
        await input.push([1, 1, 0, 0])
        #expect(await eventually { await heard.items.count == 1 })
        #expect(await heard.items.first?.trigger == .followUp(.approval(id: "a1")))
        #expect(await chimes.played == [.listening])
    }

    @Test func followUpTimesOutQuietly() async {
        let l = await make()
        await l.listenFollowUp(.reply)
        #expect(await eventually { await chimes.played == [.listening, .closed] })
        #expect(await heard.items.isEmpty)
        #expect(await observer.events == ["began", "ended"])
        #expect(await eventually { await !input.isOpen })
    }

    @Test func disarmingClosesTheMic() async {
        let l = await make()
        await l.setWakeArmed(true)
        #expect(await eventually { await input.isOpen })
        await l.setWakeArmed(false)
        #expect(await eventually { await !input.isOpen })
    }

    @Test(arguments: [
        ("Hey Earshot, what's everyone doing?", "what's everyone doing?"),
        ("hey ear shot tell billing to run the tests", "tell billing to run the tests"),
        ("Earshot. Stop billing.", "Stop billing."),
        ("Hey, Earshot", ""),
        ("Hey air shot, status", "status"),
    ])
    func stripsTheWakePhrase(_ said: String, _ rest: String) {
        #expect(Listener.stripWake(said) == rest)
    }

    @Test func leavesOtherTextAlone() {
        #expect(Listener.stripWake("run the tests") == nil)
    }
}

extension Listener.Timing {
    static let forTests = Listener.Timing(wakeSilence: .milliseconds(150), followUp: .milliseconds(150),
                                          minHold: .milliseconds(30))
}
```

- [ ] **Step 3: Run them to see them fail**

Run: `swift test --package-path app/EarshotKit --filter ListenerTests`
Expected: FAIL to compile: `Listener` does not exist.

- [ ] **Step 4: Write the Listener**

`app/EarshotKit/Sources/EarshotKit/Listen/Listener.swift`:

```swift
import Foundation
import os

/// Hears one command at a time: after "Hey Earshot", while the hotkey is
/// held, or in a short window after Earshot asked something. Audio lives
/// only in the ring buffer.
public actor Listener {
    public enum FollowUp: Sendable, Equatable {
        /// The answer to a permission prompt Earshot just announced.
        case approval(id: String)
        /// The answer to a question Earshot just asked ("Which one?").
        case reply
    }

    public enum Trigger: Sendable, Equatable { case wake, hotkey, followUp(FollowUp) }

    public struct Utterance: Sendable, Equatable {
        public let text: String
        public let trigger: Trigger
        public let endedAt: ContinuousClock.Instant
    }

    public enum Phase: Sendable, Equatable { case off, waiting, capturing(Trigger), transcribing }

    public struct Timing: Sendable {
        public var wakeSilence: Duration
        public var followUp: Duration
        public var minHold: Duration
        public var maxCommandSamples: Int
        public var preRollSamples: Int
        public var spotAtSamples: Int
        public var spotWindowSamples: Int
        public var minClipSamples: Int

        public init(wakeSilence: Duration = .seconds(8), followUp: Duration = .seconds(6),
                    minHold: Duration = .milliseconds(200), maxCommandSamples: Int = 15 * 16_000,
                    preRollSamples: Int = 4_800, spotAtSamples: Int = 24_000, spotWindowSamples: Int = 32_000,
                    minClipSamples: Int = 4_800) {
            self.wakeSilence = wakeSilence; self.followUp = followUp; self.minHold = minHold
            self.maxCommandSamples = maxCommandSamples; self.preRollSamples = preRollSamples
            self.spotAtSamples = spotAtSamples; self.spotWindowSamples = spotWindowSamples
            self.minClipSamples = minClipSamples
        }
    }

    /// A command being heard.
    private struct Capture {
        let id = UUID()
        var trigger: Trigger
        var start: Int
        /// Waiting for speech to begin: after "Hey Earshot" alone, or in a follow-up window.
        var waitingForSpeech: Bool
    }

    private let input: any AudioInput
    private let gate: any SpeechGate
    private let spotter: any WakeSpotter
    private let transcriber: any Transcriber
    private let chimes: any Chimes
    private let timing: Timing
    private var observer: (any ListenObserver)?
    private let log = Logger(subsystem: "com.earshot.app", category: "listener")

    public nonisolated let utterances: AsyncStream<Utterance>
    private let utteranceCont: AsyncStream<Utterance>.Continuation
    private var phaseConts: [UUID: AsyncStream<Phase>.Continuation] = [:]
    private var phase: Phase = .off {
        didSet { if phase != oldValue { phaseConts.values.forEach { $0.yield(phase) } } }
    }

    private var ring = SampleRing()
    private var chunker = Chunker()
    private var energy = EnergyGate()
    private var streamTask: Task<Void, Never>?
    private var micOpen = false
    private var armed = false
    private var micBusy = false
    private var sensitivity = 5
    private var vocabulary: [String] = []
    private var segmentStart: Int?
    private var spotted = false
    private var capture: Capture?
    private var hotkeyHeld = false
    private var holdTask: Task<Void, Never>?

    public init(input: any AudioInput, gate: any SpeechGate, spotter: any WakeSpotter, transcriber: any Transcriber,
                chimes: any Chimes, timing: Timing = Timing()) {
        self.input = input; self.gate = gate; self.spotter = spotter; self.transcriber = transcriber
        self.chimes = chimes; self.timing = timing
        let (stream, cont) = AsyncStream<Utterance>.makeStream()
        utterances = stream
        utteranceCont = cont
    }

    public func setObserver(_ o: any ListenObserver) { observer = o }
    public func setSensitivity(_ s: Int) { sensitivity = s }
    public func setVocabulary(_ v: [String]) { vocabulary = v }

    public func phaseChanges() -> AsyncStream<Phase> {
        let (stream, cont) = AsyncStream<Phase>.makeStream()
        let id = UUID()
        phaseConts[id] = cont
        cont.yield(phase)
        cont.onTermination = { [weak self] _ in Task { await self?.removePhaseCont(id) } }
        return stream
    }
    private func removePhaseCont(_ id: UUID) { phaseConts[id] = nil }

    // MARK: - Triggers

    /// The wake word may listen (see ListenPolicy). Opens or closes the mic.
    public func setWakeArmed(_ on: Bool) async {
        armed = on
        if on { await openMic() } else { await closeMicIfIdle() }
        settlePhase()
    }

    public func hotkeyDown() async {
        guard !micBusy, !hotkeyHeld else { return }
        hotkeyHeld = true
        await openMic()
        let start = max(ring.oldest, ring.total - timing.preRollSamples)
        holdTask?.cancel()
        holdTask = Task { [minHold = timing.minHold] in
            try? await Task.sleep(for: minHold)
            guard !Task.isCancelled else { return }
            await self.holdConfirmed(start: start)
        }
    }

    /// Held long enough: from here it is a command. Before this nothing is
    /// heard, chimed or lowered, so a tap or a chord changes nothing.
    private func holdConfirmed(start: Int) async {
        guard hotkeyHeld, !micBusy else { return }
        if let c = capture, case .followUp = c.trigger { capture = nil }   // the hotkey takes over
        else if capture != nil { return }
        capture = Capture(trigger: .hotkey, start: start, waitingForSpeech: false)
        phase = .capturing(.hotkey)
        await chimes.play(.listening)
        await observer?.captureBegan(.hotkey)
    }

    public func hotkeyUp() async {
        guard hotkeyHeld else { return }
        hotkeyHeld = false
        holdTask?.cancel()
        holdTask = nil
        if let c = capture, c.trigger == .hotkey {
            ring.append(chunker.drain())
            await finish(c, end: ring.total)
        } else {
            await closeMicIfIdle()
            settlePhase()
        }
    }

    public func hotkeyCancel() async {
        guard hotkeyHeld else { return }
        hotkeyHeld = false
        holdTask?.cancel()
        holdTask = nil
        if let c = capture, c.trigger == .hotkey { await drop(c) }
        await closeMicIfIdle()
        settlePhase()
    }

    /// Listens once without the wake word, for a few seconds.
    public func listenFollowUp(_ f: FollowUp, within: Duration? = nil) async {
        guard !micBusy, capture == nil, !hotkeyHeld else { return }
        await openMic()
        guard micOpen else { return }
        await gate.reset()
        let c = Capture(trigger: .followUp(f), start: ring.total, waitingForSpeech: true)
        capture = c
        phase = .capturing(c.trigger)
        await chimes.play(.listening)
        await observer?.captureBegan(c.trigger)
        scheduleTimeout(c.id, after: within ?? timing.followUp)
    }

    /// Another app opened the mic: drop what is being heard and close the mic.
    public func setMicBusy(_ busy: Bool) async {
        micBusy = busy
        guard busy else { return }
        holdTask?.cancel()
        holdTask = nil
        if let c = capture { await drop(c) }
        await closeMic()
        settlePhase()
    }

    // MARK: - Audio

    private func openMic() async {
        guard !micOpen, !micBusy else { return }
        do {
            let stream = try await input.start()
            micOpen = true
            streamTask = Task { [weak self] in
                for await samples in stream { await self?.receive(samples) }
            }
        } catch {
            log.error("couldn't open the mic: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func closeMic() async {
        guard micOpen else { return }
        micOpen = false
        streamTask?.cancel()
        streamTask = nil
        await input.stop()
        _ = chunker.drain()
        segmentStart = nil
        spotted = false
        await gate.reset()
    }

    private func closeMicIfIdle() async {
        if !armed, capture == nil, !hotkeyHeld { await closeMic() }
    }

    private func receive(_ samples: [Float]) async {
        for c in chunker.push(samples) { await process(c) }
    }

    private func process(_ chunk: [Float]) async {
        ring.append(chunk)
        if let c = capture, c.trigger == .hotkey {
            if ring.total - c.start >= timing.maxCommandSamples { await finish(c, end: ring.total) }
            return
        }
        // Stage 1: quiet audio skips the VAD, unless something is being heard.
        let loud = energy.admit(chunk)
        guard loud || segmentStart != nil || capture != nil else { return }
        let edge = await gate.feed(chunk)
        if edge == .start {
            // The VAD fires a little after speech starts: include the chunk before.
            segmentStart = max(ring.oldest, ring.total - 2 * chunk.count)
            spotted = false
            if var c = capture, c.waitingForSpeech, let s = segmentStart {
                c.start = s
                c.waitingForSpeech = false
                capture = c
            }
        }
        if let c = capture, !c.waitingForSpeech {
            if edge == .end || ring.total - c.start >= timing.maxCommandSamples {
                segmentStart = nil
                await finish(c, end: ring.total)
            }
            return
        }
        // Stage 3: the wake word, once per segment, at 1.5 s or at its end.
        if armed, capture == nil, let s = segmentStart, !spotted,
           ring.total - s >= timing.spotAtSamples || edge == .end {
            spotted = true
            let window = ring.samples(from: s, to: s + timing.spotWindowSamples)
            if await spotter.heardWake(window, sensitivity: sensitivity), capture == nil, !micBusy {
                let c = Capture(trigger: .wake, start: s, waitingForSpeech: false)
                capture = c
                phase = .capturing(.wake)
                await chimes.play(.listening)
                await observer?.captureBegan(.wake)
                if edge == .end { segmentStart = nil; await finish(c, end: ring.total) }
            }
        }
        if edge == .end { segmentStart = nil }
    }

    // MARK: - Ending a capture

    /// Stage 4: transcribes the clip and hands it on.
    private func finish(_ c: Capture, end: Int) async {
        guard capture?.id == c.id else { return }
        capture = nil
        phase = .transcribing
        let clip = ring.samples(from: c.start, to: end)
        var text = ""
        if clip.count >= timing.minClipSamples {
            do {
                text = try await transcriber.transcribe(clip, vocabulary: vocabulary)
            } catch {
                log.error("transcription failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if c.trigger == .wake, let rest = Self.stripWake(text) {
            text = rest
            if text.isEmpty {
                // "Hey Earshot" alone: keep listening for the command.
                let next = Capture(trigger: .wake, start: ring.total, waitingForSpeech: true)
                capture = next
                phase = .capturing(.wake)
                scheduleTimeout(next.id, after: timing.wakeSilence)
                return
            }
        }
        await observer?.captureEnded(heard: !text.isEmpty)
        if text.isEmpty {
            await chimes.play(.closed)
        } else {
            utteranceCont.yield(Utterance(text: text, trigger: c.trigger, endedAt: .now))
        }
        await closeMicIfIdle()
        settlePhase()
    }

    /// Ends a capture without a command: a call started, or the hotkey was cancelled.
    private func drop(_ c: Capture) async {
        guard capture?.id == c.id else { return }
        capture = nil
        await observer?.captureEnded(heard: false)
    }

    private func scheduleTimeout(_ id: UUID, after: Duration) {
        Task {
            try? await Task.sleep(for: after)
            await self.timedOut(id)
        }
    }

    private func timedOut(_ id: UUID) async {
        guard let c = capture, c.id == id, c.waitingForSpeech else { return }
        capture = nil
        await chimes.play(.closed)
        await observer?.captureEnded(heard: false)
        await closeMicIfIdle()
        settlePhase()
    }

    private func settlePhase() {
        if let c = capture { phase = .capturing(c.trigger); return }
        phase = micOpen && armed ? .waiting : .off
    }

    // MARK: - Text

    nonisolated(unsafe) private static let wakePrefix = try! Regex(
        #"^\s*(?:(?:hey|hi|ok|okay|a)[\s,.!]*)?(?:ear\s*shot|air\s*shot|earshot)\b[\s,.!?]*"#
    ).ignoresCase()

    /// The text after the wake phrase, or nil when it does not start with it.
    public static func stripWake(_ text: String) -> String? {
        guard let m = text.prefixMatch(of: wakePrefix) else { return nil }
        return String(text[m.range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
```

- [ ] **Step 5: Run the tests**

Run: `swift test --package-path app/EarshotKit --filter ListenerTests`
Expected: PASS. If a timing test is flaky on a loaded machine, raise the `forTests` durations, not the `eventually` limit.

- [ ] **Step 6: Commit**

```bash
git add app/EarshotKit/Sources/EarshotKit/Listen/ListenParts.swift app/EarshotKit/Sources/EarshotKit/Listen/Listener.swift app/EarshotKit/Tests/EarshotKitTests/ListenerTests.swift
git commit -m "Listener: wake word once per segment, hotkey hold, follow-up windows"
```

---
### Task 8: The speaker stops while you talk, and puts confirmations first

**Files:**
- Modify: `app/EarshotKit/Sources/EarshotKit/Speech/SpeechOut.swift`
- Test: `app/EarshotKit/Tests/EarshotKitTests/SpeechOutTests.swift`

**Interfaces:**
- Consumes: `LineKind.confirm` (Task 1).
- Produces, on `SpeechOut`:
  - `func beginListening() async`: stops the line that is playing (it is dropped, not held), keeps other audio lowered, and holds the queue.
  - `func endListening() async`: lets the queue run again; ends the ducking if nothing is left to say.
  - `enqueue` puts a `confirm` line ahead of every other queued line (behind earlier `confirm` lines).
  - `public enum LineEvent: Sendable, Equatable { case started(SpokenLine), finished(SpokenLine) }` and `func lineEvents() -> AsyncStream<LineEvent>`. `finished` comes only for a line whose audio was made and played to the end.

- [ ] **Step 1: Write the failing tests**

Append to `SpeechOutTests`:

```swift
    @Test func listeningStopsTheLineAndDropsIt() async {
        let player = FakePlayer(blocking: true)
        let s = await make(player)
        await s.enqueue(line("first")); await s.enqueue(line("second"))
        await eventually { await player.isPlaying }
        await s.beginListening()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await player.played == ["first"])   // second waits while you talk
        #expect(await s.state != .holding)            // first is not kept for later
        await player.unblock()
        await s.endListening()
        await eventually { await player.played == ["first", "second"] }
        #expect(await player.played == ["first", "second"])
    }

    @Test func linesWaitWhileListening() async {
        let player = FakePlayer()
        let s = await make(player)
        await s.beginListening()
        await s.enqueue(line("later"))
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await player.played.isEmpty)
        await s.endListening()
        await s.waitUntilIdle()
        #expect(await player.played == ["later"])
    }

    /// Other audio stays low from the wake word to the end of the answer, and
    /// comes back once.
    @Test func duckingSpansListeningAndTheAnswer() async {
        let player = FakePlayer()
        let s = await make(player)
        await s.beginListening()
        #expect(await ducker.begins == 1)
        await s.enqueue(line("Sent to blog.", .confirm, ""))
        await s.endListening()
        await s.waitUntilIdle()
        #expect(await ducker.ends == 1)
    }

    @Test func listeningAloneEndsTheDucking() async {
        let s = await make(FakePlayer())
        await s.beginListening()
        await s.endListening()
        #expect(await ducker.ends == 1)
    }

    @Test func confirmationsGoFirst() async {
        let player = FakePlayer(blocking: true)
        let s = await make(player)
        await s.enqueue(line("x")); await s.enqueue(line("y"))
        await eventually { await player.isPlaying }
        await s.enqueue(line("Sent.", .confirm, ""))
        await s.enqueue(line("Queued.", .confirm, ""))
        await player.unblock()
        await s.waitUntilIdle()
        #expect(await player.played == ["x", "Sent.", "Queued.", "y"])
    }

    @Test func confirmationsAreDroppedDuringACall() async {
        let player = FakePlayer()
        let s = await make(player)
        mic.set(true)
        await s.enqueue(line("Sent.", .confirm, ""))
        #expect(await s.state == .idle)
        mic.set(false)
        try? await Task.sleep(for: .milliseconds(80))
        #expect(await player.played.isEmpty)
    }

    @Test func lineEventsSayWhatWasHeard() async {
        let player = FakePlayer(blocking: true)
        let s = await make(player)
        let events = Collected<SpeechOut.LineEvent>()
        let stream = await s.lineEvents()
        Task { for await e in stream { await events.add(e) } }
        let a = line("heard", .need), b = line("cut off", .need)
        await s.enqueue(a); await s.enqueue(b)
        await eventually { await player.isPlaying }
        await player.finish()
        await eventually {
            let n = await player.played.count
            let playing = await player.isPlaying
            return n == 2 && playing
        }
        await s.beginListening()
        await s.endListening()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await events.items == [.started(a), .finished(a), .started(b)])
    }
```

(`Collected` is defined in `ListenerTests.swift`, Task 7.)

- [ ] **Step 2: Run them to see them fail**

Run: `swift test --package-path app/EarshotKit --filter SpeechOutTests`
Expected: FAIL to compile: `beginListening`, `endListening`, `lineEvents` do not exist.

- [ ] **Step 3: Add the state and the public calls**

In `SpeechOut`, add next to `State`:

```swift
    public enum LineEvent: Sendable, Equatable { case started(SpokenLine), finished(SpokenLine) }
```

Add next to the other private vars:

```swift
    /// You are talking to Earshot: nothing plays, other audio stays low.
    private var listening = false
    /// The playing line was stopped because you started talking: it is dropped.
    private var bargedIn = false
    private var lineConts: [UUID: AsyncStream<LineEvent>.Continuation] = [:]
```

Replace `enqueue`:

```swift
    public func enqueue(_ line: SpokenLine) async {
        if line.kind != .roll, await micBusy() {
            hold(line)   // a confirm line is not held: it is stale after a call
            return
        }
        if line.kind == .confirm {
            // Your answer comes before older lines, after earlier answers.
            let at = queue.firstIndex { $0.kind != .confirm } ?? queue.endIndex
            queue.insert(line, at: at)
        } else {
            queue.append(line)
        }
        runIfNeeded()
    }
```

Add after `sessionAnswered`:

```swift
    /// You started talking (the wake word, the hotkey, a follow-up). The line
    /// that is playing stops and is not said again; the rest waits.
    public func beginListening() async {
        listening = true
        if let id = currentLine {
            bargedIn = true
            await player.stop(id)
        }
        let ducker = self.ducker
        await bounded(callTimeout, ()) { await ducker.begin() }
    }

    public func endListening() async {
        guard listening else { return }
        listening = false
        if !running, queue.isEmpty {
            let ducker = self.ducker
            await bounded(callTimeout, ()) { await ducker.end() }
        }
        runIfNeeded()
    }

    public func lineEvents() -> AsyncStream<LineEvent> {
        let (stream, cont) = AsyncStream<LineEvent>.makeStream()
        let id = UUID()
        lineConts[id] = cont
        cont.onTermination = { [weak self] _ in Task { await self?.removeLineCont(id) } }
        return stream
    }
    private func removeLineCont(_ id: UUID) { lineConts[id] = nil }
    private func emit(_ e: LineEvent) { lineConts.values.forEach { $0.yield(e) } }
```

- [ ] **Step 4: Change the run loop**

In `run()`, make these four changes:

1. The loop condition: `while !queue.isEmpty, !listening {`
2. After `interrupted = false`, add `bargedIn = false`. (`made`, the synthesized file or nil, is already a local in the loop; the finished event checks it.)
3. Replace the block from `let finished: Bool` to the end of the `if !finished && interrupted { ... }` block with:

```swift
            emit(.started(line))
            let finished: Bool
            if interrupted || bargedIn {
                finished = false   // a call or your voice began while the ducking started
            } else if let done = await playWithTimeout(url, id: line.id) {
                finished = done
            } else {
                log.error("a line did not finish in time; skipped it")
                await player.stop(line.id)
                finished = true
            }
            currentLine = nil
            if finished, made != nil { emit(.finished(line)) }
            if !finished && interrupted {
                // A call started: say this line and the rest later.
                hold(line)
                for rest in queue where rest.kind != .roll { hold(rest) }
                queue.removeAll { $0.kind != .roll }
            }
            // Stopped because you talked: the line is dropped; the queue waits for endListening.
```

4. Replace the ducking end after the loop:

```swift
        if ducked, !listening {
            let ducker = self.ducker
            await bounded(callTimeout, ()) { await ducker.end() }
        }
```

- [ ] **Step 5: Run the tests**

Run: `swift test --package-path app/EarshotKit --filter SpeechOutTests`
Expected: PASS, the new tests and every old one.

- [ ] **Step 6: Commit**

```bash
git add app/EarshotKit/Sources/EarshotKit/Speech/SpeechOut.swift app/EarshotKit/Tests/EarshotKitTests/SpeechOutTests.swift
git commit -m "Speech: stop talking while you talk, answers first, events for heard lines"
```

---

### Task 9: The mic, the chimes and the system watch

The real parts behind `AudioInput` and `Chimes`, and a watch for lock, sleep, battery and Low Power Mode.

**Files:**
- Create: `app/EarshotKit/Sources/EarshotKit/Listen/MicInput.swift`
- Create: `app/EarshotKit/Sources/EarshotKit/Listen/SystemChimes.swift`
- Create: `app/EarshotKit/Sources/EarshotKit/Listen/SystemWatch.swift`
- Test: `app/EarshotKit/Tests/EarshotKitTests/MicInputTests.swift`

**Interfaces:**
- Consumes: `AudioInput`, `Chimes`, `Chime` (Task 7).
- Produces:
  - `public enum AudioDevices` with `struct Device: Sendable, Equatable { uid, name, hasInput, isBluetooth, isBuiltIn }`, `static func all() -> [Device]`, `static func defaultOutputIsBluetooth() -> Bool`, `static func chooseInput(setting: String?, inputs: [Device], outputIsBluetooth: Bool) -> String?`.
  - `public actor MicInput: AudioInput` with `init(deviceUID: @escaping @Sendable () -> String?)`.
  - `public struct SystemChimes: Chimes` with `init()`.
  - `@MainActor public final class SystemWatch` with `struct State: Sendable, Equatable { locked, asleep, onBattery, lowPower }`, `init()`, `var state: State`, `func changes() -> AsyncStream<State>`.

- [ ] **Step 1: Write the failing tests**

`app/EarshotKit/Tests/EarshotKitTests/MicInputTests.swift`:

```swift
import Foundation
import Testing
@testable import EarshotKit

@Suite struct MicInputTests {
    let builtIn = AudioDevices.Device(uid: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone", hasInput: true,
                                      isBluetooth: false, isBuiltIn: true)
    let airpods = AudioDevices.Device(uid: "AA-BB:input", name: "AirPods Pro", hasInput: true, isBluetooth: true,
                                      isBuiltIn: false)
    let usb = AudioDevices.Device(uid: "USB-1", name: "Yeti", hasInput: true, isBluetooth: false, isBuiltIn: false)

    @Test func aChosenInputThatIsPresentWins() {
        #expect(AudioDevices.chooseInput(setting: "USB-1", inputs: [builtIn, usb], outputIsBluetooth: true) == "USB-1")
    }

    /// Opening a Bluetooth headset's mic drops all its audio to call quality.
    @Test func bluetoothOutputUsesTheBuiltInMic() {
        #expect(AudioDevices.chooseInput(setting: nil, inputs: [airpods, builtIn], outputIsBluetooth: true)
                == "BuiltInMicrophoneDevice")
    }

    @Test func otherwiseTheSystemDefault() {
        #expect(AudioDevices.chooseInput(setting: nil, inputs: [airpods, builtIn], outputIsBluetooth: false) == nil)
        #expect(AudioDevices.chooseInput(setting: "gone", inputs: [builtIn], outputIsBluetooth: false) == nil)
    }

    @Test func bluetoothOutputWithoutABuiltInMicFallsBack() {
        #expect(AudioDevices.chooseInput(setting: nil, inputs: [airpods], outputIsBluetooth: true) == nil)
    }

    /// Needs the mic and its permission: EARSHOT_TEST_MIC=1.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["EARSHOT_TEST_MIC"] == "1"))
    func recordsAboutOneSecond() async throws {
        let mic = MicInput(deviceUID: { nil })
        let stream = try await mic.start()
        var count = 0
        let deadline = Date().addingTimeInterval(3)
        for await s in stream {
            count += s.count
            if count >= 16_000 || Date() > deadline { break }
        }
        await mic.stop()
        #expect(count >= 16_000)
    }
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `swift test --package-path app/EarshotKit --filter MicInputTests`
Expected: FAIL to compile.

- [ ] **Step 3: Write MicInput and AudioDevices**

`app/EarshotKit/Sources/EarshotKit/Listen/MicInput.swift`:

```swift
import AVFoundation
import CoreAudio
import Foundation
import os

public enum AudioDevices {
    public struct Device: Sendable, Equatable {
        public let uid: String
        public let name: String
        public let hasInput: Bool
        public let isBluetooth: Bool
        public let isBuiltIn: Bool
    }

    /// The mic to open. The setting, when that device is here; else the
    /// built-in mic when the output is Bluetooth (opening a Bluetooth mic
    /// switches the headset to call quality); else nil, the system default.
    public static func chooseInput(setting: String?, inputs: [Device], outputIsBluetooth: Bool) -> String? {
        if let setting, inputs.contains(where: { $0.uid == setting && $0.hasInput }) { return setting }
        if outputIsBluetooth, let b = inputs.first(where: { $0.isBuiltIn && $0.hasInput }) { return b.uid }
        return nil
    }

    public static func all() -> [Device] { allIDs().compactMap(device) }

    public static func defaultOutputIsBluetooth() -> Bool {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var id = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr
        else { return false }
        return device(id)?.isBluetooth ?? false
    }

    static func deviceID(uid: String) -> AudioObjectID? {
        allIDs().first { uidOf($0) == uid }
    }

    private static func allIDs() -> [AudioObjectID] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(0)
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func device(_ id: AudioObjectID) -> Device? {
        guard let uid = uidOf(id) else { return nil }
        let transport = uint(id, kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal)
        return Device(uid: uid, name: string(id, kAudioObjectPropertyName) ?? uid,
                      hasInput: streamCount(id, kAudioObjectPropertyScopeInput) > 0,
                      isBluetooth: transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE,
                      isBuiltIn: transport == kAudioDeviceTransportTypeBuiltIn)
    }

    private static func uidOf(_ id: AudioObjectID) -> String? { string(id, kAudioDevicePropertyDeviceUID) }

    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    private static func uint(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
                             _ scope: AudioObjectPropertyScope) -> UInt32 {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr ? value : 0
    }

    private static func streamCount(_ id: AudioObjectID, _ scope: AudioObjectPropertyScope) -> Int {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: scope,
                                              mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr else { return 0 }
        return Int(size) / MemoryLayout<AudioStreamID>.size
    }
}

/// 16 kHz mono from whatever the mic delivers. One converter per mic
/// session, so chunk edges join smoothly. Used only on the tap's thread.
final class Resampler: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let out = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    init?(from format: AVAudioFormat) {
        guard let c = AVAudioConverter(from: format, to: out) else { return nil }
        converter = c
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> [Float] {
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * out.sampleRate / buffer.format.sampleRate) + 32
        guard let dst = AVAudioPCMBuffer(pcmFormat: out, frameCapacity: capacity) else { return [] }
        var fed = false
        var error: NSError?
        converter.convert(to: dst, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let ch = dst.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: ch[0], count: Int(dst.frameLength)))
    }
}

/// The mic through AVAudioEngine. The engine exists only while the mic is
/// open, and is rebuilt when the audio hardware changes.
public actor MicInput: AudioInput {
    public enum Failure: Error { case noInput }

    private let deviceUID: @Sendable () -> String?
    private var engine: AVAudioEngine?
    private var cont: AsyncStream<[Float]>.Continuation?
    private var observer: (any NSObjectProtocol)?
    private let log = Logger(subsystem: "com.earshot.app", category: "mic")

    public init(deviceUID: @escaping @Sendable () -> String?) { self.deviceUID = deviceUID }

    public func start() async throws -> AsyncStream<[Float]> {
        await stop()
        let (stream, cont) = AsyncStream<[Float]>.makeStream(bufferingPolicy: .bufferingNewest(256))
        self.cont = cont
        do { try build() } catch { cont.finish(); self.cont = nil; throw error }
        return stream
    }

    public func stop() async {
        teardown()
        cont?.finish()
        cont = nil
    }

    private func build() throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let choice = AudioDevices.chooseInput(setting: deviceUID(), inputs: AudioDevices.all().filter(\.hasInput),
                                              outputIsBluetooth: AudioDevices.defaultOutputIsBluetooth())
        if let uid = choice, var id = AudioDevices.deviceID(uid: uid), let unit = input.audioUnit {
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id,
                                 UInt32(MemoryLayout<AudioObjectID>.size))
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0, let resampler = Resampler(from: format) else {
            throw Failure.noInput
        }
        let cont = self.cont
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            let s = resampler.convert(buffer)
            if !s.isEmpty { cont?.yield(s) }
        }
        engine.prepare()
        try engine.start()
        self.engine = engine
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine,
                                                          queue: nil) { [weak self] _ in
            Task { await self?.rebuild() }
        }
        log.info("mic open")
    }

    private func rebuild() {
        guard cont != nil else { return }
        teardown()
        do { try build() } catch {
            log.error("couldn't reopen the mic after a device change")
            cont?.finish()
            cont = nil
        }
    }

    private func teardown() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        if engine != nil { log.info("mic closed") }
        engine = nil
    }
}
```

- [ ] **Step 4: Write the chimes and the system watch**

`app/EarshotKit/Sources/EarshotKit/Listen/SystemChimes.swift`:

```swift
import AppKit

/// Short system sounds: Earshot is listening, stopped listening, or did it.
public struct SystemChimes: Chimes {
    public init() {}

    public func play(_ chime: Chime) async {
        let name = switch chime {
        case .listening: "Tink"
        case .closed: "Pop"
        case .confirm: "Morse"
        }
        await MainActor.run { _ = NSSound(named: NSSound.Name(name))?.play() }
    }
}
```

`app/EarshotKit/Sources/EarshotKit/Listen/SystemWatch.swift`:

```swift
import AppKit
import Foundation
import IOKit.ps

/// Lock, sleep, battery and Low Power Mode, from notifications. Nothing polls.
@MainActor public final class SystemWatch {
    public struct State: Sendable, Equatable {
        public var locked = false
        public var asleep = false
        public var onBattery = false
        public var lowPower = false
    }

    public private(set) var state = State() {
        didSet { if state != oldValue { conts.values.forEach { $0.yield(state) } } }
    }
    private var conts: [UUID: AsyncStream<State>.Continuation] = [:]
    private var tokens: [any NSObjectProtocol] = []
    private var powerSource: CFRunLoopSource?

    public init() {
        state.lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        state.onBattery = Self.onBattery()
        let distributed = DistributedNotificationCenter.default()
        tokens.append(distributed.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.state.locked = true }
        })
        tokens.append(distributed.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.state.locked = false }
        })
        let ws = NSWorkspace.shared.notificationCenter
        tokens.append(ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.state.asleep = true }
        })
        tokens.append(ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.state.asleep = false }
        })
        tokens.append(NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil,
                                                             queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.state.lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled }
        })
        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            let watch = Unmanaged<SystemWatch>.fromOpaque(ctx).takeUnretainedValue()
            MainActor.assumeIsolated { watch.state.onBattery = SystemWatch.onBattery() }
        }, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
            powerSource = source
        }
    }

    public func changes() -> AsyncStream<State> {
        let (stream, cont) = AsyncStream<State>.makeStream()
        let id = UUID()
        conts[id] = cont
        cont.yield(state)
        cont.onTermination = { [weak self] _ in Task { @MainActor in self?.conts[id] = nil } }
        return stream
    }

    nonisolated static func onBattery() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        else { return false }
        return type == kIOPMBatteryPowerKey
    }
}
```

`SystemWatch` lives as long as the app (the app model owns it), so the unretained pointer in the power callback stays valid.

- [ ] **Step 5: Run the tests**

Run: `swift test --package-path app/EarshotKit --filter MicInputTests`
Expected: PASS (the mic test skips).

Run on a Mac with a mic, once: `EARSHOT_TEST_MIC=1 swift test --package-path app/EarshotKit --filter recordsAboutOneSecond`
Expected: PASS after you allow the Terminal mic access.

- [ ] **Step 6: Commit**

```bash
git add app/EarshotKit/Sources/EarshotKit/Listen/MicInput.swift app/EarshotKit/Sources/EarshotKit/Listen/SystemChimes.swift app/EarshotKit/Sources/EarshotKit/Listen/SystemWatch.swift app/EarshotKit/Tests/EarshotKitTests/MicInputTests.swift
git commit -m "Listening: the mic at 16 kHz with the Bluetooth rule, chimes, and a system watch"
```

---
### Task 10: Commands and the fixed grammar

The fast path (under 5 ms): about 60 phrasings map straight to a `Command`. Anything else goes to the model in Task 11. The grammar also knows the yes and no words for approvals.

**Files:**
- Create: `app/EarshotKit/Sources/EarshotKit/Commands/Command.swift`
- Create: `app/EarshotKit/Sources/EarshotKit/Commands/Grammar.swift`
- Test: `app/EarshotKit/Tests/EarshotKitTests/GrammarTests.swift`

**Interfaces:**
- Produces:
  - `public enum Command: Sendable, Equatable { case send(target: String?, prompt: String), status(target: String?), stop(target: String?, now: Bool), start(project: String, prompt: String?), answer(allow: Bool, target: String?), unknown }`
  - `public enum Grammar` with `static func parse(_ transcript: String, known: [String] = []) -> Command?` (nil: no shape matched, ask the model; `.unknown`: a shape matched but nothing usable was said) and `static func approvalWord(_ text: String) -> Bool?` (true allow, false deny, nil anything else).
  - Targets and prompts keep the words as said (case and inner punctuation), without trailing punctuation.

- [ ] **Step 1: Write the failing tests**

`app/EarshotKit/Tests/EarshotKitTests/GrammarTests.swift`:

```swift
import Testing
@testable import EarshotKit

@Suite struct GrammarTests {
    static let known = ["billing service", "blog", "earshot", "refund rounding"]

    @Test(arguments: [
        // Status, everyone
        ("What's everyone doing?", Command.status(target: nil)),
        ("what is everyone doing", .status(target: nil)),
        ("Um, what's everybody doing?", .status(target: nil)),
        ("Roll call.", .status(target: nil)),
        ("Status.", .status(target: nil)),
        ("What's going on?", .status(target: nil)),
        ("Can you give me a status update?", .status(target: nil)),
        ("How's everything going?", .status(target: nil)),
        // Status, one session
        ("What's billing doing?", .status(target: "billing")),
        ("What is billing service doing?", .status(target: "billing service")),
        ("How's the blog going?", .status(target: "the blog")),
        ("How is earshot doing", .status(target: "earshot")),
        ("Status of refund rounding.", .status(target: "refund rounding")),
        ("What's the status of billing?", .status(target: "billing")),
        ("What's up with blog?", .status(target: "blog")),
        ("Where's billing at?", .status(target: "billing")),
        ("Check on the blog.", .status(target: "the blog")),
        ("Billing status.", .status(target: "Billing")),
        // Send
        ("Tell billing service to run the tests.", .send(target: "billing service", prompt: "run the tests")),
        ("tell billing to run the tests", .send(target: "billing", prompt: "run the tests")),
        ("Can you tell blog to fix the RSS feed?", .send(target: "blog", prompt: "fix the RSS feed")),
        ("Ask earshot to summarize what it did.", .send(target: "earshot", prompt: "summarize what it did")),
        ("Ask billing what it's working on.", .send(target: "billing", prompt: "what it's working on")),
        ("Ask the blog why the build failed", .send(target: "the blog", prompt: "why the build failed")),
        ("Tell it to keep going.", .send(target: nil, prompt: "keep going")),
        ("Tell them to commit the changes.", .send(target: nil, prompt: "commit the changes")),
        ("Get billing to push the branch.", .send(target: "billing", prompt: "push the branch")),
        ("In billing service, run the tests.", .send(target: "billing service", prompt: "run the tests")),
        ("in billing service run the tests", .send(target: "billing service", prompt: "run the tests")),
        ("On the blog, set the timeout to 2.5 seconds.", .send(target: "the blog", prompt: "set the timeout to 2.5 seconds")),
        ("For earshot: open a PR.", .send(target: "earshot", prompt: "open a PR")),
        ("Please tell blog to deploy, thanks.", .send(target: "blog", prompt: "deploy")),
        ("Send run the linter to billing.", .send(target: "billing", prompt: "run the linter")),
        ("Tell refund rounding to add a test for zero.", .send(target: "refund rounding", prompt: "add a test for zero")),
        // Stop
        ("Stop billing.", .stop(target: "billing", now: false)),
        ("stop billing service now", .stop(target: "billing service", now: true)),
        ("Stop the blog right now.", .stop(target: "the blog", now: true)),
        ("Halt earshot immediately.", .stop(target: "earshot", now: true)),
        ("Tell billing to stop.", .stop(target: "billing", now: false)),
        ("Tell billing to stop now.", .stop(target: "billing", now: true)),
        ("Stop.", .stop(target: nil, now: false)),
        ("Stop it.", .stop(target: nil, now: false)),
        // Start
        ("Start a session in blog.", .start(project: "blog", prompt: nil)),
        ("Start a new session in blog to fix the header.", .start(project: "blog", prompt: "fix the header")),
        ("Open a new session in billing service and write the changelog.",
         .start(project: "billing service", prompt: "write the changelog")),
        ("New session in earshot to look at the logs.", .start(project: "earshot", prompt: "look at the logs")),
        ("Start a session for the wedding site.", .start(project: "the wedding site", prompt: nil)),
        // Answers
        ("Yes.", .answer(allow: true, target: nil)),
        ("Yeah.", .answer(allow: true, target: nil)),
        ("Go ahead.", .answer(allow: true, target: nil)),
        ("No.", .answer(allow: false, target: nil)),
        ("Yes billing.", .answer(allow: true, target: "billing")),
        ("Approve billing service.", .answer(allow: true, target: "billing service")),
        ("Allow the blog.", .answer(allow: true, target: "the blog")),
        ("No to billing.", .answer(allow: false, target: "billing")),
        ("Deny earshot.", .answer(allow: false, target: "earshot")),
        ("Yes to blog.", .answer(allow: true, target: "blog")),
        // Matched a shape, nothing to send
        ("Tell billing to", .unknown),
        ("Tell billing to um", .unknown),
        ("um", .unknown),
        ("", .unknown),
    ] as [(String, Command)])
    func phrasing(_ said: String, _ expected: Command) {
        #expect(Grammar.parse(said, known: Self.known) == expected)
    }

    @Test(arguments: [
        "Run the tests.",                          // no target named: the model decides
        "Could billing maybe look at the flaky test",
        "Let's have the blog rewrite the intro",
    ])
    func unmatchedGoesToTheModel(_ said: String) {
        #expect(Grammar.parse(said, known: Self.known) == nil)
    }

    @Test func emptyPromptIsNoCommand() {
        #expect(Grammar.parse("tell billing to") == .unknown)
        #expect(Grammar.parse("in billing service,") == .unknown)
    }

    @Test(arguments: [
        ("yes", true), ("Yeah.", true), ("yep", true), ("Allow it.", true), ("approve", true), ("Go ahead.", true),
        ("Do it.", true), ("sure", true), ("OK.", true), ("Okay", true), ("yes please", true),
        ("no", false), ("Nope.", false), ("deny", false), ("Don't.", false), ("stop", false), ("cancel", false),
        ("no thanks", false),
    ] as [(String, Bool)])
    func approvalWords(_ said: String, _ allow: Bool) {
        #expect(Grammar.approvalWord(said) == allow)
    }

    /// Only a clear word counts: a sentence with other content does nothing.
    @Test(arguments: ["yes but use the other file", "no idea", "sure, after you run the tests", "", "maybe", "hmm"])
    func otherSentencesAreNoAnswer(_ said: String) {
        #expect(Grammar.approvalWord(said) == nil)
    }
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `swift test --package-path app/EarshotKit --filter GrammarTests`
Expected: FAIL to compile.

- [ ] **Step 3: Write Command**

`app/EarshotKit/Sources/EarshotKit/Commands/Command.swift`:

```swift
/// What a spoken command asks for. Targets are as said ("billing"); the
/// session directory finds the session.
public enum Command: Sendable, Equatable {
    /// Put a prompt into a session. No target: the only session, or the one
    /// Earshot last spoke about.
    case send(target: String?, prompt: String)
    /// No target: the roll call.
    case status(target: String?)
    /// now: stop at once (background sessions), else after the current step.
    case stop(target: String?, now: Bool)
    case start(project: String, prompt: String?)
    /// Yes or no to a permission prompt.
    case answer(allow: Bool, target: String?)
    case unknown
}
```

- [ ] **Step 4: Write the grammar**

`app/EarshotKit/Sources/EarshotKit/Commands/Grammar.swift`:

```swift
import Foundation

/// The fixed grammar: the fast path, and the fallback when the model is not
/// available. Works on words, keeping each word as it was said.
public enum Grammar {
    struct Words {
        var said: [String]   // as transcribed, with their punctuation
        var keys: [String]   // lowercased, punctuation trimmed

        init(_ text: String) {
            said = text.split(whereSeparator: \.isWhitespace).map(String.init)
            keys = said.map(Self.key)
            // A word that was only punctuation ("-", "...") is dropped.
            let keep = keys.indices.filter { !keys[$0].isEmpty }
            said = keep.map { said[$0] }
            keys = keep.map { keys[$0] }
        }

        init(said: [String], keys: [String]) { self.said = said; self.keys = keys }

        static func key(_ w: String) -> String {
            w.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
                .trimmingCharacters(in: CharacterSet(charactersIn: ".,!?;:\"()[]\u{201C}\u{201D}-"))
        }

        var isEmpty: Bool { keys.isEmpty }
        var count: Int { keys.count }
        var key: String { keys.joined(separator: " ") }
        /// The words as said, without the punctuation that ends the last one.
        var text: String {
            said.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: ".,!?;: "))
        }

        func slice(_ r: Range<Int>) -> Words { Words(said: Array(said[r]), keys: Array(keys[r])) }

        /// The rest after the first of these phrases that starts the words.
        func after(_ phrases: [String]) -> Words? {
            for p in phrases.sorted(by: { $0.count > $1.count }) {
                let pk = p.split(separator: " ").map(String.init)
                if keys.starts(with: pk) { return slice(pk.count..<count) }
            }
            return nil
        }

        /// The words before the first of these phrases that ends them.
        func before(_ phrases: [String]) -> Words? {
            for p in phrases.sorted(by: { $0.count > $1.count }) {
                let pk = p.split(separator: " ").map(String.init)
                if pk.count <= count, Array(keys.suffix(pk.count)) == pk { return slice(0..<(count - pk.count)) }
            }
            return nil
        }

        /// Split at the first of these words: (before, after).
        func split(at words: Set<String>) -> (Words, Words)? {
            guard let i = keys.firstIndex(where: words.contains) else { return nil }
            return (slice(0..<i), slice((i + 1)..<count))
        }

        /// Split after the first word said with a comma or colon after it.
        func splitAtComma() -> (Words, Words)? {
            guard let i = said.firstIndex(where: { $0.hasSuffix(",") || $0.hasSuffix(":") }) else { return nil }
            return (slice(0..<(i + 1)), slice((i + 1)..<count))
        }

        /// Split after the longest known name that starts the words.
        func splitAtKnown(_ known: [String]) -> (Words, Words)? {
            let names = known.map { $0.lowercased().split(separator: " ").map(String.init) }.sorted { $0.count > $1.count }
            for n in names where !n.isEmpty && n.count < count && keys.starts(with: n) {
                return (slice(0..<n.count), slice(n.count..<count))
            }
            for n in names where !n.isEmpty && keys.count > n.count + 1 && keys.first == "the" && Array(keys.dropFirst().prefix(n.count)) == n {
                return (slice(0..<(n.count + 1)), slice((n.count + 1)..<count))
            }
            return nil
        }

        func trimmingFillers() -> Words {
            var w = self
            while let f = w.keys.first, Grammar.fillers.contains(f) { w = w.slice(1..<w.count) }
            if let rest = w.after(Grammar.leadIns) { w = rest }
            while let f = w.keys.first, Grammar.fillers.contains(f) { w = w.slice(1..<w.count) }
            while let l = w.keys.last, Grammar.tail.contains(l) { w = w.slice(0..<(w.count - 1)) }
            if let rest = w.before(["thank you"]) { w = rest }
            return w
        }
    }

    static let fillers: Set<String> = ["um", "uh", "erm", "hmm", "so", "okay", "ok", "please", "hey", "and", "like"]
    static let leadIns = ["can you", "could you", "would you", "will you", "i want you to", "i need you to",
                          "go ahead and", "i'd like you to"]
    static let tail: Set<String> = ["please", "thanks", "um", "uh"]

    static let allowWords: Set<String> = ["yes", "yeah", "yep", "yup", "allow", "allow it", "approve", "approve it",
                                          "approved", "go ahead", "do it", "sure", "ok", "okay", "yes please",
                                          "yes go ahead", "yeah go ahead"]
    static let denyWords: Set<String> = ["no", "nope", "deny", "deny it", "don't", "dont", "don't do it", "stop",
                                         "cancel", "no thanks", "no thank you", "nah"]

    static let everyone: Set<String> = [
        "what's everyone doing", "what is everyone doing", "whats everyone doing", "what's everybody doing",
        "what is everybody doing", "what's everyone up to", "what's everybody up to", "roll call", "status",
        "status update", "give me a status update", "give me a status", "status report", "what's happening",
        "what's going on", "what is going on", "how's everything going", "how is everything going",
        "how's everything", "what's the status", "everyone's status",
    ]

    /// (starts with, ends with) around a target.
    static let statusShapes: [(String, String)] = [
        ("what's the status of", ""), ("what is the status of", ""), ("what's", "doing"), ("what is", "doing"),
        ("whats", "doing"), ("how's", "doing"), ("how is", "doing"), ("how's", "going"), ("how is", "going"),
        ("status of", ""), ("status on", ""), ("what's up with", ""), ("where's", "at"), ("where is", "at"),
        ("check on", ""), ("", "status"),
    ]

    static let questionWords: Set<String> = ["what", "what's", "why", "how", "whether", "if", "when", "where",
                                             "which", "who", "is", "are", "does", "did"]
    static let pronouns: Set<String> = ["it", "them", "him", "her", "claude", "that session", "this session"]

    public static func approvalWord(_ text: String) -> Bool? {
        let k = Words(text).key
        if allowWords.contains(k) { return true }
        if denyWords.contains(k) { return false }
        return nil
    }

    public static func parse(_ transcript: String, known: [String] = []) -> Command? {
        // "Stop" and "cancel" answer a prompt only inside its window (VoiceLoop
        // uses approvalWord there). Said after the hotkey, "stop" is the Stop command.
        if !["stop", "cancel"].contains(Words(transcript).key), let allow = approvalWord(transcript) {
            return .answer(allow: allow, target: nil)
        }
        let w = Words(transcript).trimmingFillers()
        guard !w.isEmpty else { return .unknown }
        if let c = answer(w) ?? status(w) ?? stop(w) ?? start(w) ?? send(w, known: known) { return c }
        return nil
    }

    // MARK: - Shapes

    private static func answer(_ w: Words) -> Command? {
        for (prefixes, allow) in [(["yes to", "yes for", "yes", "yeah", "approve", "allow", "go ahead for"], true),
                                  (["no to", "no for", "no", "deny", "don't allow", "reject"], false)] {
            guard var rest = w.after(prefixes), !rest.isEmpty, rest.count <= 4, rest.keys.first != "and" else { continue }
            if rest.keys.first == "it" { rest = rest.slice(1..<rest.count) }
            if rest.isEmpty { return .answer(allow: allow, target: nil) }
            return .answer(allow: allow, target: rest.text)
        }
        return nil
    }

    private static func status(_ w: Words) -> Command? {
        if everyone.contains(w.key) { return .status(target: nil) }
        for (pre, post) in statusShapes {
            guard var t = pre.isEmpty ? Optional(w) : w.after([pre]) else { continue }
            if !post.isEmpty { guard let b = t.before([post]) else { continue }; t = b }
            guard !t.isEmpty, t.count <= 5 else { continue }
            if ["everyone", "everybody", "everything"].contains(t.key) { return .status(target: nil) }
            return .status(target: t.text)
        }
        return nil
    }

    private static func stop(_ w: Words) -> Command? {
        if ["stop", "stop it", "stop that", "halt"].contains(w.key) { return .stop(target: nil, now: false) }
        let nowWords = ["right now", "now", "immediately", "at once"]
        if let rest = w.after(["tell", "ask"]), let (t, p) = rest.split(at: ["to"]), !t.isEmpty {
            switch p.key {
            case "stop": return .stop(target: t.text, now: false)
            case "stop now", "stop right now", "stop immediately", "stop at once": return .stop(target: t.text, now: true)
            default: break
            }
        }
        guard var t = w.after(["stop", "halt"]), !t.isEmpty, t.count <= 6 else { return nil }
        var now = false
        if let b = t.before(nowWords) { t = b; now = true }
        if t.isEmpty || pronouns.contains(t.key) { return .stop(target: nil, now: now) }
        return .stop(target: t.text, now: now)
    }

    private static func start(_ w: Words) -> Command? {
        let shapes = ["start a new session in", "start a new session for", "start a new session on",
                      "start a session in", "start a session for", "start a session on", "start new session in",
                      "open a new session in", "open a session in", "new session in", "new session for",
                      "spin up a session in", "start claude in"]
        guard let rest = w.after(shapes) else { return nil }
        guard !rest.isEmpty else { return .unknown }
        if let (p, prompt) = rest.split(at: ["to", "and"]), !p.isEmpty {
            let pr = prompt.trimmingFillers()
            return .start(project: p.text, prompt: pr.isEmpty ? nil : pr.text)
        }
        return .start(project: rest.text, prompt: nil)
    }

    private static func send(_ w: Words, known: [String]) -> Command? {
        // tell X to P, ask X to P, get X to P
        if let rest = w.after(["tell", "ask", "get"]) {
            if let (t, p) = rest.split(at: ["to"]), !t.isEmpty {
                return make(target: t, prompt: p)
            }
            // ask X what / why / how ...: the question is the prompt
            if w.keys.first == "ask", let i = rest.keys.indices.dropFirst().first(where: { questionWords.contains(rest.keys[$0]) }) {
                return make(target: rest.slice(0..<i), prompt: rest.slice(i..<rest.count))
            }
            return nil
        }
        // in X, P / on X: P / for X P (with a known name)
        if let rest = w.after(["in", "on", "for", "over in"]) {
            if let (t, p) = rest.splitAtComma() ?? rest.splitAtKnown(known), !t.isEmpty {
                return make(target: t, prompt: p)
            }
            if rest.said.last?.hasSuffix(",") == true || rest.said.last?.hasSuffix(":") == true { return .unknown }
            return nil
        }
        // send P to X
        if let rest = w.after(["send"]), let i = rest.keys.lastIndex(of: "to"), i > 0, i < rest.count - 1 {
            return make(target: rest.slice((i + 1)..<rest.count), prompt: rest.slice(0..<i))
        }
        return nil
    }

    private static func make(target: Words, prompt: Words) -> Command {
        let p = prompt.trimmingFillers()
        guard !p.isEmpty else { return .unknown }
        let t = Words(target.text)   // drops a trailing comma or colon
        return .send(target: t.isEmpty || pronouns.contains(t.key) ? nil : t.text, prompt: p.text)
    }
}
```

- [ ] **Step 5: Run the tests**

Run: `swift test --package-path app/EarshotKit --filter GrammarTests`
Expected: PASS. A row that fails shows a real gap; fix the grammar, not the row, unless the row is ambiguous English (then move it to `unmatchedGoesToTheModel` and say why in the commit message).

- [ ] **Step 6: Commit**

```bash
git add app/EarshotKit/Sources/EarshotKit/Commands app/EarshotKit/Tests/EarshotKitTests/GrammarTests.swift
git commit -m "Commands: the four commands and voice answers, from a fixed grammar"
```

---

### Task 11: The parser: grammar first, then the on-device model

**Files:**
- Create: `app/EarshotKit/Sources/EarshotKit/Commands/CommandParser.swift`
- Test: `app/EarshotKit/Tests/EarshotKitTests/CommandParserTests.swift`

**Interfaces:**
- Consumes: `Command`, `Grammar` (Task 10).
- Produces:
  - `public protocol CommandModel: Sendable { var isAvailable: Bool { get async }; func prewarm(sessions: [String]) async; func parse(_ text: String, sessions: [String]) async -> Command? }`
  - `public actor FoundationCommandModel: CommandModel` with `init()` and `static func command(action: String, target: String, prompt: String, immediately: Bool) -> Command?`
  - `public struct CommandParser: Sendable` with `init(model: (any CommandModel)?)`, `func parse(_ text: String, sessions: [String]) async -> Command`, `func prewarm(sessions: [String]) async`

- [ ] **Step 1: Write the failing tests**

`app/EarshotKit/Tests/EarshotKitTests/CommandParserTests.swift`:

```swift
import Foundation
import Testing
@testable import EarshotKit

actor FakeModel: CommandModel {
    private(set) var asked: [String] = []
    private(set) var prewarmed = 0
    let available: Bool
    let answer: Command?
    init(available: Bool = true, answer: Command?) { self.available = available; self.answer = answer }
    var isAvailable: Bool { available }
    func prewarm(sessions: [String]) async { prewarmed += 1 }
    func parse(_ text: String, sessions: [String]) async -> Command? { asked.append(text); return answer }
}

@Suite struct CommandParserTests {
    @Test func theGrammarWinsWithoutAskingTheModel() async {
        let model = FakeModel(answer: .unknown)
        let p = CommandParser(model: model)
        #expect(await p.parse("Tell blog to deploy.", sessions: ["blog"]) == .send(target: "blog", prompt: "deploy"))
        #expect(await model.asked.isEmpty)
    }

    @Test func theModelGetsWhatTheGrammarMissed() async {
        let model = FakeModel(answer: .send(target: nil, prompt: "run the tests"))
        let p = CommandParser(model: model)
        #expect(await p.parse("Run the tests.", sessions: ["blog"]) == .send(target: nil, prompt: "run the tests"))
        #expect(await model.asked == ["Run the tests."])
    }

    @Test func noModelMeansUnknown() async {
        #expect(await CommandParser(model: nil).parse("Run the tests.", sessions: []) == .unknown)
        let off = FakeModel(available: false, answer: .status(target: nil))
        #expect(await CommandParser(model: off).parse("Run the tests.", sessions: []) == .unknown)
        let failing = FakeModel(answer: nil)
        #expect(await CommandParser(model: failing).parse("Run the tests.", sessions: []) == .unknown)
    }

    @Test(arguments: [
        ("send", "billing", "run the tests", false, Command.send(target: "billing", prompt: "run the tests")),
        ("send", "", "run the tests", false, .send(target: nil, prompt: "run the tests")),
        ("send", "billing", "", false, .unknown),            // never send an empty prompt
        ("status", "", "", false, .status(target: nil)),
        ("status", "blog", "", false, .status(target: "blog")),
        ("stop", "blog", "", true, .stop(target: "blog", now: true)),
        ("start", "blog", "fix the header", false, .start(project: "blog", prompt: "fix the header")),
        ("start", "", "fix the header", false, .unknown),     // a session needs a folder
        ("approve", "blog", "", false, .answer(allow: true, target: "blog")),
        ("deny", "", "", false, .answer(allow: false, target: nil)),
        ("unknown", "", "", false, .unknown),
        ("dance", "", "", false, .unknown),
    ] as [(String, String, String, Bool, Command)])
    func modelOutputMapsToACommand(_ action: String, _ target: String, _ prompt: String, _ now: Bool, _ expected: Command) {
        #expect(FoundationCommandModel.command(action: action, target: target, prompt: prompt, immediately: now) == expected)
    }

    @Test func prewarmReachesTheModel() async {
        let model = FakeModel(answer: nil)
        await CommandParser(model: model).prewarm(sessions: ["blog"])
        #expect(await model.prewarmed == 1)
    }

    /// Needs Apple Intelligence on: EARSHOT_TEST_FM=1.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["EARSHOT_TEST_FM"] == "1"))
    func theRealModelUnderstandsAFreeformCommand() async {
        let m = FoundationCommandModel()
        #expect(await m.isAvailable)
        let c = await m.parse("could billing service maybe run the integration tests again",
                              sessions: ["billing service", "blog"])
        guard case .send(let target, let prompt) = c else { Issue.record("got \(String(describing: c))"); return }
        #expect(target?.lowercased().contains("billing") == true)
        #expect(prompt.lowercased().contains("integration tests"))
    }
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `swift test --package-path app/EarshotKit --filter CommandParserTests`
Expected: FAIL to compile.

- [ ] **Step 3: Write the parser**

`app/EarshotKit/Sources/EarshotKit/Commands/CommandParser.swift`:

```swift
import Foundation
import FoundationModels
import os

/// Understands what the grammar does not.
public protocol CommandModel: Sendable {
    var isAvailable: Bool { get async }
    /// Called when the wake word or hotkey fires, so the model is ready by the end of the command.
    func prewarm(sessions: [String]) async
    /// nil when the model failed.
    func parse(_ text: String, sessions: [String]) async -> Command?
}

public struct CommandParser: Sendable {
    let model: (any CommandModel)?

    public init(model: (any CommandModel)?) { self.model = model }

    public func parse(_ text: String, sessions: [String]) async -> Command {
        if let c = Grammar.parse(text, known: sessions) { return c }
        guard let model, await model.isAvailable, let c = await model.parse(text, sessions: sessions) else { return .unknown }
        return c
    }

    public func prewarm(sessions: [String]) async { await model?.prewarm(sessions: sessions) }
}

@Generable
struct ParsedCommand {
    @Guide(description: "What the user asked for.", .anyOf(["send", "status", "stop", "start", "approve", "deny", "unknown"]))
    var action: String
    @Guide(description: "The session or project the user named, in their words. Empty when they named none.")
    var target: String
    @Guide(description: "For send and start: the request to pass on, in the user's own words. Empty otherwise. Never invent one.")
    var prompt: String
    @Guide(description: "For stop: true only when the user said now, right now or immediately.")
    var immediately: Bool
}

/// Apple's on-device model. A fresh session per command, made and prewarmed
/// when the wake word or hotkey fires.
public actor FoundationCommandModel: CommandModel {
    private var ready: LanguageModelSession?
    private var readyFor: [String] = []
    private let log = Logger(subsystem: "com.earshot.app", category: "parser")

    public init() {}

    public var isAvailable: Bool { SystemLanguageModel.default.isAvailable }

    public func prewarm(sessions: [String]) async {
        guard SystemLanguageModel.default.isAvailable else { return }
        let s = Self.session(sessions)
        s.prewarm()
        ready = s
        readyFor = sessions
    }

    public func parse(_ text: String, sessions: [String]) async -> Command? {
        let session = (readyFor == sessions ? ready : nil) ?? Self.session(sessions)
        ready = nil
        do {
            let r = try await session.respond(to: text, generating: ParsedCommand.self)
            let p = r.content
            return Self.command(action: p.action, target: p.target, prompt: p.prompt, immediately: p.immediately)
        } catch {
            log.error("the model failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    static func session(_ sessions: [String]) -> LanguageModelSession {
        LanguageModelSession(instructions: """
            You read one spoken command for Earshot, a voice assistant that controls Claude Code coding sessions, \
            and say what it asks for.
            Actions: send (pass a request to a session), status (ask what a session or everyone is doing), \
            stop (stop a session), start (start a new session in a project folder), approve or deny (answer a \
            permission prompt), unknown (anything else, or when you are not sure).
            Open sessions: \(sessions.isEmpty ? "none" : sessions.joined(separator: ", ")).
            Keep the user's own words for the target and the prompt. Never invent a prompt.
            """)
    }

    /// The model's answer as a command; nil for an action that needs
    /// something the user did not say.
    static func command(action: String, target: String, prompt: String, immediately: Bool) -> Command? {
        let t = target.trimmingCharacters(in: .whitespacesAndNewlines)
        let p = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = t.isEmpty ? nil : t
        switch action {
        case "send": return p.isEmpty ? .unknown : .send(target: target, prompt: p)
        case "status": return .status(target: target)
        case "stop": return .stop(target: target, now: immediately)
        case "start": return t.isEmpty ? .unknown : .start(project: t, prompt: p.isEmpty ? nil : p)
        case "approve": return .answer(allow: true, target: target)
        case "deny": return .answer(allow: false, target: target)
        default: return .unknown
        }
    }
}
```

`command(action:…)` returns `Command?` but every branch returns a value; `CommandParser` treats `nil` (a failed call) and `.unknown` alike.

- [ ] **Step 4: Run the tests**

Run: `swift test --package-path app/EarshotKit --filter CommandParserTests`
Expected: PASS (the live model test skips).

With Apple Intelligence on: `EARSHOT_TEST_FM=1 swift test --package-path app/EarshotKit --filter theRealModel`
Expected: PASS. Task 21 runs the full 100-case eval.

- [ ] **Step 5: Commit**

```bash
git add app/EarshotKit/Sources/EarshotKit/Commands/CommandParser.swift app/EarshotKit/Tests/EarshotKitTests/CommandParserTests.swift
git commit -m "Commands: the on-device model for what the grammar misses"
```

---
### Task 12: Find and run `claude`, and read its session list

**Files:**
- Create: `app/EarshotKit/Sources/EarshotKit/Sessions/ClaudeCLI.swift`
- Test: `app/EarshotKit/Tests/EarshotKitTests/ClaudeCLITests.swift`

**Interfaces:**
- Produces:
  - `public struct RunResult: Sendable, Equatable { var status: Int32; var stdout: Data; var stderr: String }`
  - `public protocol ClaudeRunner: Sendable { func run(_ args: [String], cwd: String?, timeout: Duration) async -> RunResult; func version() async -> String? }`
  - `public struct AgentEntry: Decodable, Sendable, Equatable` with `sessionId`, `pid: Int32?`, `cwd`, `kind`, `name: String?`, `status: String?`, `state: String?`, `isBackground`, `isBusy`, `isWaiting`, and `static func decodeList(_ data: Data) -> [AgentEntry]` (skips entries it cannot read)
  - `public final class ClaudeCLI: ClaudeRunner` with `init(path: String)` and `static func locate(home: String, isExecutable: (String) -> Bool, loginShell: () -> String?) -> String?`, `static func locate() -> String?` (the real one)

- [ ] **Step 1: Write the failing tests**

`app/EarshotKit/Tests/EarshotKitTests/ClaudeCLITests.swift`:

```swift
import Foundation
import Testing
@testable import EarshotKit

@Suite struct ClaudeCLITests {
    /// The shape `claude agents --json` printed on 2026-10-11 (Claude Code 2.1.296).
    static let agentsJSON = #"""
    [
      {"id":"2bc20c28","cwd":"/Users/me/wedding","kind":"background","startedAt":1782868923593,
       "sessionId":"2bc20c28-fe31-4c8d-be2f-cddffee12b94","name":"Create guest confirmation email with event details","state":"blocked"},
      {"pid":2030,"cwd":"/Users/me/blog","kind":"interactive","startedAt":1790640209107,
       "sessionId":"3b4f70dd-8dd4-4425-b46d-e2b2e85b6ad9","name":"blog-83","status":"idle"},
      {"pid":2031,"cwd":"/Users/me/billing-service","kind":"interactive","startedAt":1790640209188,
       "sessionId":"4cf0687b-7105-4ee3-a83f-33b5fdf86559","name":"Fix refund rounding","status":"busy"},
      {"pid":"not a number","sessionId":"broken"}
    ]
    """#

    @Test func readsTheSessionList() {
        let list = AgentEntry.decodeList(Data(Self.agentsJSON.utf8))
        #expect(list.map(\.sessionId) == ["2bc20c28-fe31-4c8d-be2f-cddffee12b94", "3b4f70dd-8dd4-4425-b46d-e2b2e85b6ad9",
                                          "4cf0687b-7105-4ee3-a83f-33b5fdf86559"])
        #expect(list[0].isBackground && list[0].pid == nil)
        #expect(list[1].pid == 2030 && !list[1].isBusy)
        #expect(list[2].isBusy)
    }

    @Test func notJSONIsAnEmptyList() {
        #expect(AgentEntry.decodeList(Data("Error: not signed in".utf8)).isEmpty)
    }

    @Test func locatePrefersTheUsualPlaces() {
        let found = ClaudeCLI.locate(home: "/Users/me", isExecutable: { $0 == "/opt/homebrew/bin/claude" },
                                     loginShell: { Issue.record("asked the shell"); return nil })
        #expect(found == "/opt/homebrew/bin/claude")
        #expect(ClaudeCLI.locate(home: "/Users/me", isExecutable: { $0 == "/Users/me/.local/bin/claude" },
                                 loginShell: { nil }) == "/Users/me/.local/bin/claude")
    }

    @Test func locateAsksTheLoginShellLast() {
        #expect(ClaudeCLI.locate(home: "/Users/me", isExecutable: { $0 == "/nix/bin/claude" },
                                 loginShell: { "/nix/bin/claude" }) == "/nix/bin/claude")
        #expect(ClaudeCLI.locate(home: "/Users/me", isExecutable: { _ in false }, loginShell: { nil }) == nil)
    }

    @Test func runsAProgramAndReadsItsOutput() async {
        let r = await ClaudeCLI(path: "/bin/echo").run(["hello"], cwd: "/tmp", timeout: .seconds(5))
        #expect(r.status == 0)
        #expect(String(decoding: r.stdout, as: UTF8.self) == "hello\n")
    }

    @Test func aSlowProgramIsStopped() async {
        let start = ContinuousClock.now
        let r = await ClaudeCLI(path: "/bin/sleep").run(["10"], cwd: nil, timeout: .milliseconds(300))
        #expect(r.status != 0)
        #expect(ContinuousClock.now - start < .seconds(3))
    }

    @Test func aMissingProgramFails() async {
        let r = await ClaudeCLI(path: "/nonexistent/claude").run(["--version"], cwd: nil, timeout: .seconds(1))
        #expect(r.status == -1)
    }
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `swift test --package-path app/EarshotKit --filter ClaudeCLITests`
Expected: FAIL to compile.

- [ ] **Step 3: Write the code**

`app/EarshotKit/Sources/EarshotKit/Sessions/ClaudeCLI.swift`:

```swift
import Foundation
import Synchronization

public struct RunResult: Sendable, Equatable {
    public var status: Int32
    public var stdout: Data
    public var stderr: String
    public init(status: Int32, stdout: Data = Data(), stderr: String = "") {
        self.status = status; self.stdout = stdout; self.stderr = stderr
    }
}

public protocol ClaudeRunner: Sendable {
    func run(_ args: [String], cwd: String?, timeout: Duration) async -> RunResult
    /// Claude Code's version, "2.1.296", or nil.
    func version() async -> String?
}

/// One entry of `claude agents --json`.
public struct AgentEntry: Decodable, Sendable, Equatable {
    public let sessionId: String
    public let pid: Int32?
    public let cwd: String
    public let kind: String
    public let name: String?
    /// busy, idle or waiting, for sessions with a process.
    public let status: String?
    /// For background sessions without a process, for example blocked.
    public let state: String?

    public init(sessionId: String, pid: Int32?, cwd: String, kind: String, name: String? = nil, status: String? = nil,
                state: String? = nil) {
        self.sessionId = sessionId; self.pid = pid; self.cwd = cwd; self.kind = kind
        self.name = name; self.status = status; self.state = state
    }

    public var isBackground: Bool { kind == "background" }
    public var isBusy: Bool { status == "busy" }
    public var isWaiting: Bool { status == "waiting" }

    public static func decodeList(_ data: Data) -> [AgentEntry] {
        guard let items = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return [] }
        return items.compactMap { item in
            guard let d = try? JSONSerialization.data(withJSONObject: item) else { return nil }
            return try? JSONDecoder().decode(AgentEntry.self, from: d)
        }
    }
}

/// Runs the claude command line. Apps opened from the Dock get a short PATH,
/// so the binary is found once, at launch.
public final class ClaudeCLI: ClaudeRunner {
    public let path: String
    private let cachedVersion = Mutex<String??>(nil)

    public init(path: String) { self.path = path }

    public static func locate() -> String? {
        locate(home: NSHomeDirectory(), isExecutable: { FileManager.default.isExecutableFile(atPath: $0) },
               loginShell: loginShellLookup)
    }

    public static func locate(home: String, isExecutable: (String) -> Bool, loginShell: () -> String?) -> String? {
        let usual = ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude",
                     "\(home)/.claude/local/claude"]
        if let p = usual.first(where: isExecutable) { return p }
        if let p = loginShell(), p.hasPrefix("/"), isExecutable(p) { return p }
        return nil
    }

    /// Asks the login shell once: it has the PATH the user set up.
    static func loginShellLookup() -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lic", "command -v claude"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").last
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    public func run(_ args: [String], cwd: String?, timeout: Duration) async -> RunResult {
        let path = self.path
        let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
        return await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: path)
                p.arguments = args
                if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
                var env = ProcessInfo.processInfo.environment
                let dir = (path as NSString).deletingLastPathComponent
                env["PATH"] = "\(dir):/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
                p.environment = env
                let out = Pipe(), err = Pipe()
                p.standardOutput = out
                p.standardError = err
                p.standardInput = FileHandle.nullDevice
                do { try p.run() } catch {
                    cont.resume(returning: RunResult(status: -1, stderr: error.localizedDescription))
                    return
                }
                let timer = DispatchWorkItem { if p.isRunning { p.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: timer)
                let o = out.fileHandleForReading.readDataToEndOfFile()
                let e = err.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                timer.cancel()
                cont.resume(returning: RunResult(status: p.terminationStatus, stdout: o,
                                                 stderr: String(decoding: e, as: UTF8.self)))
            }
        }
    }

    public func version() async -> String? {
        if let v = cachedVersion.withLock({ $0 }) { return v }
        let r = await run(["--version"], cwd: nil, timeout: .seconds(5))
        let v = r.status == 0 ? String(decoding: r.stdout, as: UTF8.self).split(separator: " ").first.map(String.init) : nil
        cachedVersion.withLock { $0 = .some(v) }
        return v
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `swift test --package-path app/EarshotKit --filter ClaudeCLITests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/EarshotKit/Sources/EarshotKit/Sessions/ClaudeCLI.swift app/EarshotKit/Tests/EarshotKitTests/ClaudeCLITests.swift
git commit -m "Sessions: find claude from a Dock-launched app, run it with a time limit, read agents JSON"
```

---

### Task 13: Spoken names and labels

The app's port of the plugin's naming (`session_names` and `label` in `plugin/scripts/speak.sh`), plus labels from the on-device model, written back to the plugin's live file as line 3 so the plugin says the same name.

**Files:**
- Create: `app/EarshotKit/Sources/EarshotKit/Sessions/SpokenNames.swift`
- Create: `app/EarshotKit/Sources/EarshotKit/Sessions/Labeler.swift`
- Test: `app/EarshotKit/Tests/EarshotKitTests/SpokenNamesTests.swift`

**Interfaces:**
- Produces:
  - `public enum SpokenNames` with `static func project(cwd: String, home: String, isGitRoot: (String) -> Bool) -> String`, `static func project(cwd: String) -> String` (real file system), `static func ruleLabel(_ title: String) -> String`, `struct Entry: Sendable, Equatable { id, project, title, label }`, `static func names(_ entries: [Entry]) -> [String: String]`, `static func isDefaultName(_ name: String, cwd: String) -> Bool`.
  - `public protocol LabelModel: Sendable { func label(for title: String) async -> String? }`, `public struct FoundationLabelModel: LabelModel`.
  - `public actor Labeler` with `init(model: (any LabelModel)?, liveDir: String = ApprovalBook.defaultStateDir + "/live")` and `func label(session: String, title: String) async -> String`.

- [ ] **Step 1: Write the failing tests**

`app/EarshotKit/Tests/EarshotKitTests/SpokenNamesTests.swift`:

```swift
import Foundation
import Testing
@testable import EarshotKit

@Suite struct SpokenNamesTests {
    @Test(arguments: [
        ("/Users/me/code/billing_service", "billing service"),
        ("/Users/me/code/billingService", "billing Service"),
        ("/Users/me/code/finebrief.app", "finebrief app"),
        ("/Users/me/code/billing-service/src/api", "billing service"),   // the git root
        ("/Users/me", "your home folder"),
    ])
    func projectNames(_ cwd: String, _ expected: String) {
        let roots: Set<String> = ["/Users/me/code/billing-service", "/Users/me/code/billing_service",
                                  "/Users/me/code/billingService", "/Users/me/code/finebrief.app"]
        #expect(SpokenNames.project(cwd: cwd, home: "/Users/me", isGitRoot: roots.contains) == expected)
    }

    /// The label rule, on real titles (same cases as the plugin's tests).
    @Test(arguments: [
        ("Create guest confirmation email with event details", "guest confirmation email"),
        ("Fix refund rounding", "Fix refund rounding"),
        ("Orchestrator agent for multi-session voice control", "Orchestrator agent"),
        ("Add a dark mode toggle to the settings page", "dark mode toggle"),
        ("Debug the flaky invoice test session", "flaky invoice test"),
        ("Investigate why_the_build fails on CI", "Investigate why build"),   // articles go anywhere
        ("Update the", "Update the"),
    ])
    func ruleLabels(_ title: String, _ expected: String) {
        #expect(SpokenNames.ruleLabel(title) == expected)
    }

    @Test func theProjectWhenItIsTheOnlySessionThere() {
        let n = SpokenNames.names([.init(id: "a", project: "billing service", title: "Fix refund rounding", label: "refund rounding"),
                                   .init(id: "b", project: "blog", title: "", label: "")])
        #expect(n["a"] == "billing service")
        #expect(n["b"] == "blog")
    }

    @Test func theLabelWhenTwoShareAProject() {
        let n = SpokenNames.names([.init(id: "a", project: "billing service", title: "Fix refund rounding", label: "refund rounding"),
                                   .init(id: "b", project: "billing service", title: "Invoice export", label: "invoices")])
        #expect(n["a"] == "the refund rounding session")
        #expect(n["b"] == "the invoices session")
    }

    @Test func labelAndProjectWhenTheLabelClashes() {
        let n = SpokenNames.names([.init(id: "a", project: "billing service", title: "Tests", label: "tests"),
                                   .init(id: "b", project: "billing service", title: "Docs", label: "docs"),
                                   .init(id: "c", project: "blog", title: "Tests", label: "Tests")])
        #expect(n["a"] == "tests in billing service")
        #expect(n["b"] == "the docs session")
        #expect(n["c"] == "blog")   // the only blog session
    }

    @Test func aSessionWithoutATitleIsItsProject() {
        let n = SpokenNames.names([.init(id: "a", project: "blog", title: "", label: ""),
                                   .init(id: "b", project: "blog", title: "Fix RSS", label: "Fix RSS")])
        #expect(n["a"] == "blog")
        #expect(n["b"] == "the Fix RSS session")
    }

    @Test func defaultNamesAreNotTitles() {
        #expect(SpokenNames.isDefaultName("blog-83", cwd: "/Users/me/blog"))
        #expect(SpokenNames.isDefaultName("projects-2c", cwd: "/Users/me/Projects"))
        #expect(!SpokenNames.isDefaultName("Fix refund rounding", cwd: "/Users/me/billing"))
        #expect(!SpokenNames.isDefaultName("blog-redesign", cwd: "/Users/me/blog"))
    }

    struct FixedModel: LabelModel {
        let answer: String?
        func label(for title: String) async -> String? { answer }
    }

    @Test func shortTitlesAreUsedAsTheyAre() async {
        let l = Labeler(model: FixedModel(answer: "should not be asked"), liveDir: NSTemporaryDirectory())
        #expect(await l.label(session: "s", title: "Fix RSS feed") == "Fix RSS feed")
    }

    @Test func theModelShortensLongTitles() async {
        let l = Labeler(model: FixedModel(answer: "voice orchestrator"), liveDir: NSTemporaryDirectory())
        #expect(await l.label(session: "s", title: "Orchestrator agent for multi-session voice control") == "voice orchestrator")
    }

    @Test func aBadModelAnswerFallsBackToTheRule() async {
        let l = Labeler(model: FixedModel(answer: "a label that is far too long to say"), liveDir: NSTemporaryDirectory())
        #expect(await l.label(session: "s", title: "Create guest confirmation email with event details") == "guest confirmation email")
        let none = Labeler(model: nil, liveDir: NSTemporaryDirectory())
        #expect(await none.label(session: "s", title: "Create guest confirmation email with event details") == "guest confirmation email")
    }

    /// The plugin keeps line 3 while the title is the same.
    @Test func theLabelIsWrittenToThePluginsLiveFile() async throws {
        let dir = NSTemporaryDirectory() + "ek-live-\(UUID().uuidString.prefix(6))"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let title = "Orchestrator agent for multi-session voice control"
        try "earshot\n\(title)\n".write(toFile: "\(dir)/s1", atomically: true, encoding: .utf8)
        try "blog\nOther title\n".write(toFile: "\(dir)/s2", atomically: true, encoding: .utf8)
        let l = Labeler(model: FixedModel(answer: "voice orchestrator"), liveDir: dir)
        _ = await l.label(session: "s1", title: title)
        _ = await l.label(session: "s2", title: "A different title than the file has now")
        #expect(try String(contentsOfFile: "\(dir)/s1", encoding: .utf8) == "earshot\n\(title)\nvoice orchestrator\n")
        #expect(try String(contentsOfFile: "\(dir)/s2", encoding: .utf8) == "blog\nOther title\n")   // stale: left alone
        #expect(!FileManager.default.fileExists(atPath: "\(dir)/s3"))   // never created
    }
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `swift test --package-path app/EarshotKit --filter SpokenNamesTests`
Expected: FAIL to compile.

- [ ] **Step 3: Write SpokenNames**

`app/EarshotKit/Sources/EarshotKit/Sessions/SpokenNames.swift`:

```swift
import Foundation

/// How sessions are said out loud. A port of speak.sh, so the app and the
/// plugin name a session the same way.
public enum SpokenNames {
    /// speak.sh's proj: the git root's folder, with _ . - as spaces and
    /// camelCase split. The home folder is "your home folder".
    public static func project(cwd: String, home: String, isGitRoot: (String) -> Bool) -> String {
        var dir = (cwd as NSString).standardizingPath
        var root = dir
        while dir != "/" && !dir.isEmpty {
            if isGitRoot(dir) { root = dir; break }
            dir = (dir as NSString).deletingLastPathComponent
        }
        if root == (home as NSString).standardizingPath { return "your home folder" }
        let base = (root as NSString).lastPathComponent
        var out = ""
        var prev: Character?
        for c in base {
            let ch: Character = "_.-".contains(c) ? " " : c
            if let p = prev, p.isLowercase, ch.isUppercase { out.append(" ") }
            out.append(ch)
            prev = ch
        }
        return out
    }

    public static func project(cwd: String) -> String {
        project(cwd: cwd, home: NSHomeDirectory()) { FileManager.default.fileExists(atPath: $0 + "/.git") }
    }

    static let verbs: Set<String> = ["fix", "add", "create", "make", "update", "build", "write", "check", "debug",
                                     "refactor", "implement"]
    static let articles: Set<String> = ["a", "an", "the"]
    static let stops: Set<String> = ["for", "with", "and", "to", "in", "on", "of", "vs"]

    /// speak.sh's label(): 1 to 3 words for a title.
    public static func ruleLabel(_ title: String) -> String {
        var t = title.map { "_/-".contains($0) ? " " : $0 }.reduce(into: "") { $0.append($1) }
        if t.lowercased().hasSuffix(" session") { t = String(t.dropLast(" session".count)) }
        let w = t.split(separator: " ").map(String.init)
        if w.count <= 3 { return w.joined(separator: " ") }
        var out: [String] = []
        for (i, word) in w.enumerated() {
            let lw = word.lowercased()
            if i == 0 && verbs.contains(lw) { continue }
            if articles.contains(lw) { continue }
            if !out.isEmpty && stops.contains(lw) { break }
            out.append(word)
            if out.count == 3 { break }
        }
        return out.isEmpty ? w.prefix(3).joined(separator: " ") : out.joined(separator: " ")
    }

    public struct Entry: Sendable, Equatable {
        public let id: String
        public let project: String
        public let title: String
        public let label: String
        public init(id: String, project: String, title: String, label: String) {
            self.id = id; self.project = project; self.title = title; self.label = label
        }
    }

    /// The shortest name that is unique among these sessions: the project
    /// when it is the only one there; else "the <label> session" when no
    /// other session has that label; else "<label> in <project>".
    public static func names(_ entries: [Entry]) -> [String: String] {
        var out: [String: String] = [:]
        for e in entries {
            let others = entries.filter { $0.id != e.id }
            let twins = others.filter { $0.project == e.project }.count
            if e.title.isEmpty || e.label.isEmpty || twins == 0 {
                out[e.id] = e.project
                continue
            }
            let clash = others.contains { $0.label.lowercased() == e.label.lowercased() }
            out[e.id] = clash ? "\(e.label) in \(e.project)" : "the \(e.label) session"
        }
        return out
    }

    /// Claude Code names an untitled session after its folder and a short
    /// hex suffix ("blog-83"). That is not a title.
    public static func isDefaultName(_ name: String, cwd: String) -> Bool {
        let base = (cwd as NSString).lastPathComponent.lowercased()
        guard name.lowercased().hasPrefix(base + "-") else { return false }
        let suffix = name.dropFirst(base.count + 1)
        return (1...4).contains(suffix.count) && suffix.allSatisfy(\.isHexDigit)
    }
}
```

- [ ] **Step 4: Write the Labeler**

`app/EarshotKit/Sources/EarshotKit/Sessions/Labeler.swift`:

```swift
import Darwin
import Foundation
import FoundationModels

public protocol LabelModel: Sendable {
    /// A 1 to 3 word noun phrase for a session title, or nil.
    func label(for title: String) async -> String?
}

@Generable
struct ShortLabel {
    @Guide(description: "A 1 to 3 word noun phrase that names the work, to say out loud. No verbs at the start, no punctuation.")
    var label: String
}

public struct FoundationLabelModel: LabelModel {
    public init() {}
    public func label(for title: String) async -> String? {
        guard SystemLanguageModel.default.isAvailable else { return nil }
        let s = LanguageModelSession(instructions: """
            You name coding sessions so a voice assistant can say them often. Turn the session title into a 1 to 3 \
            word noun phrase. Example: "Orchestrator agent for multi-session voice control" becomes "voice orchestrator".
            """)
        return try? await s.respond(to: title, generating: ShortLabel.self).content.label
    }
}

/// Labels for session titles, cached by session and title. A label the
/// model made is written to the plugin's live file as line 3, so the
/// plugin's alerts use it too.
public actor Labeler {
    private let model: (any LabelModel)?
    private let liveDir: String
    private var cache: [String: String] = [:]

    public init(model: (any LabelModel)?, liveDir: String = ApprovalBook.defaultStateDir + "/live") {
        self.model = model
        self.liveDir = liveDir
    }

    public func label(session: String, title: String) async -> String {
        let key = session + "\u{1f}" + title
        if let l = cache[key] { return l }
        let words = title.split(separator: " ")
        var label: String
        if words.count <= 3 {
            label = title
        } else if let m = await model?.label(for: title), Self.usable(m) {
            label = m.trimmingCharacters(in: .whitespacesAndNewlines)
            writeLiveLabel(session: session, title: title, label: label)
        } else {
            label = SpokenNames.ruleLabel(title)
        }
        cache[key] = label
        return label
    }

    static func usable(_ s: String) -> Bool {
        let w = s.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
        return (1...3).contains(w.count) && w.allSatisfy { $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "'" } }
    }

    /// Only into a file the plugin made, while its title (line 2) is this one.
    private func writeLiveLabel(session: String, title: String, label: String) {
        guard ApprovalBook.safe(session) else { return }
        let path = "\(liveDir)/\(session)"
        var st = stat()
        guard lstat(path, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_uid == getuid(),
              let text = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.count >= 2, lines[1] == title else { return }
        let tmp = "\(path).app-\(UUID().uuidString.prefix(6))"
        guard (try? "\(lines[0])\n\(title)\n\(label)\n".write(toFile: tmp, atomically: false, encoding: .utf8)) != nil else { return }
        chmod(tmp, 0o600)
        if rename(tmp, path) != 0 { unlink(tmp) }
    }
}
```

- [ ] **Step 5: Run the tests**

Run: `swift test --package-path app/EarshotKit --filter SpokenNamesTests`
Expected: PASS.

- [ ] **Step 6: Check the rule matches the plugin's**

Run each title through the plugin and compare with `ruleLabels` above:

```bash
for t in "Create guest confirmation email with event details" "Orchestrator agent for multi-session voice control" "Add a dark mode toggle to the settings page" "Debug the flaky invoice test session" "Investigate why_the_build fails on CI"; do EARSHOT_LABEL_TEST="$t" bash plugin/scripts/speak.sh label </dev/null; done
```

Expected: the same five labels, in order. (`speak.sh label` exits before reading hook input. It needs `/voice` on, or it exits silently; if it prints nothing, turn `/voice` on.)

- [ ] **Step 7: Commit**

```bash
git add app/EarshotKit/Sources/EarshotKit/Sessions/SpokenNames.swift app/EarshotKit/Sources/EarshotKit/Sessions/Labeler.swift app/EarshotKit/Tests/EarshotKitTests/SpokenNamesTests.swift
git commit -m "Sessions: the plugin's spoken names in Swift, and model labels for long titles"
```

---

### Task 14: The session directory and the roll call

**Files:**
- Modify: `app/EarshotKit/Sources/EarshotKit/Core/SessionStore.swift` (keep `project` and `title`)
- Create: `app/EarshotKit/Sources/EarshotKit/Sessions/SessionDirectory.swift`
- Create: `app/EarshotKit/Sources/EarshotKit/Sessions/RollCall.swift`
- Test: `app/EarshotKit/Tests/EarshotKitTests/SessionDirectoryTests.swift`

**Interfaces:**
- Consumes: `ClaudeRunner`, `AgentEntry` (Task 12), `SpokenNames`, `Labeler` (Task 13), `SessionStore` and `SessionInfo` (plan 1).
- Produces:
  - `SessionInfo` gains `project: String?` and `title: String?`.
  - `public struct LiveSession: Sendable, Equatable, Identifiable` with `id`, `pid: Int32?`, `kind`, `cwd`, `project`, `title`, `label`, `name`, `busy`, `waiting`, `state: SessionState?`, `detail: String?`, `since: Date?`, `isBackground`.
  - `public struct KnownProject: Sendable, Equatable { name, path, trusted }`
  - `public actor SessionDirectory` with `init(runner: any ClaudeRunner, store: SessionStore, labeler: Labeler, claudeJSON: String = NSHomeDirectory() + "/.claude.json", clock: @escaping @Sendable () -> Date = Date.init)`, `func refresh() async`, `func refresh(ifOlderThan seconds: TimeInterval) async`, `var sessions: [LiveSession]`, `func session(_ id: String) -> LiveSession?`, `func noteSpoke(about session: String)`, `func resolve(_ target: String?) -> SessionDirectory.Match`, `func resolve(_ target: String, among ids: [String]) -> SessionDirectory.Match`, `func vocabulary() -> [String]`, `func knownProjects() -> [KnownProject]`, `func matchProject(_ spoken: String) -> KnownProject?`.
  - `public enum Match: Sendable, Equatable { case one(LiveSession), several([LiveSession]), none, noTarget }`
  - `public enum NameMatch` with `static func normalize(_ s: String) -> String` and `static func score(_ spoken: String, _ candidate: String) -> Double` (0 to 1).
  - `public enum RollCall` with `static func line(_ sessions: [LiveSession], now: Date) -> String` and `static func sentence(_ s: LiveSession, now: Date) -> String`.

- [ ] **Step 1: Keep project and title in the store**

In `SessionStore.swift`, add to `SessionInfo`:

```swift
    public var project: String?
    public var title: String?
```

In `apply`, replace the `SessionInfo(...)` construction:

```swift
            let old = byID[status.session]
            byID[status.session] = SessionInfo(id: status.session, name: name, state: status.state,
                                               detail: status.detail, updated: clock(),
                                               project: status.project ?? old?.project, title: status.title ?? old?.title)
```

Run: `swift test --package-path app/EarshotKit --filter CoreTests`
Expected: PASS (the two new optional properties default to nil in the memberwise init, so existing code compiles unchanged).

- [ ] **Step 2: Write the failing tests**

`app/EarshotKit/Tests/EarshotKitTests/SessionDirectoryTests.swift`:

```swift
import Foundation
import Testing
@testable import EarshotKit

/// claude, scripted: agents JSON, and every call recorded.
actor FakeRunner: ClaudeRunner {
    var agents: [AgentEntry]
    var results: [String: RunResult] = [:]   // by first argument
    private(set) var calls: [(args: [String], cwd: String?)] = []
    init(_ agents: [AgentEntry]) { self.agents = agents }
    func setAgents(_ a: [AgentEntry]) { agents = a }
    func setResult(_ first: String, _ r: RunResult) { results[first] = r }
    func run(_ args: [String], cwd: String?, timeout: Duration) async -> RunResult {
        calls.append((args, cwd))
        if args.first == "agents" {
            let objs: [[String: Any]] = agents.map { a in
                var d: [String: Any] = ["sessionId": a.sessionId, "cwd": a.cwd, "kind": a.kind]
                if let p = a.pid { d["pid"] = p }
                if let n = a.name { d["name"] = n }
                if let s = a.status { d["status"] = s }
                if let s = a.state { d["state"] = s }
                return d
            }
            return RunResult(status: 0, stdout: try! JSONSerialization.data(withJSONObject: objs))
        }
        return results[args.first ?? ""] ?? RunResult(status: 0)
    }
    func version() async -> String? { "2.1.296" }
    var argLists: [[String]] { calls.map(\.args) }
}

func agent(_ id: String, _ dir: String, name: String? = nil, pid: Int32? = 100, kind: String = "interactive",
           status: String? = "idle") -> AgentEntry {
    AgentEntry(sessionId: id, pid: pid, cwd: "/p/\(dir)", kind: kind, name: name, status: status)
}

@Suite struct SessionDirectoryTests {
    let store = SessionStore()
    let labeler = Labeler(model: nil, liveDir: NSTemporaryDirectory())

    func directory(_ agents: [AgentEntry], now: @escaping @Sendable () -> Date = Date.init,
                   claudeJSON: String = "/nonexistent") async -> (SessionDirectory, FakeRunner) {
        let runner = FakeRunner(agents)
        let d = SessionDirectory(runner: runner, store: store, labeler: labeler, claudeJSON: claudeJSON, clock: now)
        await d.refresh()
        return (d, runner)
    }

    @Test func namesFollowTheShortestUniqueRule() async {
        let (d, _) = await directory([agent("a", "billing-service", name: "Fix refund rounding"),
                                      agent("b", "billing-service", name: "Invoice export"),
                                      agent("c", "blog", name: "blog-83")])
        let names = await d.sessions.map(\.name).sorted()
        #expect(names == ["blog", "the Fix refund rounding session", "the Invoice export session"])
    }

    @Test func thePluginsStatusAndTitleWin() async {
        await store.apply(.init(session: "a", state: .needs, detail: "needs your OK to run the migration",
                                name: "billing service", project: "billing service", title: "Refund rounding"))
        let (d, _) = await directory([agent("a", "billing-service", name: "billing-service-1f")])
        let s = await d.session("a")
        #expect(s?.state == .needs)
        #expect(s?.title == "Refund rounding")
        #expect(s?.detail == "needs your OK to run the migration")
    }

    @Test(arguments: [
        ("billing service", "a"), ("Billing Service", "a"), ("billing services", "a"), ("the billing service", "a"),
        ("fine brief", "b"), ("finebrief", "b"), ("blog", "c"), ("the blog session", "c"),
    ])
    func matchesSpokenNames(_ said: String, _ id: String) async {
        let (d, _) = await directory([agent("a", "billing-service"), agent("b", "finebrief"), agent("c", "blog")])
        guard case .one(let s) = await d.resolve(said) else { Issue.record("no single match for \(said)"); return }
        #expect(s.id == id)
    }

    @Test func twoSessionsInOneProjectAreBothMatches() async {
        let (d, _) = await directory([agent("a", "billing-service", name: "Fix refund rounding"),
                                      agent("b", "billing-service", name: "Invoice export"), agent("c", "blog")])
        guard case .several(let list) = await d.resolve("billing") else { Issue.record("expected several"); return }
        #expect(Set(list.map(\.id)) == ["a", "b"])
        guard case .one(let s) = await d.resolve("invoice export") else { Issue.record("label"); return }
        #expect(s.id == "b")
        guard case .one(let r) = await d.resolve("refund rounding in billing service") else { Issue.record("label in project"); return }
        #expect(r.id == "a")
    }

    @Test func anUnknownNameIsNone() async {
        let (d, _) = await directory([agent("a", "billing-service"), agent("c", "blog")])
        #expect(await d.resolve("payments") == .none)
    }

    @Test func noTargetIsTheOnlySession() async {
        let (d, _) = await directory([agent("c", "blog")])
        guard case .one(let s) = await d.resolve(nil) else { Issue.record("expected one"); return }
        #expect(s.id == "c")
    }

    @Test func noTargetIsTheLastSpokenAboutForTwoMinutes() async {
        let now = Box(Date(timeIntervalSince1970: 1_000_000))
        let (d, _) = await directory([agent("a", "billing-service"), agent("c", "blog")], now: { now.value })
        #expect(await d.resolve(nil) == .noTarget)
        await d.noteSpoke(about: "c")
        now.value = now.value.addingTimeInterval(119)
        guard case .one(let s) = await d.resolve(nil) else { Issue.record("expected the last one"); return }
        #expect(s.id == "c")
        now.value = now.value.addingTimeInterval(2)
        #expect(await d.resolve(nil) == .noTarget)
    }

    @Test func resolveAmongTheOffered() async {
        let (d, _) = await directory([agent("a", "billing-service", name: "Fix refund rounding"),
                                      agent("b", "billing-service", name: "Invoice export"), agent("c", "blog")])
        guard case .one(let s) = await d.resolve("the second one invoices", among: ["a", "b"]) else {
            Issue.record("expected invoices"); return
        }
        #expect(s.id == "b")
    }

    @Test func vocabularyHasProjectsAndLabels() async {
        let (d, _) = await directory([agent("a", "finebrief", name: "Orchestrator agent for multi-session voice control")])
        let v = await d.vocabulary()
        #expect(v.contains("finebrief"))
        #expect(v.contains("Orchestrator agent"))
    }

    @Test func knownProjectsComeFromClaudeJSONAndLiveSessions() async throws {
        let path = NSTemporaryDirectory() + "ek-claude-\(UUID().uuidString.prefix(6)).json"
        try #"{"projects":{"/p/blog":{"hasTrustDialogAccepted":true},"/p/new-thing":{"hasTrustDialogAccepted":false}},"other":1}"#
            .write(toFile: path, atomically: true, encoding: .utf8)
        let (d, _) = await directory([agent("a", "billing-service")], claudeJSON: path)
        let known = await d.knownProjects()
        #expect(known.contains(KnownProject(name: "blog", path: "/p/blog", trusted: true)))
        #expect(known.contains(KnownProject(name: "new thing", path: "/p/new-thing", trusted: false)))
        #expect(known.contains(KnownProject(name: "billing service", path: "/p/billing-service", trusted: true)))
        #expect(await d.matchProject("the blog")?.path == "/p/blog")
        #expect(await d.matchProject("newthing")?.path == "/p/new-thing")
        #expect(await d.matchProject("payments") == nil)
    }

    @Test func rollCallPutsSessionsThatNeedYouFirst() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        func s(_ id: String, _ name: String, _ state: SessionState?, detail: String? = nil, mins: Double = 0,
               busy: Bool = false) -> LiveSession {
            LiveSession(id: id, pid: 1, kind: "interactive", cwd: "/p", project: name, title: "", label: "", name: name,
                        busy: busy, waiting: false, state: state, detail: detail, since: now.addingTimeInterval(-mins * 60))
        }
        let line = RollCall.line([s("a", "invoice api", .working, mins: 12), s("b", "docs site", .done, detail: "fixed the broken links"),
                                  s("c", "billing service", .needs, detail: "needs your OK to run the database migration")], now: now)
        #expect(line == "Three sessions. Billing service needs your OK to run the database migration. Invoice api is working, 12 minutes in. Docs site finished: fixed the broken links.")
        #expect(RollCall.line([], now: now) == "No Claude sessions are open.")
        #expect(RollCall.sentence(s("x", "blog", nil, busy: true), now: now) == "Blog is working.")
        #expect(RollCall.sentence(s("x", "blog", nil), now: now) == "Blog is open.")
    }

    @Test func rollCallNamesSixThenCounts() {
        let now = Date()
        let list = (1...8).map { i in
            LiveSession(id: "\(i)", pid: 1, kind: "interactive", cwd: "/p", project: "p\(i)", title: "", label: "",
                        name: "p\(i)", busy: false, waiting: false, state: .open, detail: nil, since: now.addingTimeInterval(Double(i)))
        }
        let line = RollCall.line(list, now: now)
        #expect(line.hasPrefix("Eight sessions. P1 is open."))
        #expect(line.hasSuffix("And 2 more."))
    }
}
```

(`Box` comes from `CoreTests.swift`.)

- [ ] **Step 3: Run them to see them fail**

Run: `swift test --package-path app/EarshotKit --filter SessionDirectoryTests`
Expected: FAIL to compile.

- [ ] **Step 4: Write the directory**

`app/EarshotKit/Sources/EarshotKit/Sessions/SessionDirectory.swift`:

```swift
import Foundation

public struct LiveSession: Sendable, Equatable, Identifiable {
    public let id: String
    public var pid: Int32?
    public var kind: String
    public var cwd: String
    public var project: String
    public var title: String
    public var label: String
    /// The shortest unique spoken name.
    public var name: String
    public var busy: Bool
    /// On a permission prompt or a question (Claude Code's own view).
    public var waiting: Bool
    /// From the plugin, when it reported one.
    public var state: SessionState?
    public var detail: String?
    public var since: Date?

    public var isBackground: Bool { kind == "background" }
}

public struct KnownProject: Sendable, Equatable {
    public let name: String
    public let path: String
    public let trusted: Bool
}

/// Matching what you said against what a session is called.
public enum NameMatch {
    public static func normalize(_ s: String) -> String {
        var w = s.lowercased().split { !$0.isLetter && !$0.isNumber && $0 != "'" }.map(String.init)
        if w.first == "the" { w.removeFirst() }
        if w.last == "session" { w.removeLast() }
        return w.joined(separator: " ")
    }

    /// 1 for the same name, about 0.9 when the words you said start the
    /// name ("billing" for "billing service"), else closeness of the letters
    /// with spaces ignored ("fine brief" and "finebrief" are the same).
    public static func score(_ spoken: String, _ candidate: String) -> Double {
        let a = normalize(spoken), b = normalize(candidate)
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        if a == b { return 1 }
        let sa = a.replacingOccurrences(of: " ", with: ""), sb = b.replacingOccurrences(of: " ", with: "")
        if sa == sb { return 0.99 }
        let aw = a.split(separator: " "), bw = b.split(separator: " ")
        if bw.starts(with: aw) { return 0.9 }
        let d = levenshtein(Array(sa), Array(sb))
        return max(0, 1 - Double(d) / Double(max(sa.count, sb.count)))
    }

    static func levenshtein(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count), cur = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            cur[0] = i
            for j in 1...b.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            swap(&prev, &cur)
        }
        return prev[b.count]
    }
}

/// Every open session, from `claude agents --json` and the plugin's
/// statuses, with the names Earshot says.
public actor SessionDirectory {
    public enum Match: Sendable, Equatable {
        case one(LiveSession)
        case several([LiveSession])
        case none
        /// No session named and no default: ask.
        case noTarget
    }

    static let threshold = 0.78
    static let lastSpokeWindow: TimeInterval = 120

    private let runner: any ClaudeRunner
    private let store: SessionStore
    private let labeler: Labeler
    private let claudeJSON: String
    private let clock: @Sendable () -> Date
    private var list: [LiveSession] = []
    private var lastSpoke: (id: String, at: Date)?
    private var refreshedAt: Date?

    public init(runner: any ClaudeRunner, store: SessionStore, labeler: Labeler,
                claudeJSON: String = NSHomeDirectory() + "/.claude.json",
                clock: @escaping @Sendable () -> Date = Date.init) {
        self.runner = runner; self.store = store; self.labeler = labeler
        self.claudeJSON = claudeJSON; self.clock = clock
    }

    public var sessions: [LiveSession] { list }
    public func session(_ id: String) -> LiveSession? { list.first { $0.id == id } }

    /// Refreshes unless the list is younger than this: the wake word already
    /// refreshed it, so a command does not pay the 130 ms twice.
    public func refresh(ifOlderThan seconds: TimeInterval) async {
        if let r = refreshedAt, clock().timeIntervalSince(r) < seconds { return }
        await refresh()
    }

    /// Reads `claude agents --json` (about 130 ms) and merges the plugin's view.
    public func refresh() async {
        refreshedAt = clock()
        let r = await runner.run(["agents", "--json"], cwd: nil, timeout: .seconds(3))
        let agents = r.status == 0 ? AgentEntry.decodeList(r.stdout) : []
        let reported = Dictionary(await store.sessions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var merged: [LiveSession] = []
        for a in agents {
            let info = reported[a.sessionId]
            let project = info?.project ?? SpokenNames.project(cwd: a.cwd)
            let agentTitle = a.name.flatMap { SpokenNames.isDefaultName($0, cwd: a.cwd) ? nil : $0 } ?? ""
            let title = info?.title.flatMap { $0.isEmpty ? nil : $0 } ?? agentTitle
            let label = title.isEmpty ? "" : await labeler.label(session: a.sessionId, title: title)
            merged.append(LiveSession(id: a.sessionId, pid: a.pid, kind: a.kind, cwd: a.cwd, project: project, title: title,
                                      label: label, name: project, busy: a.isBusy, waiting: a.isWaiting,
                                      state: info?.state, detail: info?.detail, since: info?.updated))
        }
        // Sessions only the plugin knows (agents failed, or a kind it does not list).
        for (id, info) in reported where !merged.contains(where: { $0.id == id }) {
            let title = info.title ?? ""
            let label = title.isEmpty ? "" : await labeler.label(session: id, title: title)
            merged.append(LiveSession(id: id, pid: nil, kind: "unknown", cwd: "", project: info.project ?? info.name,
                                      title: title, label: label, name: info.name, busy: info.state == .working,
                                      waiting: info.state == .needs || info.state == .reply, state: info.state,
                                      detail: info.detail, since: info.updated))
        }
        let names = SpokenNames.names(merged.map { .init(id: $0.id, project: $0.project, title: $0.title, label: $0.label) })
        for i in merged.indices { merged[i].name = names[merged[i].id] ?? merged[i].project }
        list = merged
    }

    public func noteSpoke(about session: String) { lastSpoke = (session, clock()) }

    public func resolve(_ target: String?) -> Match {
        guard let target, !NameMatch.normalize(target).isEmpty else {
            if list.isEmpty { return .none }
            if list.count == 1 { return .one(list[0]) }
            if let l = lastSpoke, clock().timeIntervalSince(l.at) <= Self.lastSpokeWindow, let s = session(l.id) { return .one(s) }
            return .noTarget
        }
        return match(target, in: list)
    }

    /// After "Which one?": only the sessions that were offered.
    public func resolve(_ target: String, among ids: [String]) -> Match {
        let offered = list.filter { ids.contains($0.id) }
        if case .one(let s) = match(target, in: offered) { return .one(s) }
        // "the second one invoices": any word that picks out one label.
        let words = Set(NameMatch.normalize(target).split(separator: " ").map(String.init))
        let hits = offered.filter { s in
            [s.label, s.title].contains { name in
                NameMatch.normalize(name).split(separator: " ").contains { w in
                    words.contains { NameMatch.score($0, String(w)) >= 0.8 }
                }
            }
        }
        return hits.count == 1 ? .one(hits[0]) : (hits.isEmpty ? .none : .several(hits))
    }

    private func match(_ target: String, in sessions: [LiveSession]) -> Match {
        // "refund rounding in billing service"
        let t = NameMatch.normalize(target)
        if let r = t.range(of: " in ") {
            let label = String(t[..<r.lowerBound]), project = String(t[r.upperBound...])
            let hits = sessions.filter { NameMatch.score(project, $0.project) >= Self.threshold
                && max(NameMatch.score(label, $0.label), NameMatch.score(label, $0.title)) >= Self.threshold }
            if hits.count == 1 { return .one(hits[0]) }
        }
        // In order: the project, the label, the title, the spoken name.
        for key in [\LiveSession.project, \.label, \.title, \.name] {
            let exact = sessions.filter { NameMatch.normalize($0[keyPath: key]) == t && !t.isEmpty }
            if exact.count == 1 { return .one(exact[0]) }
            if exact.count > 1 { return .several(exact) }
        }
        // Then the closest names.
        let scored = sessions.map { s in (s, [s.project, s.label, s.title, s.name].map { NameMatch.score(target, $0) }.max() ?? 0) }
        guard let best = scored.map(\.1).max(), best >= Self.threshold else { return .none }
        let top = scored.filter { $0.1 >= best - 0.02 }.map(\.0)
        return top.count == 1 ? .one(top[0]) : .several(top)
    }

    /// Names to boost in transcription: projects and labels, at most 50.
    public func vocabulary() -> [String] {
        var seen = Set<String>(), out: [String] = []
        for n in list.flatMap({ [$0.project, $0.label] }) + knownProjects().map(\.name) where !n.isEmpty {
            if seen.insert(n.lowercased()).inserted { out.append(n) }
        }
        return Array(out.prefix(50))
    }

    /// Folders Claude Code knows (from ~/.claude.json, with their trust) and
    /// the folders of open sessions.
    public func knownProjects() -> [KnownProject] {
        var out: [KnownProject] = []
        if let data = FileManager.default.contents(atPath: claudeJSON),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let projects = root["projects"] as? [String: Any] {
            for (path, value) in projects {
                let trusted = (value as? [String: Any])?["hasTrustDialogAccepted"] as? Bool ?? false
                out.append(KnownProject(name: SpokenNames.project(cwd: path), path: path, trusted: trusted))
            }
        }
        for s in list where !s.cwd.isEmpty && !out.contains(where: { $0.path == s.cwd }) {
            out.append(KnownProject(name: s.project, path: s.cwd, trusted: true))
        }
        return out.sorted { $0.path < $1.path }
    }

    public func matchProject(_ spoken: String) -> KnownProject? {
        let scored = knownProjects().map { ($0, NameMatch.score(spoken, $0.name)) }.filter { $0.1 >= Self.threshold }
        guard let best = scored.max(by: { $0.1 < $1.1 }) else { return nil }
        // Two folders with the same name: prefer the one with a live session, then the shorter path.
        let ties = scored.filter { $0.1 == best.1 }.map(\.0)
        return ties.first { p in list.contains { $0.cwd == p.path } } ?? ties.min { $0.path.count < $1.path.count }
    }
}
```

Note on `SpokenNames.project(cwd:)` for `~/.claude.json` paths: it walks up looking for `.git`, so a project path inside a repo is named after the repo, as the plugin does.

- [ ] **Step 5: Write the roll call**

`app/EarshotKit/Sources/EarshotKit/Sessions/RollCall.swift`:

```swift
import Foundation

/// The roll call, as the plugin says it (speak.sh rollcall): how many, then
/// the sessions that need you first, at most six.
public enum RollCall {
    static let counts = ["No", "One", "Two", "Three", "Four", "Five", "Six", "Seven", "Eight", "Nine"]

    public static func line(_ sessions: [LiveSession], now: Date) -> String {
        guard !sessions.isEmpty else { return "No Claude sessions are open." }
        let total = sessions.count
        let head = total <= 9 ? "\(counts[total]) session\(total == 1 ? "" : "s")." : "\(total) sessions."
        let ordered = sessions.sorted { (rank($0), $0.since ?? now) < (rank($1), $1.since ?? now) }
        var parts = [head] + ordered.prefix(6).map { sentence($0, now: now) }
        if total > 6 { parts.append("And \(total - 6) more.") }
        return parts.joined(separator: " ")
    }

    public static func sentence(_ s: LiveSession, now: Date) -> String {
        let n = s.name.prefix(1).uppercased() + s.name.dropFirst()
        switch effectiveState(s) {
        case .needs: return "\(n) \(s.detail.flatMap { $0.isEmpty ? nil : $0 } ?? "is waiting on you")."
        case .reply: return "\(n) is waiting on your answer."
        case .stuck: return "\(n) might be stuck."
        case .failed: return "\(n) hit an error."
        case .working:
            guard let since = s.since, s.state == .working else { return "\(n) is working." }
            let m = Int(now.timeIntervalSince(since) / 60)
            return m == 0 ? "\(n) is working, just started." : "\(n) is working, \(m) minute\(m == 1 ? "" : "s") in."
        case .done:
            guard let d = s.detail, !d.isEmpty else { return "\(n) finished." }
            let detail = d.prefix(1).lowercased() + d.dropFirst()
            return "\(n) finished: \(detail)\(".!?".contains(d.last ?? " ") ? "" : ".")"
        default: return "\(n) is open."
        }
    }

    /// The plugin's state, else what Claude Code shows.
    static func effectiveState(_ s: LiveSession) -> SessionState {
        if let st = s.state { return st }
        if s.waiting { return .needs }
        return s.busy ? .working : .open
    }

    static func rank(_ s: LiveSession) -> Int { SessionStore.rank(effectiveState(s)) }
}
```

- [ ] **Step 6: Run the tests**

Run: `swift test --package-path app/EarshotKit --filter "SessionDirectoryTests|CoreTests"`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add app/EarshotKit/Sources/EarshotKit/Core/SessionStore.swift app/EarshotKit/Sources/EarshotKit/Sessions app/EarshotKit/Tests/EarshotKitTests/SessionDirectoryTests.swift
git commit -m "Sessions: one directory of open sessions, name matching, known folders and the roll call"
```

---

### Task 15: Writing into a session's socket

**Files:**
- Create: `app/EarshotKit/Sources/EarshotKit/Sessions/SessionTransport.swift`
- Test: `app/EarshotKit/Tests/EarshotKitTests/SessionTransportTests.swift`

**Interfaces:**
- Produces:
  - `public enum Priority: String, Sendable { case now, next }`
  - `public protocol SessionTransport: Sendable { func send(pid: Int32, sessionID: String, text: String, priority: Priority) async -> Bool }`
  - `public struct CCSocketTransport: SessionTransport` with `init(dir: String = "/tmp/cc-socks")` and `static func line(sessionID: String, text: String, priority: Priority) -> Data`

- [ ] **Step 1: Write the failing tests**

`app/EarshotKit/Tests/EarshotKitTests/SessionTransportTests.swift`:

```swift
import Darwin
import Foundation
import Testing
@testable import EarshotKit

@Suite(.serialized) struct SessionTransportTests {
    @Test func theLineIsTheMessagingFormat() throws {
        let data = CCSocketTransport.line(sessionID: "3b4f", text: "run the \"tests\"", priority: .next)
        let o = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(o["type"] as? String == "user")
        #expect(o["from"] as? String == "earshot")
        #expect(o["session_id"] as? String == "3b4f")
        #expect(o["priority"] as? String == "next")
        let m = try #require(o["message"] as? [String: Any])
        #expect(m["role"] as? String == "user")
        #expect(m["content"] as? String == "run the \"tests\"")
        #expect(!data.contains(10))   // one line
    }

    @Test func writesOneLineToThePidsSocket() async throws {
        let dir = "/tmp/ek-cc-\(UUID().uuidString.prefix(4))"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let got = Collected<String>()
        let server = LineServer(path: "\(dir)/4242.sock") { (line: Data) -> Data in
            let s = String(decoding: line, as: UTF8.self)
            Task { await got.add(s) }
            return Data()
        }
        try server.start()
        defer { server.stop() }
        let ok = await CCSocketTransport(dir: dir).send(pid: 4242, sessionID: "s1", text: "hi", priority: .now)
        #expect(ok)
        #expect(await eventually { await got.items.count == 1 })
        #expect(await got.items.first?.contains(#""priority":"now""#) == true)
    }

    @Test func aMissingSocketIsFalse() async {
        #expect(await CCSocketTransport(dir: "/tmp/ek-none").send(pid: 1, sessionID: "s", text: "x", priority: .next) == false)
    }

    /// Only a socket you own: a plain file or a link at the path is refused.
    @Test func refusesSomethingThatIsNotYourSocket() async throws {
        let dir = "/tmp/ek-cc-\(UUID().uuidString.prefix(4))"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: "\(dir)/7.sock", contents: Data())
        #expect(await CCSocketTransport(dir: dir).send(pid: 7, sessionID: "s", text: "x", priority: .next) == false)
    }
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `swift test --package-path app/EarshotKit --filter SessionTransportTests`
Expected: FAIL to compile.

- [ ] **Step 3: Write the transport**

`app/EarshotKit/Sources/EarshotKit/Sessions/SessionTransport.swift`:

```swift
import Darwin
import Foundation

public enum Priority: String, Sendable {
    /// Before anything else, after the current tool call.
    case now
    case next
}

public protocol SessionTransport: Sendable {
    /// One prompt line to the session. False when its socket is gone or the write failed.
    func send(pid: Int32, sessionID: String, text: String, priority: Priority) async -> Bool
}

/// Claude Code's messaging socket, /tmp/cc-socks/<pid>.sock (see the spike
/// notes). The session drops a line whose session_id is not its own, so a
/// reused pid never gets a command meant for another session.
public struct CCSocketTransport: SessionTransport {
    let dir: String

    public init(dir: String = "/tmp/cc-socks") { self.dir = dir }

    public static func line(sessionID: String, text: String, priority: Priority) -> Data {
        let o: [String: Any] = ["type": "user", "from": "earshot", "session_id": sessionID, "priority": priority.rawValue,
                                "message": ["role": "user", "content": text]]
        return (try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])) ?? Data()
    }

    public func send(pid: Int32, sessionID: String, text: String, priority: Priority) async -> Bool {
        let path = "\(dir)/\(pid).sock"
        var st = stat()
        guard lstat(path, &st) == 0, st.st_mode & S_IFMT == S_IFSOCK, st.st_uid == getuid(), UnixAddress.fits(path)
        else { return false }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        UnixAddress.noSigPipe(fd)
        guard UnixAddress.with(path, { connect(fd, $0, $1) }) == 0 else { return false }
        var out = Self.line(sessionID: sessionID, text: text, priority: priority)
        out.append(10)
        return out.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) } == out.count
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `swift test --package-path app/EarshotKit --filter SessionTransportTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/EarshotKit/Sources/EarshotKit/Sessions/SessionTransport.swift app/EarshotKit/Tests/EarshotKitTests/SessionTransportTests.swift
git commit -m "Sessions: write a prompt line into a session's messaging socket"
```

---
### Task 16: The Dispatcher: carrying out a command

Turns a `Command` into an action and the line Earshot says. It never sends an empty or unparsed command, and it asks back only when the target is unclear.

**Files:**
- Create: `app/EarshotKit/Sources/EarshotKit/Commands/Dispatcher.swift`
- Test: `app/EarshotKit/Tests/EarshotKitTests/DispatcherTests.swift`

**Interfaces:**
- Consumes: `Command` (Task 10), `SessionDirectory`, `LiveSession`, `KnownProject`, `NameMatch`, `RollCall` (Task 14), `SessionTransport`, `Priority` (Task 15), `ClaudeRunner` (Task 12), `ApprovalBook`, `OpenApproval` (Task 2), `SessionStore`.
- Produces:
  - `public actor Dispatcher` with `init(directory:store:transport:runner:approvals:say:receiptTimeout:defaultsSuite:)` where `say: @escaping @Sendable (String) async -> Void` speaks a later line (a missed receipt), `receiptTimeout: Duration = .seconds(5)`, `defaultsSuite: String? = nil` (nil: the app's own defaults; tests pass a throwaway suite).
  - `func run(_ c: Command) async -> Dispatcher.Outcome`, `func reply(_ text: String, to pending: Dispatcher.Pending) async -> Dispatcher.Outcome`.
  - `public enum Pending: Sendable, Equatable { case chooseSession(Command, [String]), startPrompt(KnownProject), chooseApproval(allow: Bool, [String]) }`
  - `public struct Outcome: Sendable, Equatable { var line: String?; var pending: Pending?; var spokeAbout: String?; var sound: Bool }`
  - `static let didntGetIt = "Sorry, I didn't get that."`, `static let stopText = "Stop what you're doing and wait for the user."`

The spoken lines, exactly:

| Case | Line |
|---|---|
| Not understood | Sorry, I didn't get that. |
| No sessions open | No Claude sessions are open. |
| No target, several open | Which session? Open ones are billing service, blog and earshot. |
| Unknown target | I don't know a session called payments. Open ones are billing service, blog and earshot. |
| Two match in one project | Billing service has two: refund rounding and invoices. Which one? |
| Two match elsewhere | Two match: blog and blog api. Which one? |
| Sent, idle session | Sent to billing service. |
| Sent, busy session | Queued, billing service is busy. |
| Sent, waiting on a prompt | Queued. Billing service is still waiting on your OK. |
| Socket gone | Billing service has closed. |
| No receipt in 5 s (later) | Billing service didn't pick it up. |
| Second miss in a row (later) | Sending to sessions stopped working with this Claude Code version. Background sessions still work. |
| Sending marked broken, not background | Sending to billing service doesn't work with this Claude Code version yet. |
| No process, not background | I can't reach billing service. |
| Stop, after the step | Billing service will stop after its current step. |
| Stop now, background | Stopped billing service. |
| Stop, idle | Billing service isn't doing anything. |
| Start, done | Started a session in blog. |
| Start, untrusted | Blog isn't trusted yet. Open it in Claude once first. |
| Start, unknown folder | I don't know a folder called payments. |
| Start, no prompt | What should the new session in blog do? |
| Start failed | Couldn't start a session in blog. |
| Answer written | Approved. / Told it no. |
| Answer, nothing open | Nothing is waiting on your OK. |
| Answer, several open | Which one, billing service or docs? |
| Answer, the prompt closed first | (nothing) |

- [ ] **Step 1: Write the failing tests**

`app/EarshotKit/Tests/EarshotKitTests/DispatcherTests.swift`:

```swift
import Foundation
import Testing
@testable import EarshotKit

actor FakeTransport: SessionTransport {
    struct Sent: Equatable { let pid: Int32; let session: String; let text: String; let priority: Priority }
    private(set) var sent: [Sent] = []
    private var works = true
    func setWorks(_ w: Bool) { works = w }
    func send(pid: Int32, sessionID: String, text: String, priority: Priority) async -> Bool {
        sent.append(Sent(pid: pid, session: sessionID, text: text, priority: priority))
        return works
    }
}

@Suite struct DispatcherTests {
    let store = SessionStore()
    let transport = FakeTransport()
    let said = Collected<String>()
    let suite = "ek-dispatch-\(UUID().uuidString)"
    let approvalsDir: String = {
        let d = NSTemporaryDirectory() + "ek-d-\(UUID().uuidString.prefix(6))"
        try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
        return d
    }()
    let secret = "0123456789abcdef0123456789abcdef"

    func make(_ agents: [AgentEntry], claudeJSON: String = "/nonexistent") -> (Dispatcher, FakeRunner, ApprovalBook) {
        let runner = FakeRunner(agents)
        let directory = SessionDirectory(runner: runner, store: store, labeler: Labeler(model: nil, liveDir: NSTemporaryDirectory()),
                                         claudeJSON: claudeJSON)
        let book = ApprovalBook(stateDir: approvalsDir, isAlive: { _ in true })
        let said = self.said
        let d = Dispatcher(directory: directory, store: store, transport: transport, runner: runner, approvals: book,
                           say: { await said.add($0) }, receiptTimeout: .milliseconds(200), defaultsSuite: suite)
        return (d, runner, book)
    }

    func approval(_ session: String, _ id: String, _ name: String) -> AppMessage.Approval {
        .init(session: session, id: id, name: name, what: "to run the migration",
              answer: "\(approvalsDir)/answer-\(session)-\(id)", secret: secret, pid: 1)
    }

    // MARK: Send

    @Test func sendsToTheNamedSession() async {
        let (d, _, _) = make([agent("a", "billing-service", pid: 10), agent("b", "blog", pid: 11)])
        let o = await d.run(.send(target: "billing service", prompt: "run the tests"))
        #expect(o.line == "Sent to billing service.")
        #expect(o.spokeAbout == "a")
        #expect(await transport.sent == [.init(pid: 10, session: "a", text: "run the tests", priority: .next)])
    }

    @Test func aBusySessionIsQueued() async {
        let (d, _, _) = make([agent("a", "billing-service", status: "busy")])
        #expect(await d.run(.send(target: "billing", prompt: "x")).line == "Queued, billing service is busy.")
    }

    @Test func aSessionOnAPromptSaysItStillWaits() async {
        await store.apply(.init(session: "a", state: .needs, detail: "needs your OK", name: "billing service"))
        let (d, _, _) = make([agent("a", "billing-service", status: "waiting")])
        #expect(await d.run(.send(target: "billing", prompt: "x")).line == "Queued. Billing service is still waiting on your OK.")
    }

    @Test func noTargetWithOneSessionUsesIt() async {
        let (d, _, _) = make([agent("b", "blog")])
        #expect(await d.run(.send(target: nil, prompt: "deploy")).line == "Sent to blog.")
    }

    @Test func noTargetWithSeveralAsks() async {
        let (d, _, _) = make([agent("a", "billing-service"), agent("b", "blog"), agent("c", "earshot"), agent("e", "extra")])
        let o = await d.run(.send(target: nil, prompt: "deploy"))
        #expect(o.line?.hasPrefix("Which session? Open ones are ") == true)
        #expect(o.pending == .chooseSession(.send(target: nil, prompt: "deploy"), ["a", "b", "c", "e"]))
        #expect(await transport.sent.isEmpty)
    }

    @Test func twoInOneProjectAsksWhichOneThenSends() async {
        let (d, _, _) = make([agent("a", "billing-service", name: "Fix refund rounding", pid: 10),
                              agent("b", "billing-service", name: "Invoice export", pid: 11)])
        let o = await d.run(.send(target: "billing", prompt: "run the tests"))
        #expect(o.line == "Billing service has two: Fix refund rounding and Invoice export. Which one?")
        guard let p = o.pending else { Issue.record("no question"); return }
        let r = await d.reply("invoices", to: p)
        #expect(r.line == "Sent to the Invoice export session.")
        #expect(await transport.sent.map(\.pid) == [11])
    }

    @Test func anUnknownTargetListsAtMostThree() async {
        let (d, _, _) = make([agent("a", "billing-service"), agent("b", "blog"), agent("c", "earshot"), agent("e", "extra")])
        let line = await d.run(.send(target: "payments", prompt: "x")).line ?? ""
        #expect(line.hasPrefix("I don't know a session called payments. Open ones are "))
        #expect(line.components(separatedBy: ",").count + line.components(separatedBy: " and ").count - 1 == 3)
    }

    @Test func aClosedSessionIsSaid() async {
        await transport.setWorks(false)
        let (d, _, _) = make([agent("a", "billing-service")])
        #expect(await d.run(.send(target: "billing", prompt: "x")).line == "Billing service has closed.")
    }

    @Test func noReceiptIsSaidLater() async {
        let (d, _, _) = make([agent("a", "billing-service")])
        _ = await d.run(.send(target: "billing", prompt: "x"))
        #expect(await eventually { await said.items == ["Billing service didn't pick it up."] })
    }

    @Test func aReceiptKeepsItQuiet() async {
        let (d, _, _) = make([agent("a", "billing-service")])
        _ = await d.run(.send(target: "billing", prompt: "x"))
        await store.apply(.init(session: "a", state: .working, name: "billing service"))
        try? await Task.sleep(for: .milliseconds(400))
        #expect(await said.items.isEmpty)
    }

    @Test func twoMissesMarkSendingBrokenAndBackgroundSessionsResume() async {
        let (d, runner, _) = make([agent("a", "billing-service"), agent("g", "wedding", pid: nil, kind: "background", status: nil)])
        _ = await d.run(.send(target: "billing", prompt: "x"))
        #expect(await eventually { await said.items.count == 1 })
        _ = await d.run(.send(target: "billing", prompt: "y"))
        #expect(await eventually { await said.items.count == 2 })
        #expect(await said.items.last == "Sending to sessions stopped working with this Claude Code version. Background sessions still work.")
        #expect(await d.run(.send(target: "billing", prompt: "z")).line == "Sending to billing service doesn't work with this Claude Code version yet.")
        #expect(await d.run(.send(target: "wedding", prompt: "w")).line == "Sent to wedding.")
        #expect(await runner.argLists.contains(["--resume", "g", "--bg", "w"]))
    }

    @Test func aBackgroundSessionWithoutAProcessResumes() async {
        let (d, runner, _) = make([agent("g", "wedding", pid: nil, kind: "background", status: nil)])
        #expect(await d.run(.send(target: "wedding", prompt: "keep going")).line == "Sent to wedding.")
        #expect(await runner.argLists.contains(["--resume", "g", "--bg", "keep going"]))
        #expect(await transport.sent.isEmpty)
    }

    @Test func unknownCommandSendsNothing() async {
        let (d, _, _) = make([agent("a", "billing-service")])
        #expect(await d.run(.unknown).line == "Sorry, I didn't get that.")
        #expect(await transport.sent.isEmpty)
    }

    // MARK: Status, stop, start

    @Test func statusForEveryoneIsTheRollCall() async {
        let (d, _, _) = make([agent("a", "billing-service", status: "busy"), agent("b", "blog")])
        #expect(await d.run(.status(target: nil)).line == "Two sessions. Billing service is working. Blog is open.")
    }

    @Test func statusForOne() async {
        let (d, _, _) = make([agent("a", "billing-service", status: "busy"), agent("b", "blog")])
        let o = await d.run(.status(target: "billing"))
        #expect(o.line == "Billing service is working.")
        #expect(o.spokeAbout == "a")
    }

    @Test func stopAfterTheCurrentStep() async {
        let (d, _, _) = make([agent("a", "billing-service", pid: 10, status: "busy")])
        #expect(await d.run(.stop(target: "billing", now: false)).line == "Billing service will stop after its current step.")
        #expect(await transport.sent == [.init(pid: 10, session: "a", text: Dispatcher.stopText, priority: .now)])
    }

    @Test func stopNowOnABackgroundSessionRunsClaudeStop() async {
        let (d, runner, _) = make([agent("g", "wedding", pid: 20, kind: "background", status: "busy")])
        #expect(await d.run(.stop(target: "wedding", now: true)).line == "Stopped wedding.")
        #expect(await runner.argLists.contains(["stop", "g"]))
        #expect(await transport.sent.isEmpty)
    }

    @Test func stoppingAnIdleSessionDoesNothing() async {
        let (d, _, _) = make([agent("b", "blog")])
        #expect(await d.run(.stop(target: "blog", now: false)).line == "Blog isn't doing anything.")
        #expect(await transport.sent.isEmpty)
    }

    func claudeJSON() throws -> String {
        let path = NSTemporaryDirectory() + "ek-cj-\(UUID().uuidString.prefix(6)).json"
        try #"{"projects":{"/p/blog":{"hasTrustDialogAccepted":true},"/p/secret":{"hasTrustDialogAccepted":false}}}"#
            .write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    @Test func startRunsClaudeInTheFolder() async throws {
        let (d, runner, _) = make([], claudeJSON: try claudeJSON())
        #expect(await d.run(.start(project: "blog", prompt: "fix the header")).line == "Started a session in blog.")
        let call = await runner.calls.last
        #expect(call?.args == ["--bg", "fix the header"])
        #expect(call?.cwd == "/p/blog")
    }

    @Test func startInAnUntrustedFolderSaysSo() async throws {
        let (d, runner, _) = make([], claudeJSON: try claudeJSON())
        #expect(await d.run(.start(project: "secret", prompt: "x")).line == "Secret isn't trusted yet. Open it in Claude once first.")
        #expect(await runner.argLists.allSatisfy { $0.first != "--bg" })
    }

    @Test func startWithoutAPromptAsksWhatToDo() async throws {
        let (d, runner, _) = make([], claudeJSON: try claudeJSON())
        let o = await d.run(.start(project: "blog", prompt: nil))
        #expect(o.line == "What should the new session in blog do?")
        guard let p = o.pending else { Issue.record("no question"); return }
        #expect(await d.reply("fix the header", to: p).line == "Started a session in blog.")
        #expect(await runner.argLists.contains(["--bg", "fix the header"]))
    }

    @Test func startInAnUnknownFolder() async throws {
        let (d, _, _) = make([], claudeJSON: try claudeJSON())
        #expect(await d.run(.start(project: "payments", prompt: "x")).line == "I don't know a folder called payments.")
    }

    // MARK: Answers

    @Test func answerApprovesTheOnlyPrompt() async throws {
        let (d, _, book) = make([agent("s1", "billing-service")])
        await book.apply(approval("s1", "1-1-1", "billing service"))
        let o = await d.run(.answer(allow: true, target: nil))
        #expect(o.line == "Approved.")
        #expect(o.sound)
        #expect(try String(contentsOfFile: "\(approvalsDir)/answer-s1-1-1-1", encoding: .utf8) == "allow \(secret)\n")
    }

    @Test func answerWithTwoOpenAsksWhichOne() async {
        let (d, _, book) = make([agent("s1", "billing-service"), agent("s2", "docs")])
        await book.apply(approval("s1", "1-1-1", "billing service"))
        await book.apply(approval("s2", "2-2-2", "docs"))
        let o = await d.run(.answer(allow: false, target: nil))
        #expect(o.line == "Which one, billing service or docs?")
        guard let p = o.pending else { Issue.record("no question"); return }
        let r = await d.reply("docs", to: p)
        #expect(r.line == "Told it no.")
        #expect(await book.current.map(\.id) == ["1-1-1"])
    }

    @Test func answerByName() async {
        let (d, _, book) = make([agent("s1", "billing-service"), agent("s2", "docs")])
        await book.apply(approval("s1", "1-1-1", "billing service"))
        await book.apply(approval("s2", "2-2-2", "docs"))
        #expect(await d.run(.answer(allow: true, target: "billing")).line == "Approved.")
        #expect(await book.current.map(\.id) == ["2-2-2"])
    }

    @Test func answerWhenNothingWaits() async {
        let (d, _, _) = make([agent("s1", "billing-service")])
        #expect(await d.run(.answer(allow: true, target: nil)).line == "Nothing is waiting on your OK.")
    }
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `swift test --package-path app/EarshotKit --filter DispatcherTests`
Expected: FAIL to compile.

- [ ] **Step 3: Write the Dispatcher**

`app/EarshotKit/Sources/EarshotKit/Commands/Dispatcher.swift`:

```swift
import Foundation
import os

/// Carries out one command and returns what to say.
public actor Dispatcher {
    public enum Pending: Sendable, Equatable {
        /// "Which one?": the command waits for a session name.
        case chooseSession(Command, [String])
        /// "What should it do?"
        case startPrompt(KnownProject)
        /// "Which one, billing or docs?"
        case chooseApproval(allow: Bool, [String])
    }

    public struct Outcome: Sendable, Equatable {
        public var line: String?
        public var pending: Pending?
        /// The session this was about, for "last spoke about".
        public var spokeAbout: String?
        /// A voice answer was written: the confirm sound plays first.
        public var sound: Bool

        public init(line: String? = nil, pending: Pending? = nil, spokeAbout: String? = nil, sound: Bool = false) {
            self.line = line; self.pending = pending; self.spokeAbout = spokeAbout; self.sound = sound
        }
    }

    public static let didntGetIt = "Sorry, I didn't get that."
    public static let stopText = "Stop what you're doing and wait for the user."
    static let counts = ["no", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine"]

    private let directory: SessionDirectory
    private let store: SessionStore
    private let transport: any SessionTransport
    private let runner: any ClaudeRunner
    private let approvals: ApprovalBook
    private let say: @Sendable (String) async -> Void
    private let receiptTimeout: Duration
    private let defaults: UserDefaults
    private var misses = 0
    private let log = Logger(subsystem: "com.earshot.app", category: "dispatch")

    public init(directory: SessionDirectory, store: SessionStore, transport: any SessionTransport, runner: any ClaudeRunner,
                approvals: ApprovalBook, say: @escaping @Sendable (String) async -> Void,
                receiptTimeout: Duration = .seconds(5), defaultsSuite: String? = nil) {
        self.directory = directory; self.store = store; self.transport = transport; self.runner = runner
        self.approvals = approvals; self.say = say; self.receiptTimeout = receiptTimeout
        defaults = defaultsSuite.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }

    public func run(_ c: Command) async -> Outcome {
        switch c {
        case .unknown:
            return Outcome(line: Self.didntGetIt)
        case .status(nil):
            await directory.refresh(ifOlderThan: 2)
            return Outcome(line: RollCall.line(await directory.sessions, now: Date()))
        case .answer(let allow, let target):
            return await answer(allow: allow, target: target)
        case .start(let project, let prompt):
            return await start(project, prompt: prompt)
        case .send(let target, _), .stop(let target, _):
            return await targeted(c, target)
        case .status(let target?):
            return await targeted(c, target)
        }
    }

    public func reply(_ text: String, to pending: Pending) async -> Outcome {
        if ["never mind", "nevermind", "cancel", "forget it", "nothing", "none"].contains(NameMatch.normalize(text)) {
            return Outcome()
        }
        switch pending {
        case .chooseSession(let c, let ids):
            switch await directory.resolve(text, among: ids) {
            case .one(let s): return await act(c, on: s)
            case .several: return Outcome(line: "I still can't tell which one.")
            default: return Outcome(line: "I didn't catch which one.")
            }
        case .startPrompt(let p):
            let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return prompt.isEmpty ? Outcome(line: Self.didntGetIt) : await launch(p, prompt)
        case .chooseApproval(let allow, let ids):
            let open = await approvals.current.filter { ids.contains($0.id) }
            let hits = open.filter { NameMatch.score(text, $0.name) >= SessionDirectory.threshold }
            guard hits.count == 1 else { return Outcome(line: "I didn't catch which one.") }
            return await write(hits[0], allow: allow)
        }
    }

    // MARK: - Sessions

    private func targeted(_ c: Command, _ target: String?) async -> Outcome {
        await directory.refresh(ifOlderThan: 2)
        let sessions = await directory.sessions
        guard !sessions.isEmpty else { return Outcome(line: "No Claude sessions are open.") }
        switch await directory.resolve(target) {
        case .one(let s):
            return await act(c, on: s)
        case .several(let list):
            return Outcome(line: whichOne(list), pending: .chooseSession(c, list.map(\.id)))
        case .none:
            return Outcome(line: "I don't know a session called \(target ?? "that"). Open ones are \(Self.listThree(sessions)).")
        case .noTarget:
            return Outcome(line: "Which session? Open ones are \(Self.listThree(sessions)).",
                           pending: .chooseSession(c, sessions.map(\.id)))
        }
    }

    private func act(_ c: Command, on s: LiveSession) async -> Outcome {
        switch c {
        case .send(_, let prompt): return await send(prompt, to: s)
        case .status: return Outcome(line: RollCall.sentence(s, now: Date()), spokeAbout: s.id)
        case .stop(_, let now): return await stop(s, now: now)
        default: return Outcome(line: Self.didntGetIt)
        }
    }

    private func send(_ prompt: String, to s: LiveSession) async -> Outcome {
        let broken = await sendingBroken()
        guard let pid = s.pid, !broken else {
            if s.isBackground { return await resume(s, prompt) }
            if broken { return Outcome(line: "Sending to \(s.name) doesn't work with this Claude Code version yet.") }
            return Outcome(line: "I can't reach \(s.name).")
        }
        let sentAt = Date()
        guard await transport.send(pid: pid, sessionID: s.id, text: prompt, priority: .next) else {
            return Outcome(line: "\(Self.upper(s.name)) has closed.")
        }
        if s.waiting || s.state == .needs || s.state == .reply {
            return Outcome(line: "Queued. \(Self.upper(s.name)) is still waiting on your OK.", spokeAbout: s.id)
        }
        if s.busy || s.state == .working {
            return Outcome(line: "Queued, \(s.name) is busy.", spokeAbout: s.id)
        }
        let session = s
        Task { await self.watchReceipt(session, sentAt: sentAt) }
        return Outcome(line: "Sent to \(s.name).", spokeAbout: s.id)
    }

    /// `claude --resume <id> --bg "<prompt>"`, with no other flags, continues the same session.
    private func resume(_ s: LiveSession, _ prompt: String) async -> Outcome {
        let r = await runner.run(["--resume", s.id, "--bg", prompt], cwd: s.cwd.isEmpty ? nil : s.cwd, timeout: .seconds(15))
        return r.status == 0 ? Outcome(line: "Sent to \(s.name).", spokeAbout: s.id) : Outcome(line: "Couldn't reach \(s.name).")
    }

    /// An idle session that got the prompt starts working: the plugin's
    /// status says so, or Claude Code lists it as busy.
    private func watchReceipt(_ s: LiveSession, sentAt: Date) async {
        let deadline = ContinuousClock.now + receiptTimeout
        while ContinuousClock.now < deadline {
            if await received(s.id, after: sentAt) { misses = 0; return }
            try? await Task.sleep(for: .milliseconds(50))
        }
        await directory.refresh()
        let busyNow = await directory.session(s.id)?.busy == true
        let reported = await received(s.id, after: sentAt)
        if busyNow || reported { misses = 0; return }
        misses += 1
        log.info("no receipt from a session (\(self.misses, privacy: .public) in a row)")
        if misses >= 2 {
            if let key = await brokenKey() { defaults.set(true, forKey: key) }
            await say("Sending to sessions stopped working with this Claude Code version. Background sessions still work.")
        } else {
            await say("\(Self.upper(s.name)) didn't pick it up.")
        }
    }

    private func received(_ id: String, after: Date) async -> Bool {
        guard let info = await store.sessions.first(where: { $0.id == id }) else { return false }
        return info.updated >= after && info.state != .open && info.state != .done
    }

    private func brokenKey() async -> String? { await runner.version().map { "socketBroken-\($0)" } }

    private func sendingBroken() async -> Bool {
        guard let key = await brokenKey() else { return false }
        return defaults.bool(forKey: key)
    }

    private func stop(_ s: LiveSession, now: Bool) async -> Outcome {
        let name = Self.upper(s.name)
        if now, s.isBackground {
            let r = await runner.run(["stop", s.id], cwd: nil, timeout: .seconds(10))
            return Outcome(line: r.status == 0 ? "Stopped \(s.name)." : "Couldn't stop \(s.name).", spokeAbout: s.id)
        }
        let active = s.busy || s.waiting || [.working, .needs, .reply, .stuck].contains(s.state)
        guard active else { return Outcome(line: "\(name) isn't doing anything.", spokeAbout: s.id) }
        guard let pid = s.pid, !(await sendingBroken()) else {
            if s.isBackground { return await stop(s, now: true) }
            return Outcome(line: "I can't reach \(s.name).")
        }
        guard await transport.send(pid: pid, sessionID: s.id, text: Self.stopText, priority: .now) else {
            return Outcome(line: "\(name) has closed.")
        }
        return Outcome(line: "\(name) will stop after its current step.", spokeAbout: s.id)
    }

    // MARK: - Start

    private func start(_ project: String, prompt: String?) async -> Outcome {
        guard let p = await directory.matchProject(project) else {
            return Outcome(line: "I don't know a folder called \(project).")
        }
        guard p.trusted else { return Outcome(line: "\(Self.upper(p.name)) isn't trusted yet. Open it in Claude once first.") }
        guard let prompt, !prompt.isEmpty else {
            return Outcome(line: "What should the new session in \(p.name) do?", pending: .startPrompt(p))
        }
        return await launch(p, prompt)
    }

    private func launch(_ p: KnownProject, _ prompt: String) async -> Outcome {
        let r = await runner.run(["--bg", prompt], cwd: p.path, timeout: .seconds(20))
        if r.status == 0 { return Outcome(line: "Started a session in \(p.name).") }
        if r.stderr.lowercased().contains("trust") {
            return Outcome(line: "\(Self.upper(p.name)) isn't trusted yet. Open it in Claude once first.")
        }
        return Outcome(line: "Couldn't start a session in \(p.name).")
    }

    // MARK: - Answers

    private func answer(allow: Bool, target: String?) async -> Outcome {
        var open = await approvals.current
        guard !open.isEmpty else { return Outcome(line: "Nothing is waiting on your OK.") }
        if let target {
            open = open.filter { NameMatch.score(target, $0.name) >= SessionDirectory.threshold }
            guard !open.isEmpty else { return Outcome(line: "Nothing in \(target) is waiting on your OK.") }
        }
        // The newest prompt of each session.
        var latest: [String: OpenApproval] = [:]
        for a in open { latest[a.session] = a }
        let pick = latest.values.sorted { $0.opened < $1.opened }
        if pick.count == 1 { return await write(pick[0], allow: allow) }
        let names = pick.map(\.name)
        let list = names.dropLast().joined(separator: ", ") + " or " + (names.last ?? "")
        return Outcome(line: "Which one, \(list)?", pending: .chooseApproval(allow: allow, pick.map(\.id)))
    }

    private func write(_ a: OpenApproval, allow: Bool) async -> Outcome {
        switch await approvals.answer(a.id, allow: allow) {
        case .written: return Outcome(line: allow ? "Approved." : "Told it no.", spokeAbout: a.session, sound: true)
        case .closed: return Outcome()
        case .failed: return Outcome(line: "Couldn't answer it.")
        }
    }

    // MARK: - Words

    private func whichOne(_ list: [LiveSession]) -> String {
        let count = list.count < Self.counts.count ? Self.counts[list.count] : String(list.count)
        let projects = Set(list.map(\.project))
        if projects.count == 1, let p = projects.first {
            let labels = list.map { $0.label.isEmpty ? $0.name : $0.label }
            return "\(Self.upper(p)) has \(count): \(Self.join(labels)). Which one?"
        }
        return "\(Self.upper(count)) match: \(Self.join(list.map(\.name))). Which one?"
    }

    static func listThree(_ sessions: [LiveSession]) -> String { join(Array(sessions.prefix(3).map(\.name))) }

    static func join(_ items: [String]) -> String {
        guard items.count > 1 else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + " and " + items.last!
    }

    static func upper(_ s: String) -> String { s.prefix(1).uppercased() + s.dropFirst() }
}
```

- [ ] **Step 4: Run the tests**

Run: `swift test --package-path app/EarshotKit --filter DispatcherTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/EarshotKit/Sources/EarshotKit/Commands/Dispatcher.swift app/EarshotKit/Tests/EarshotKitTests/DispatcherTests.swift
git commit -m "Dispatcher: send, status, stop, start and voice answers, with receipts"
```

---
### Task 17: The voice loop

Ties the parts together: what the Listener hears goes to the parser and the Dispatcher, the answer is said as a `confirm` line, and the follow-up windows open only after Earshot's own line has finished playing.

**Files:**
- Create: `app/EarshotKit/Sources/EarshotKit/Core/VoiceLoop.swift`
- Test: `app/EarshotKit/Tests/EarshotKitTests/VoiceLoopTests.swift`

**Interfaces:**
- Consumes: `Listener.Utterance`, `Listener.FollowUp`, `ListenObserver`, `Chimes` (Task 7), `SpeechOut.LineEvent`, `beginListening`, `endListening` (Task 8), `Grammar`, `CommandParser` (Tasks 10, 11), `SessionDirectory` (Task 14), `Dispatcher` (Task 16), `ApprovalBook` (Task 2), `EventLog`.
- Produces:
  - `public protocol FollowUpListening: Sendable { func listenFollowUp(_ f: Listener.FollowUp, within: Duration?) async; func setVocabulary(_ v: [String]) async }`, with `extension Listener: FollowUpListening {}`
  - `public protocol LineSpeaker: Sendable { func enqueue(_ line: SpokenLine) async; func beginListening() async; func endListening() async; func lineEvents() async -> AsyncStream<SpeechOut.LineEvent> }`, with `extension SpeechOut: LineSpeaker {}`
  - `public actor VoiceLoop: ListenObserver` with `init(followUps:parser:dispatcher:directory:approvals:speech:chimes:events:)` and `func start(utterances: AsyncStream<Listener.Utterance>) async`
  - Event log entries: `command send|status|stop|start|answer|unknown`, `latency <ms> ms`, never the words said.
  - Signposts on `com.earshot.app` / `command`: `wake`, `transcript`, `command`, `speech`.

- [ ] **Step 1: Write the failing tests**

`app/EarshotKit/Tests/EarshotKitTests/VoiceLoopTests.swift`:

```swift
import Foundation
import Testing
@testable import EarshotKit

actor FakeFollowUps: FollowUpListening {
    private(set) var calls: [Listener.FollowUp] = []
    private(set) var vocabulary: [String] = []
    func listenFollowUp(_ f: Listener.FollowUp, within: Duration?) async { calls.append(f) }
    func setVocabulary(_ v: [String]) async { vocabulary = v }
}

@Suite struct VoiceLoopTests {
    let mic = FakeMic()
    let ducker = FakeDucker()
    let followUps = FakeFollowUps()
    let chimes = FakeChimes()
    let transport = FakeTransport()
    let store = SessionStore()
    let approvalsDir: String = {
        let d = NSTemporaryDirectory() + "ek-vl-\(UUID().uuidString.prefix(6))"
        try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
        return d
    }()
    let secret = "0123456789abcdef0123456789abcdef"

    struct Rig {
        let loop: VoiceLoop
        let speech: SpeechOut
        let player: FakePlayer
        let book: ApprovalBook
        let heard: AsyncStream<Listener.Utterance>.Continuation
    }

    func rig(_ agents: [AgentEntry], blocking: Bool = false) async -> Rig {
        let player = FakePlayer(blocking: blocking)
        let speech = SpeechOut(synth: FakeSynth(), player: player, mic: mic, ducker: ducker, settle: .milliseconds(30))
        await speech.start()
        let runner = FakeRunner(agents)
        let directory = SessionDirectory(runner: runner, store: store, labeler: Labeler(model: nil, liveDir: NSTemporaryDirectory()),
                                         claudeJSON: "/nonexistent")
        await directory.refresh()
        let book = ApprovalBook(stateDir: approvalsDir, isAlive: { _ in true })
        let dispatcher = Dispatcher(directory: directory, store: store, transport: transport, runner: runner, approvals: book,
                                    say: { _ in }, receiptTimeout: .seconds(60), defaultsSuite: "ek-vl-\(UUID().uuidString)")
        let loop = VoiceLoop(followUps: followUps, parser: CommandParser(model: nil), dispatcher: dispatcher,
                             directory: directory, approvals: book, speech: speech, chimes: chimes, events: EventLog())
        let (stream, cont) = AsyncStream<Listener.Utterance>.makeStream()
        await loop.start(utterances: stream)
        return Rig(loop: loop, speech: speech, player: player, book: book, heard: cont)
    }

    func said(_ text: String, _ trigger: Listener.Trigger = .hotkey) -> Listener.Utterance {
        .init(text: text, trigger: trigger, endedAt: .now)
    }

    func approval(_ id: String = "1-1-1") -> AppMessage.Approval {
        .init(session: "s1", id: id, name: "billing service", what: "to run the migration",
              answer: "\(approvalsDir)/answer-s1-\(id)", secret: secret, pid: 1)
    }

    @Test func aCommandIsCarriedOutAndConfirmed() async {
        let r = await rig([agent("b", "blog", pid: 11)])
        let player = r.player
        r.heard.yield(said("Tell blog to deploy."))
        #expect(await eventually { await player.played == ["Sent to blog."] })
        #expect(await transport.sent.map(\.text) == ["deploy"])
    }

    @Test func notUnderstoodSendsNothing() async {
        let r = await rig([agent("b", "blog")])
        let player = r.player
        r.heard.yield(said("Banana."))
        #expect(await eventually { await player.played == ["Sorry, I didn't get that."] })
        #expect(await transport.sent.isEmpty)
    }

    /// Earshot must not hear its own "needs your OK" line as the answer.
    @Test func approvalWindowOpensOnlyAfterTheLineFinished() async {
        let r = await rig([agent("s1", "billing-service")], blocking: true)
        await r.book.apply(approval())
        await r.speech.enqueue(SpokenLine(text: "Hey, billing service needs your OK to run the migration.", kind: .need, session: "s1"))
        let player = r.player
        #expect(await eventually { await player.isPlaying })
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await followUps.calls.isEmpty)
        await player.finish()
        #expect(await eventually { await followUps.calls == [.approval(id: "1-1-1")] })
    }

    @Test func noWindowWithoutAnOpenPrompt() async {
        let r = await rig([agent("s1", "billing-service")])
        await r.speech.enqueue(SpokenLine(text: "Hey, billing service needs your input.", kind: .need, session: "s1"))
        await r.speech.waitUntilIdle()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await followUps.calls.isEmpty)
    }

    @Test func yesInTheWindowApproves() async throws {
        let r = await rig([agent("s1", "billing-service")])
        await r.book.apply(approval())
        let player = r.player
        r.heard.yield(said("Yeah.", .followUp(.approval(id: "1-1-1"))))
        #expect(await eventually { await player.played == ["Approved."] })
        #expect(await chimes.played == [.confirm])
        #expect(try String(contentsOfFile: "\(approvalsDir)/answer-s1-1-1-1", encoding: .utf8) == "allow \(secret)\n")
    }

    @Test func yesAfterTheDialogClosedSaysNothing() async {
        let r = await rig([agent("s1", "billing-service")])
        await r.book.apply(approval())
        await r.book.apply(.init(session: "s1", id: "1-1-1", state: "closed", by: "screen"))
        r.heard.yield(said("Yes.", .followUp(.approval(id: "1-1-1"))))
        try? await Task.sleep(for: .milliseconds(100))
        #expect(await r.player.played.isEmpty)
        #expect(await chimes.played.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: "\(approvalsDir)/answer-s1-1-1-1"))
    }

    @Test func otherWordsInTheWindowDoNothing() async {
        let r = await rig([agent("s1", "billing-service")])
        await r.book.apply(approval())
        r.heard.yield(said("Yes but use the other file.", .followUp(.approval(id: "1-1-1"))))
        try? await Task.sleep(for: .milliseconds(100))
        #expect(await r.player.played.isEmpty)
        #expect(await r.book.current.count == 1)
    }

    @Test func whichOneThenTheAnswer() async {
        let r = await rig([agent("a", "billing-service", name: "Fix refund rounding", pid: 10),
                           agent("b", "billing-service", name: "Invoice export", pid: 11)])
        let player = r.player
        r.heard.yield(said("Tell billing to run the tests."))
        #expect(await eventually { await followUps.calls == [.reply] })   // after the question was said
        #expect(await player.played == ["Billing service has two: Fix refund rounding and Invoice export. Which one?"])
        r.heard.yield(said("Invoice export.", .followUp(.reply)))
        #expect(await eventually { await transport.sent.map(\.pid) == [11] })
    }

    /// Other audio stays low from the wake word through the answer.
    @Test func duckingSpansTheCommandAndItsAnswer() async {
        let r = await rig([agent("b", "blog")])
        await r.loop.captureBegan(.hotkey)
        await r.loop.captureEnded(heard: true)
        #expect(await ducker.ends == 0)
        r.heard.yield(said("What's everyone doing?"))
        let player = r.player
        #expect(await eventually { await player.played.count == 1 })
        await r.speech.waitUntilIdle()
        #expect(await ducker.ends == 1)
    }

    @Test func aCaptureWithNothingHeardEndsListeningAtOnce() async {
        let r = await rig([agent("b", "blog")])
        await r.loop.captureBegan(.wake)
        await r.loop.captureEnded(heard: false)
        #expect(await ducker.ends == 1)
    }

    @Test func theWakeWordRefreshesTheVocabulary() async {
        let r = await rig([agent("a", "finebrief")])
        await r.loop.captureBegan(.wake)
        #expect(await eventually { await followUps.vocabulary.contains("finebrief") })
    }
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `swift test --package-path app/EarshotKit --filter VoiceLoopTests`
Expected: FAIL to compile.

- [ ] **Step 3: Write the loop**

`app/EarshotKit/Sources/EarshotKit/Core/VoiceLoop.swift`:

```swift
import Foundation
import os

public protocol FollowUpListening: Sendable {
    func listenFollowUp(_ f: Listener.FollowUp, within: Duration?) async
    func setVocabulary(_ v: [String]) async
}

extension Listener: FollowUpListening {}

/// The parts of SpeechOut the voice loop uses.
public protocol LineSpeaker: Sendable {
    func enqueue(_ line: SpokenLine) async
    func beginListening() async
    func endListening() async
    func lineEvents() async -> AsyncStream<SpeechOut.LineEvent>
}

extension SpeechOut: LineSpeaker {}

/// From what you said to what Earshot says back.
public actor VoiceLoop: ListenObserver {
    private let followUps: any FollowUpListening
    private let parser: CommandParser
    private let dispatcher: Dispatcher
    private let directory: SessionDirectory
    private let approvals: ApprovalBook
    private let speech: any LineSpeaker
    private let chimes: any Chimes
    private let events: EventLog
    private let signposter = OSSignposter(subsystem: "com.earshot.app", category: "command")
    private let latencyLog = Logger(subsystem: "com.earshot.app", category: "latency")

    /// A question Earshot asked ("Which one?"), waiting for its answer.
    private var pending: Dispatcher.Pending?
    /// Follow-up windows to open once a line has been said.
    private var afterLine: [UUID: Listener.FollowUp] = [:]
    /// When the command that led to a line ended, for the latency log.
    private var commandEnded: [UUID: ContinuousClock.Instant] = [:]
    /// A command was heard: listening ends once its answer is queued.
    private var endAfterAnswer = false

    public init(followUps: any FollowUpListening, parser: CommandParser, dispatcher: Dispatcher, directory: SessionDirectory,
                approvals: ApprovalBook, speech: any LineSpeaker, chimes: any Chimes, events: EventLog) {
        self.followUps = followUps; self.parser = parser; self.dispatcher = dispatcher; self.directory = directory
        self.approvals = approvals; self.speech = speech; self.chimes = chimes; self.events = events
    }

    public func start(utterances: AsyncStream<Listener.Utterance>) async {
        let lines = await speech.lineEvents()
        Task { for await e in lines { await self.lineEvent(e) } }
        Task { for await u in utterances { await self.handle(u) } }
    }

    // MARK: - ListenObserver

    public func captureBegan(_ trigger: Listener.Trigger) async {
        signposter.emitEvent("wake")
        await speech.beginListening()
        switch trigger {
        case .wake, .hotkey: Task { await self.prepare() }
        case .followUp: break
        }
    }

    public func captureEnded(heard: Bool) async {
        if heard { endAfterAnswer = true } else { await speech.endListening() }
    }

    /// While you talk: fresh sessions, their names boosted, the model warm.
    private func prepare() async {
        await directory.refresh()
        let names = await directory.vocabulary()
        await followUps.setVocabulary(names)
        await parser.prewarm(sessions: names)
    }

    // MARK: - Utterances

    private func handle(_ u: Listener.Utterance) async {
        signposter.emitEvent("transcript")
        switch u.trigger {
        case .followUp(.approval(let id)):
            // Only a clear yes or no. Anything else leaves the prompt as it is.
            if let allow = Grammar.approvalWord(u.text) {
                switch await approvals.answer(id, allow: allow) {
                case .written:
                    await chimes.play(.confirm)
                    await say(allow ? "Approved." : "Told it no.", after: u)
                case .closed: break   // answered on screen first: say nothing
                case .failed: await say("Couldn't answer it.", after: u)
                }
                await events.add("command answer")
            }
        case .followUp(.reply):
            if let p = pending {
                pending = nil
                await apply(await dispatcher.reply(u.text, to: p), after: u)
            }
        case .wake, .hotkey:
            pending = nil
            afterLine.removeAll()
            let c = await parser.parse(u.text, sessions: await directory.vocabulary())
            signposter.emitEvent("command")
            await events.add("command \(Self.kind(c))")
            await apply(await dispatcher.run(c), after: u)
        }
        if endAfterAnswer {
            endAfterAnswer = false
            await speech.endListening()
        }
    }

    private func apply(_ o: Dispatcher.Outcome, after u: Listener.Utterance) async {
        if o.sound { await chimes.play(.confirm) }
        if let s = o.spokeAbout { await directory.noteSpoke(about: s) }
        if let p = o.pending { pending = p }
        guard let text = o.line else { return }
        await say(text, after: u, then: o.pending == nil ? nil : .reply)
    }

    private func say(_ text: String, after u: Listener.Utterance, then followUp: Listener.FollowUp? = nil) async {
        let line = SpokenLine(text: text, kind: .confirm, session: "")
        commandEnded[line.id] = u.endedAt
        if let followUp { afterLine[line.id] = followUp }
        await speech.enqueue(line)
    }

    // MARK: - Lines

    private func lineEvent(_ e: SpeechOut.LineEvent) async {
        switch e {
        case .started(let line):
            if let ended = commandEnded.removeValue(forKey: line.id) {
                let d = ContinuousClock.now - ended
                let ms = Int(d.components.seconds * 1000 + d.components.attoseconds / 1_000_000_000_000_000)
                signposter.emitEvent("speech")
                latencyLog.info("latency \(ms, privacy: .public) ms")
                await events.add("latency \(ms) ms")
            }
        case .finished(let line):
            if !line.session.isEmpty { await directory.noteSpoke(about: line.session) }
            // Windows open only now, after Earshot's own line, so it never hears itself.
            if let f = afterLine.removeValue(forKey: line.id) {
                await followUps.listenFollowUp(f, within: nil)
            } else if line.kind == .need, !line.session.isEmpty, let a = await approvals.latest(session: line.session) {
                await followUps.listenFollowUp(.approval(id: a.id), within: nil)
            }
        }
    }

    static func kind(_ c: Command) -> String {
        switch c {
        case .send: "send"
        case .status: "status"
        case .stop: "stop"
        case .start: "start"
        case .answer: "answer"
        case .unknown: "unknown"
        }
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `swift test --package-path app/EarshotKit --filter VoiceLoopTests`
Expected: PASS.

- [ ] **Step 5: Run the whole package**

Run: `swift test --package-path app/EarshotKit`
Expected: PASS, every suite.

- [ ] **Step 6: Commit**

```bash
git add app/EarshotKit/Sources/EarshotKit/Core/VoiceLoop.swift app/EarshotKit/Tests/EarshotKitTests/VoiceLoopTests.swift
git commit -m "Voice loop: from what you said to the answer, windows only after Earshot's own line"
```

---
### Task 18: The real models, and the live listening stack

FluidAudio behind `SpeechGate`, `WakeSpotter` and `Transcriber`, the model download, and one builder that wires every part for the app.

**Files:**
- Create: `app/EarshotKit/Sources/EarshotKit/Listen/FluidListening.swift`
- Create: `app/EarshotKit/Sources/EarshotKit/Core/ListenStack.swift`
- Test: `app/EarshotKit/Tests/EarshotKitTests/FluidListeningTests.swift`

**Interfaces:**
- Consumes: the protocols from Task 7, `MicInput` and `SystemChimes` (Task 9), `CommandParser`, `FoundationCommandModel` (Task 11), `ClaudeCLI` (Task 12), `Labeler`, `FoundationLabelModel` (Task 13), `SessionDirectory` (Task 14), `CCSocketTransport` (Task 15), `Dispatcher` (Task 16), `VoiceLoop` (Task 17), `EarshotCore` (plan 1, with `approvals` from Task 2).
- Produces:
  - `public enum ListenModelFiles` with `static var present: Bool`
  - `public actor ListenModels` with `enum State: Sendable, Equatable { case missing, downloading(Double), ready, failed }`, `init()`, `var state: State`, `func download() async`, `func changes() -> AsyncStream<State>`
  - `public actor SileroGate: SpeechGate` with `init()`, `func load() async throws`
  - `public actor CtcWakeSpotter: WakeSpotter` with `init()`, `func load() async throws`, `static func threshold(_ sensitivity: Int) -> Float`
  - `public actor ParakeetTranscriber: Transcriber` with `init()`, `func unload()`
  - `public struct ListenStack: Sendable` with `listener`, `loop`, `directory`, `models`, `claudePath: String?`, `static func live(core: EarshotCore, config: @escaping @Sendable () -> EarshotConfig) async -> ListenStack`, `func loadWakeModels() async`

- [ ] **Step 1: Write the failing tests**

`app/EarshotKit/Tests/EarshotKitTests/FluidListeningTests.swift`. The model tests need the downloaded models (about 1 GB, Task 0 fetched them) and are opt-in. They use the Mac's `say` voice for test audio, which is enough to check the wiring; Task 21's eval uses real recordings.

```swift
@preconcurrency import FluidAudio
import Foundation
import Testing
@testable import EarshotKit

@Suite struct FluidListeningTests {
    @Test func sensitivityMapsAroundTheDefaultThreshold() {
        #expect(CtcWakeSpotter.threshold(5) == -15)
        #expect(CtcWakeSpotter.threshold(1) == -11)    // stricter
        #expect(CtcWakeSpotter.threshold(10) == -20)   // looser
        #expect(CtcWakeSpotter.threshold(99) == -20)
    }

    static var modelsOn: Bool { ProcessInfo.processInfo.environment["EARSHOT_TEST_MODELS"] == "1" }

    /// 16 kHz mono samples of the Mac's voice saying it.
    func spoken(_ text: String) throws -> [Float] {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "ek-say-\(UUID().uuidString.prefix(6)).aiff")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        p.arguments = ["-o", url.path, text]
        try p.run()
        p.waitUntilExit()
        defer { try? FileManager.default.removeItem(at: url) }
        return try AudioConverter().resampleAudioFile(url)
    }

    @Test(.enabled(if: modelsOn)) func modelsArePresent() {
        #expect(ListenModelFiles.present)
    }

    @Test(.enabled(if: modelsOn)) func transcribesACommand() async throws {
        let t = ParakeetTranscriber()
        let text = try await t.transcribe(try spoken("Hey Earshot, what's everyone doing?"), vocabulary: [])
        #expect(text.lowercased().contains("everyone"))
    }

    @Test(.enabled(if: modelsOn)) func vocabularyHelpsASessionName() async throws {
        let t = ParakeetTranscriber()
        let text = try await t.transcribe(try spoken("Tell finebrief to run the tests."), vocabulary: ["finebrief", "billing service"])
        #expect(text.lowercased().contains("finebrief"))
    }

    @Test(.enabled(if: modelsOn)) func spotsTheWakePhraseOnly() async throws {
        let s = CtcWakeSpotter()
        try await s.load()
        #expect(await s.heardWake(try spoken("Hey Earshot, what's everyone doing?"), sensitivity: 5))
        #expect(!(await s.heardWake(try spoken("Good morning everyone, the build passed."), sensitivity: 5)))
    }

    @Test(.enabled(if: modelsOn)) func theGateFindsSpeechAndItsEnd() async throws {
        let g = SileroGate()
        try await g.load()
        let audio = [Float](repeating: 0, count: 8192) + (try spoken("Run the tests.")) + [Float](repeating: 0, count: 32_768)
        var chunker = Chunker()
        var edges: [SpeechEdge] = []
        for c in chunker.push(audio) { if let e = await g.feed(c) { edges.append(e) } }
        #expect(edges == [.start, .end])
    }
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `swift test --package-path app/EarshotKit --filter FluidListeningTests`
Expected: FAIL to compile.

- [ ] **Step 3: Write the FluidAudio parts**

`app/EarshotKit/Sources/EarshotKit/Listen/FluidListening.swift`:

```swift
@preconcurrency import FluidAudio
import Foundation
import os

/// Where FluidAudio keeps the listening models:
/// ~/Library/Application Support/FluidAudio/Models.
public enum ListenModelFiles {
    static var vadDir: URL { MLModelConfigurationUtils.defaultModelsDirectory().appending(path: "silero-vad") }
    static var ctcDir: URL { CtcModels.defaultCacheDirectory(for: .ctc110m) }
    static var asrDir: URL { AsrModels.defaultCacheDirectory(for: .v2) }

    public static var present: Bool {
        let vad = (try? FileManager.default.contentsOfDirectory(atPath: vadDir.path))?.contains { $0.hasSuffix(".mlmodelc") } ?? false
        return vad && CtcModels.modelsExist(at: ctcDir) && AsrModels.modelsExist(at: asrDir, version: .v2)
    }
}

/// Downloads the three listening models once. Speaking works meanwhile.
public actor ListenModels {
    public enum State: Sendable, Equatable { case missing, downloading(Double), ready, failed }

    public private(set) var state: State {
        didSet { if state != oldValue { conts.values.forEach { $0.yield(state) } } }
    }
    private var conts: [UUID: AsyncStream<State>.Continuation] = [:]
    private let log = Logger(subsystem: "com.earshot.app", category: "models")

    public init() { state = ListenModelFiles.present ? .ready : .missing }

    public func download() async {
        if case .downloading = state { return }
        guard state != .ready else { return }
        state = .downloading(0)
        do {
            _ = try await VadManager()   // small; fetched when missing
            state = .downloading(0.05)
            try await CtcModels.download(variant: .ctc110m)
            state = .downloading(0.3)
            try await AsrModels.download(version: .v2, progressHandler: { p in
                Task { await self.progress(0.3 + 0.7 * p.fractionCompleted) }
            })
            state = ListenModelFiles.present ? .ready : .failed
        } catch {
            log.error("model download failed: \(error.localizedDescription, privacy: .public)")
            state = .failed
        }
    }

    private func progress(_ p: Double) {
        if case .downloading = state { state = .downloading(min(p, 0.99)) }
    }

    public func changes() -> AsyncStream<State> {
        let (stream, cont) = AsyncStream<State>.makeStream()
        let id = UUID()
        conts[id] = cont
        cont.yield(state)
        cont.onTermination = { [weak self] _ in Task { await self?.remove(id) } }
        return stream
    }
    private func remove(_ id: UUID) { conts[id] = nil }
}

/// Stage 2: Silero VAD, 4096-sample chunks, speech ends after 600 ms of silence.
public actor SileroGate: SpeechGate {
    private var vad: VadManager?
    private var state = VadStreamState.initial()
    private let config = VadSegmentationConfig(minSilenceDuration: 0.6)

    public init() {}

    public func load() async throws {
        guard vad == nil else { return }
        vad = try await VadManager()
    }

    public func reset() async { state = VadStreamState.initial() }

    public func feed(_ chunk: [Float]) async -> SpeechEdge? {
        guard let vad, let r = try? await vad.processStreamingChunk(chunk, state: state, config: config) else { return nil }
        state = r.state
        switch r.event?.kind {
        case .speechStart: return .start
        case .speechEnd: return .end
        default: return nil
        }
    }
}

/// The CTC model is shared: the wake word spotter and the vocabulary boost use it.
actor CtcShared {
    static let shared = CtcShared()
    private var models: CtcModels?
    private var phraseTokens: [String: [Int]] = [:]

    func models() async throws -> CtcModels {
        if let models { return models }
        let m = try await CtcModels.downloadAndLoad(variant: .ctc110m)
        models = m
        return m
    }

    func tokens(_ text: String) async throws -> [Int] {
        if let t = phraseTokens[text] { return t }
        let tokenizer = try await CtcTokenizer.load(from: CtcModels.defaultCacheDirectory(for: .ctc110m))
        let t = tokenizer.encode(text)
        phraseTokens[text] = t
        return t
    }
}

/// Stage 3: "Hey Earshot" in the first 2 s of a speech segment.
public actor CtcWakeSpotter: WakeSpotter {
    public static let phrase = "hey earshot"
    private var spotter: CtcKeywordSpotter?
    private var vocab: CustomVocabularyContext?
    private let log = Logger(subsystem: "com.earshot.app", category: "wake")

    public init() {}

    public func load() async throws {
        guard spotter == nil else { return }
        let models = try await CtcShared.shared.models()
        let tokens = try await CtcShared.shared.tokens(Self.phrase)
        spotter = CtcKeywordSpotter(models: models, blankId: models.vocabulary.count)
        vocab = CustomVocabularyContext(terms: [CustomVocabularyTerm(text: Self.phrase, ctcTokenIds: tokens)])
    }

    /// Sensitivity 5 is FluidAudio's default spotter threshold (-15). Each
    /// step moves it by 1: higher wakes more easily.
    public static func threshold(_ sensitivity: Int) -> Float { -10 - Float(min(max(sensitivity, 1), 10)) }

    public func heardWake(_ samples: [Float], sensitivity: Int) async -> Bool {
        guard let spotter, let vocab else { return false }
        let threshold = Self.threshold(sensitivity)
        guard let r = try? await spotter.spotKeywordsWithLogProbs(audioSamples: samples, customVocabulary: vocab,
                                                                    minScore: threshold) else { return false }
        let hit = r.detections.contains { $0.score >= threshold }
        if hit { log.info("wake") }
        return hit
    }
}

/// Stage 4: Parakeet TDT v2 (English) on the whole clip, then the session
/// names boosted. Loaded on first use, unloaded after 10 idle minutes and
/// when macOS is short on memory.
public actor ParakeetTranscriber: Transcriber {
    private var asr: AsrManager?
    private var boosting: (names: [String], session: VocabularyBoostingSession)?
    private var idleTask: Task<Void, Never>?
    private var pressure: DispatchSourceMemoryPressure?
    private let log = Logger(subsystem: "com.earshot.app", category: "transcriber")
    static let idle: Duration = .seconds(600)

    public init() {}

    public func prewarm() async { _ = try? await loaded() }

    public func transcribe(_ samples: [Float], vocabulary: [String]) async throws -> String {
        let asr = try await loaded()
        var decoder = TdtDecoderState.make()
        let result = try await asr.transcribe(samples, decoderState: &decoder)
        scheduleUnload()
        guard !vocabulary.isEmpty, !result.text.isEmpty, let timings = result.tokenTimings else { return result.text }
        let session = try await boostingSession(vocabulary)
        return await session.rescore(text: result.text, tokenTimings: timings, audioSamples: samples)?.text ?? result.text
    }

    public func unload() {
        if asr != nil { log.info("unloaded the transcriber") }
        asr = nil
        boosting = nil
        idleTask?.cancel()
        idleTask = nil
    }

    private func loaded() async throws -> AsrManager {
        if let asr { return asr }
        let models = try await AsrModels.downloadAndLoad(version: .v2)
        let m = AsrManager(config: .default)
        try await m.loadModels(models)
        asr = m
        watchMemory()
        log.info("loaded the transcriber")
        return m
    }

    private func boostingSession(_ names: [String]) async throws -> VocabularyBoostingSession {
        if let b = boosting, b.names == names { return b.session }
        let terms = names.map { CustomVocabularyTerm(text: $0) }
        let s = try await VocabularyBoostingSession(vocabulary: CustomVocabularyContext(terms: terms),
                                                    ctcModels: try await CtcShared.shared.models())
        boosting = (names, s)
        return s
    }

    private func scheduleUnload() {
        idleTask?.cancel()
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: ParakeetTranscriber.idle)
            guard !Task.isCancelled else { return }
            await self?.unload()
        }
    }

    private func watchMemory() {
        guard pressure == nil else { return }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .global(qos: .utility))
        source.setEventHandler { [weak self] in Task { await self?.unload() } }
        source.resume()
        pressure = source
    }
}
```

If Task 0 found that real wakes score lower than -15 on this Mac (for example -13 to -17), keep sensitivity 5 at -15 but note the measured range in a comment above `threshold`; do not change the mapping without the probe's numbers.

- [ ] **Step 4: Write the stack builder**

`app/EarshotKit/Sources/EarshotKit/Core/ListenStack.swift`:

```swift
import Foundation

/// Every listening part, wired. The app owns one.
public struct ListenStack: Sendable {
    public let listener: Listener
    public let loop: VoiceLoop
    public let directory: SessionDirectory
    public let models: ListenModels
    public let claudePath: String?
    let gate: SileroGate
    let spotter: CtcWakeSpotter

    public static func live(core: EarshotCore, config: @escaping @Sendable () -> EarshotConfig) async -> ListenStack {
        let gate = SileroGate(), spotter = CtcWakeSpotter(), transcriber = ParakeetTranscriber(), chimes = SystemChimes()
        let listener = Listener(input: MicInput(deviceUID: { config().inputDevice }), gate: gate, spotter: spotter,
                                transcriber: transcriber, chimes: chimes)
        let claudePath = await Task.detached { ClaudeCLI.locate() }.value
        let runner = ClaudeCLI(path: claudePath ?? "/nonexistent/claude")
        let directory = SessionDirectory(runner: runner, store: core.sessions, labeler: Labeler(model: FoundationLabelModel()))
        let speech = core.speech
        let dispatcher = Dispatcher(directory: directory, store: core.sessions, transport: CCSocketTransport(), runner: runner,
                                    approvals: core.approvals,
                                    say: { text in await speech.enqueue(SpokenLine(text: text, kind: .confirm, session: "")) })
        let loop = VoiceLoop(followUps: listener, parser: CommandParser(model: FoundationCommandModel()), dispatcher: dispatcher,
                             directory: directory, approvals: core.approvals, speech: speech, chimes: chimes, events: core.events)
        await listener.setObserver(loop)
        await loop.start(utterances: listener.utterances)
        return ListenStack(listener: listener, loop: loop, directory: directory, models: ListenModels(),
                           claudePath: claudePath, gate: gate, spotter: spotter)
    }

    /// The VAD and the spotter, which stay loaded while the wake word may listen.
    public func loadWakeModels() async {
        try? await gate.load()
        try? await spotter.load()
    }
}
```

- [ ] **Step 5: Run the tests**

Run: `swift test --package-path app/EarshotKit --filter FluidListeningTests`
Expected: PASS (the model tests skip).

With the models downloaded: `EARSHOT_TEST_MODELS=1 swift test --package-path app/EarshotKit --filter FluidListeningTests`
Expected: PASS. If `vocabularyHelpsASessionName` fails, run `earshot-probe transcribe` on the same clip with and without the term and record both in the probe notes; it is the one check that depends on how the Mac's `say` voice pronounces a made-up word, so a fail here with a pass on a real recording (Task 21) is acceptable. Say so in the commit message.

- [ ] **Step 6: Run the whole package**

Run: `swift test --package-path app/EarshotKit`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add app/EarshotKit/Sources/EarshotKit/Listen/FluidListening.swift app/EarshotKit/Sources/EarshotKit/Core/ListenStack.swift app/EarshotKit/Tests/EarshotKitTests/FluidListeningTests.swift
git commit -m "Listening: Silero, the CTC spotter and Parakeet behind the listener, and the live stack"
```

---
### Task 19: The app listens: hotkey tap, permissions, menu and App Nap

**Files:**
- Create: `app/Earshot/HotkeyTap.swift`
- Modify: `app/Earshot/AppModel.swift`
- Modify: `app/Earshot/MenuContent.swift`
- Modify: `app/Earshot/Earshot.entitlements`
- Modify: `app/project.yml`

**Interfaces:**
- Consumes: `ListenStack` (Task 18), `ListenPolicy`, `ListenInputs`, `ListenBlock` (Task 5), `HotkeyDetector`, `KeyEvent` (Task 6), `SystemWatch` (Task 9), `ListenAvailability` (Task 2), `EarshotConfig` listening keys (Task 3), `Listener.Phase` (Task 7).
- Produces, on `AppModel`: `listenPhase: Listener.Phase`, `listenBlock: ListenBlock?`, `modelState: ListenModels.State`, `micAllowed: Bool`, `hotkeyAllowed: Bool`, `func requestMic() async`, `func requestHotkeyAccess()`, `func downloadModels()`, `func listeningChanged()` (call after any listening setting is saved). Task 20's views use these.

The app target has no unit tests (plan 1 kept all logic in `EarshotKit`); this task is checked by building and by the manual steps at the end.

- [ ] **Step 1: Permissions in the project**

In `app/project.yml`, under `info.properties`, add after `NSAudioCaptureUsageDescription`:

```yaml
        NSMicrophoneUsageDescription: "Earshot listens for \"Hey Earshot\" and for commands while you hold the hotkey. Audio stays on this Mac and is never saved."
```

Under `entitlements`, replace `properties: {}` with:

```yaml
      properties:
        com.apple.security.device.audio-input: true
```

Run: `cd app && xcodegen generate && cd ..`
Expected: `Earshot/Info.plist` gains `NSMicrophoneUsageDescription` and `Earshot/Earshot.entitlements` gains the audio input key. Input Monitoring (for the hotkey) needs no key; macOS asks when the tap is created.

- [ ] **Step 2: Write the hotkey tap**

`app/Earshot/HotkeyTap.swift`:

```swift
import CoreGraphics
import EarshotKit
import Foundation

/// Watches modifier and key events for the hotkey. Listen only: it never
/// changes or blocks an event. Needs Input Monitoring permission.
@MainActor final class HotkeyTap {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var detector: HotkeyDetector
    private let onAction: @MainActor (HotkeyDetector.Action) -> Void

    init(hotkey: EarshotConfig.Hotkey, onAction: @escaping @MainActor (HotkeyDetector.Action) -> Void) {
        detector = HotkeyDetector(hotkey: hotkey)
        self.onAction = onAction
    }

    static var allowed: Bool { CGPreflightListenEventAccess() }

    /// Shows macOS's Input Monitoring prompt (once) and adds Earshot to the list.
    static func requestAccess() { _ = CGRequestListenEventAccess() }

    func setHotkey(_ h: EarshotConfig.Hotkey) { detector = HotkeyDetector(hotkey: h) }

    /// False when Input Monitoring is not allowed yet.
    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        let mask = CGEventMask((1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue))
        let me = Unmanaged.passUnretained(self).toOpaque()
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                        eventsOfInterest: mask, callback: { _, type, event, refcon in
            if let refcon {
                let tap = Unmanaged<HotkeyTap>.fromOpaque(refcon).takeUnretainedValue()
                MainActor.assumeIsolated { tap.handle(type, event) }
            }
            return Unmanaged.passUnretained(event)
        }, userInfo: me) else { return false }
        tap = t
        source = CFMachPortCreateRunLoopSource(nil, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        return true
    }

    func stop() {
        if let t = tap { CGEvent.tapEnable(tap: t, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
            return
        }
        let e: KeyEvent = type == .keyDown
            ? .keyDown
            : .flagsChanged(keyCode: UInt16(event.getIntegerValueField(.keyboardEventKeycode)), flags: event.flags.rawValue)
        if let a = detector.handle(e, at: ProcessInfo.processInfo.systemUptime) { onAction(a) }
    }
}
```

The tap callback runs on the main run loop, so `MainActor.assumeIsolated` holds; the `HotkeyTap` lives as long as the app model, so the unretained pointer stays valid.

- [ ] **Step 3: Listening state in the app model**

In `app/Earshot/AppModel.swift`:

Add `import AVFoundation` at the top.

Add these properties next to `speechState`:

```swift
    var listenPhase: Listener.Phase = .off
    var listenBlock: ListenBlock?
    var modelState: ListenModels.State = .missing
    var micAllowed = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    var hotkeyAllowed = HotkeyTap.allowed
```

Add these next to the other `@ObservationIgnored` properties:

```swift
    @ObservationIgnored private(set) var stack: ListenStack?
    @ObservationIgnored private let watch = SystemWatch()
    @ObservationIgnored private var hotkeyTap: HotkeyTap?
    @ObservationIgnored private var micInUse = false
    @ObservationIgnored private var wakeLoaded = false
    @ObservationIgnored private var activity: (any NSObjectProtocol)?
```

Replace `menuIcon`:

```swift
    var menuIcon: String {
        if mutedUntil != nil { return "speaker.slash" }
        switch listenPhase {
        case .capturing: return "mic.fill"
        case .transcribing: return "ellipsis.circle"
        default: break
        }
        switch speechState {
        case .speaking: return "waveform"
        case .holding: return "pause.circle"
        case .idle: return listenPhase == .waiting ? "ear.badge.waveform" : "ear"
        }
    }
```

In `start()`, after the `Task` that starts the core, add the listening setup:

```swift
        Task {
            let stack = await ListenStack.live(core: live.core) { box.value }
            self.stack = stack
            Task { for await s in await stack.models.changes() { modelState = s; await listeningChanged() } }
            Task { for await p in await stack.listener.phaseChanges() { listenPhase = p; updateActivity() } }
            Task { for await _ in watch.changes() { await listeningChanged() } }
            Task { for await _ in await live.core.sessions.changes() { await listeningChanged() } }
            Task {
                for await busy in live.mic.changes() {
                    micInUse = busy
                    await stack.listener.setMicBusy(busy)
                    await listeningChanged()
                }
            }
            await listeningChanged()
        }
        // Actions before the stack exists are ignored (hotkey(_:) checks it).
        hotkeyTap = HotkeyTap(hotkey: configBox.value.hotkey) { [weak self] action in self?.hotkey(action) }
        hotkeyAllowed = hotkeyTap?.start() ?? false
```

Also update `speechState` handling so App Nap follows speaking; replace the existing state task with:

```swift
        Task { for await s in await live.core.speech.stateChanges() { speechState = s; updateActivity() } }
```

Add a `// MARK: Listening` section:

```swift
    // MARK: Listening

    /// Applies the current settings and system state: whether the wake word
    /// listens, what the menu says, and whether approvals are taken.
    func listeningChanged() async {
        guard let stack else { return }
        let c = configBox.value
        micAllowed = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        var i = ListenInputs()
        i.micAllowed = micAllowed
        i.modelsReady = modelState == .ready
        if case .downloading(let p) = modelState { i.modelProgress = p }
        i.wakeWord = c.wakeWord
        i.battery = c.wakeOnBattery
        i.onBattery = watch.state.onBattery
        i.lowPower = watch.state.lowPower
        i.locked = watch.state.locked
        i.asleep = watch.state.asleep
        i.micInUse = micInUse
        i.liveSessions = sessions.count
        i.hotkey = c.hotkey
        core?.availability.canListen = ListenPolicy.canListen(i)
        let wake = ListenPolicy.wakeBlock(i)
        listenBlock = wake
        hotkeyTap?.setHotkey(c.hotkey)
        await stack.listener.setSensitivity(c.wakeSensitivity)
        if wake == nil, !wakeLoaded {
            wakeLoaded = true
            await stack.loadWakeModels()
        }
        await stack.listener.setWakeArmed(wake == nil)
    }

    private func hotkey(_ action: HotkeyDetector.Action) {
        guard let listener = stack?.listener else { return }
        switch action {
        case .down:
            var i = ListenInputs()
            i.micAllowed = micAllowed; i.modelsReady = modelState == .ready; i.micInUse = micInUse
            i.locked = watch.state.locked; i.asleep = watch.state.asleep
            guard ListenPolicy.commandBlock(i) == nil else { return }
            Task { await listener.hotkeyDown() }
        case .up: Task { await listener.hotkeyUp() }
        case .cancel: Task { await listener.hotkeyCancel() }
        }
    }

    func requestMic() async {
        _ = await AVCaptureDevice.requestAccess(for: .audio)
        await listeningChanged()
    }

    func requestHotkeyAccess() {
        HotkeyTap.requestAccess()
        hotkeyAllowed = hotkeyTap?.start() ?? false
    }

    func downloadModels() {
        guard let stack else { return }
        Task { await stack.models.download() }
    }

    /// No App Nap while the mic is open or Earshot speaks: a napping process
    /// delays the audio work.
    private func updateActivity() {
        let busy = listenPhase != .off || speechState == .speaking
        if busy, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep],
                                                             reason: "Listening or speaking")
        } else if !busy, let a = activity {
            ProcessInfo.processInfo.endActivity(a)
            activity = nil
        }
    }
```

In `save(_:)`, after `config = c`, add `Task { await listeningChanged() }`.

In `diagnostics()`, add these lines before `Recent events:` (no transcripts, no prompt text):

```swift
        Listening: \(listenPhase), \(listenBlock.map(ListenPolicy.menuLine) ?? "wake word armed")
        Wake word: \(c.wakeWord ? "on" : "off"), sensitivity \(c.wakeSensitivity), battery rule \(c.wakeOnBattery.rawValue)
        Hotkey: \(c.hotkey.rawValue), Input Monitoring \(hotkeyAllowed ? "allowed" : "not allowed")
        Mic permission: \(micAllowed ? "allowed" : "not allowed")
        Speech models: \(modelState)
        claude: \(stack?.claudePath ?? "not found")
```

- [ ] **Step 4: The menu says what listening is doing**

In `app/Earshot/MenuContent.swift`, after the `startError` line, add:

```swift
        switch model.modelState {
        case .missing, .failed:
            Button(model.modelState == .failed ? "Retry Downloading Speech Models" : "Download Speech Models (about 1 GB)") {
                model.downloadModels()
            }
        case .downloading(let p):
            Text("Downloading speech models: \(Int(p * 100))%")
        case .ready:
            if let b = model.listenBlock { Text(ListenPolicy.menuLine(b)) } else { Text("Listening for \u{201C}Hey Earshot\u{201D}") }
        }
        if model.config.hotkey != .off, !model.hotkeyAllowed {
            Button("Allow the Hotkey…") { model.requestHotkeyAccess() }
        }
        Divider()
```

- [ ] **Step 5: Build**

Run: `cd app && xcodegen generate && xcodebuild -project Earshot.xcodeproj -scheme Earshot -configuration Debug -destination 'platform=macOS' build | tail -3 && cd ..`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 6: Check it by hand**

Run the app (`open app/build/...` or from Xcode) and check, writing each result into `tests/app-e2e.md` in Task 21:

1. The menu shows "Download Speech Models" on a Mac without them; after the download it shows the listening line.
2. With the wake word off (the default): "The wake word is off. Hold the hotkey to talk."
3. Hold Right Option for a second, say "what's everyone doing", release: the chime, then the roll call.
4. Tap Right Option, and type Option+e: no chime.
5. Start a call (FaceTime audio to yourself, or QuickTime audio recording) and hold the hotkey: nothing happens; the menu says another app uses the mic.

- [ ] **Step 7: Commit**

```bash
git add app/project.yml app/Earshot/Info.plist app/Earshot/Earshot.entitlements app/Earshot/HotkeyTap.swift app/Earshot/AppModel.swift app/Earshot/MenuContent.swift
git commit -m "App: hold the hotkey to talk, the wake word follows the rules, the menu says why"
```

---
### Task 20: The orb, Listening settings and onboarding

**Files:**
- Create: `app/Earshot/OrbPanel.swift`
- Modify: `app/Earshot/EarshotApp.swift`
- Modify: `app/Earshot/SettingsView.swift`
- Modify: `app/Earshot/OnboardingView.swift`

**Interfaces:**
- Consumes: `AppModel.listenPhase`, `speechState`, `listenBlock`, `modelState`, `micAllowed`, `hotkeyAllowed`, `requestMic()`, `requestHotkeyAccess()`, `downloadModels()`, `save(_:)` (Task 19), `AudioDevices` (Task 9), `EarshotConfig` listening keys (Task 3).
- Produces: `OrbPanel` (a floating panel shown only while Earshot listens to a command, thinks, or speaks), a Listening settings tab, and the seven onboarding steps from the spec.

- [ ] **Step 1: Write the orb**

`app/Earshot/OrbPanel.swift`:

```swift
import AppKit
import EarshotKit
import SwiftUI

/// A small panel at the top of the screen while Earshot hears a command,
/// works on it, or talks. It never takes focus and ignores clicks.
@MainActor final class OrbPanel {
    private let panel: NSPanel
    private let model: AppModel

    init(model: AppModel) {
        self.model = model
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 220, height: 44),
                        styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = NSHostingView(rootView: OrbView().environment(model))
        observe()
    }

    private func observe() {
        withObservationTracking {
            _ = model.listenPhase
            _ = model.speechState
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.update()
                self?.observe()
            }
        }
        update()
    }

    private func update() {
        let show: Bool
        switch model.listenPhase {
        case .capturing, .transcribing: show = true
        default: show = model.speechState == .speaking
        }
        if show {
            guard let screen = NSScreen.main else { return }
            let f = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: f.midX - panel.frame.width / 2, y: f.maxY - panel.frame.height - 8))
            panel.orderFrontRegardless()
        } else {
            panel.orderOut(nil)
        }
    }
}

private struct OrbView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .symbolEffect(.pulse, isActive: !reduceMotion && isListening)
                .foregroundStyle(isListening ? Color.accentColor : .primary)
            Text(label).font(.callout.weight(.medium))
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
        .glassEffect(.regular, in: .capsule)
        .accessibilityElement(children: .combine)
    }

    private var isListening: Bool {
        if case .capturing = model.listenPhase { return true }
        return false
    }

    private var symbol: String {
        switch model.listenPhase {
        case .capturing: "mic.fill"
        case .transcribing: "ellipsis"
        default: "waveform"
        }
    }

    private var label: String {
        switch model.listenPhase {
        case .capturing: "Listening"
        case .transcribing: "Working on it"
        default: "Earshot"
        }
    }
}
```

`glassEffect` is the macOS 26 Liquid Glass modifier. If the build reports it missing, use `.background(.regularMaterial, in: .capsule)`.

- [ ] **Step 2: Show it**

In `app/Earshot/EarshotApp.swift`, add a property and create the panel when the app starts:

```swift
    @State private var orb: OrbPanel?
```

In the `.task` on the menu bar label, after `model.start()`:

```swift
                    if orb == nil { orb = OrbPanel(model: model) }
```

- [ ] **Step 3: The Listening tab**

In `app/Earshot/SettingsView.swift`, add the tab after Voice:

```swift
            ListeningTab().tabItem { Label("Listening", systemImage: "mic") }
```

and the view:

```swift
private struct ListeningTab: View {
    @Environment(AppModel.self) private var model
    @State private var inputs: [AudioDevices.Device] = []

    var body: some View {
        Form {
            Section {
                Toggle("Listen for \u{201C}Hey Earshot\u{201D}",
                       isOn: Binding(get: { model.config.wakeWord },
                                     set: { on in model.save { $0.set("EARSHOT_WAKE", on ? "on" : "off") } }))
                Picker("On battery", selection: Binding(get: { model.config.wakeOnBattery },
                                                        set: { v in model.save { $0.set("EARSHOT_WAKE_BATTERY", v.rawValue) } })) {
                    Text("Listen, except in Low Power Mode").tag(EarshotConfig.WakeBattery.lowpower)
                    Text("Always listen").tag(EarshotConfig.WakeBattery.always)
                    Text("Only listen on power").tag(EarshotConfig.WakeBattery.power)
                }
                .disabled(!model.config.wakeWord)
                Slider(value: Binding(get: { Double(model.config.wakeSensitivity) },
                                      set: { v in model.save { $0.set("EARSHOT_WAKE_SENSITIVITY", String(Int(v))) } }),
                       in: 1...10, step: 1) {
                    Text("Sensitivity")
                } minimumValueLabel: { Text("Fewer false starts") } maximumValueLabel: { Text("Fewer misses") }
                .disabled(!model.config.wakeWord)
            }
            Section {
                Picker("Hold to talk", selection: Binding(get: { model.config.hotkey },
                                                          set: { v in model.save { $0.set("EARSHOT_HOTKEY", v.rawValue) } })) {
                    Text("Right Option").tag(EarshotConfig.Hotkey.rightOption)
                    Text("Right Command").tag(EarshotConfig.Hotkey.rightCommand)
                    Text("Off").tag(EarshotConfig.Hotkey.off)
                }
                if model.config.hotkey != .off, !model.hotkeyAllowed {
                    Text("macOS needs to allow Earshot to see the hotkey (Input Monitoring). It only watches that one key.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Allow the Hotkey…") { model.requestHotkeyAccess() }
                }
            }
            Section {
                Picker("Microphone", selection: Binding(get: { model.config.inputDevice ?? "" },
                                                        set: { v in model.save { $0.set("EARSHOT_INPUT", v.isEmpty ? nil : v) } })) {
                    Text("Automatic").tag("")
                    ForEach(inputs, id: \.uid) { Text($0.name).tag($0.uid) }
                }
                Text("Automatic uses the built-in mic while your output is a Bluetooth headset, so the headset keeps its full sound quality.")
                    .font(.caption).foregroundStyle(.secondary)
                if !model.micAllowed {
                    Button("Allow the Microphone…") { Task { await model.requestMic() } }
                }
            }
            Text("Audio stays on this Mac. Earshot keeps the last few seconds in memory to hear a command, and never saves or sends it.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear {
            model.reloadConfig()
            inputs = AudioDevices.all().filter(\.hasInput)
        }
    }
}
```

- [ ] **Step 4: Onboarding in seven steps**

Replace `app/Earshot/OnboardingView.swift`:

```swift
import EarshotKit
import SwiftUI

/// First launch, in the spec's order: what Earshot does, the voice, the
/// mic and the wake word, the hotkey, the speech models, lowering other
/// audio, and a first command.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismissWindow) private var dismissWindow
    @AppStorage("onboarded") private var onboarded = false
    @State private var step = 0
    static let last = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch step {
            case 0:
                Text("Earshot reads Claude Code updates aloud, and takes commands by voice").font(.title2.bold())
                Text("It tells you when a session needs your OK, might be stuck, or finishes. Say \u{201C}Hey Earshot\u{201D} or hold a key to send a session a prompt, ask what everyone is doing, stop a session, start one, or answer a permission prompt with yes or no.")
            case 1:
                Text("Voice").font(.title2.bold())
                Text("Earshot uses the voice you set up with the plugin: \(model.config.engine.rawValue). You can change it in Settings.")
                Button("Play a Test Line") { model.playTestLine() }
            case 2:
                Text("Microphone and wake word").font(.title2.bold())
                Text("Earshot hears you on this Mac only. Audio is kept in memory for a few seconds and never saved or sent.")
                if model.micAllowed {
                    Label("The microphone is allowed.", systemImage: "checkmark.circle")
                } else {
                    Button("Allow the Microphone") { Task { await model.requestMic() } }
                }
                Toggle("Listen for \u{201C}Hey Earshot\u{201D} (the mic indicator stays on while it listens)",
                       isOn: Binding(get: { model.config.wakeWord },
                                     set: { on in model.save { $0.set("EARSHOT_WAKE", on ? "on" : "off") } }))
                    .disabled(!model.micAllowed)
            case 3:
                Text("Hold to talk").font(.title2.bold())
                Text("Hold Right Option, say the command, and let go. A quick tap or Option with another key does nothing. macOS asks to allow Input Monitoring so Earshot can see that key.")
                if model.hotkeyAllowed {
                    Label("The hotkey is allowed.", systemImage: "checkmark.circle")
                } else {
                    Button("Allow the Hotkey") { model.requestHotkeyAccess() }
                }
            case 4:
                Text("Speech models").font(.title2.bold())
                Text("Listening needs about 1 GB of speech models, downloaded once. Earshot keeps speaking while they download.")
                switch model.modelState {
                case .ready: Label("The models are ready.", systemImage: "checkmark.circle")
                case .downloading(let p): ProgressView(value: p) { Text("Downloading") }
                case .missing: Button("Download") { model.downloadModels() }
                case .failed: Button("Try Again") { model.downloadModels() }
                }
            case 5:
                Text("Lower other audio").font(.title2.bold())
                Text("While Earshot talks or listens, it can turn music and videos down to \(Int(model.config.duckLevel * 100))%. macOS will ask for permission to capture system audio. Earshot only plays other apps back quieter; it never records or saves their audio.")
                Toggle("Lower other apps while Earshot talks",
                       isOn: Binding(get: { model.config.duckEnabled },
                                     set: { on in model.save { $0.set("EARSHOT_DUCK", on ? nil : "off") } }))
                Toggle("Open Earshot when you log in",
                       isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
            default:
                Text("Try it").font(.title2.bold())
                Text(model.config.wakeWord
                     ? "Say: \u{201C}Hey Earshot, what's everyone doing?\u{201D}"
                     : "Hold Right Option and say: \u{201C}What's everyone doing?\u{201D}")
                if let b = model.listenBlock, model.config.wakeWord { Text(ListenPolicy.menuLine(b)).foregroundStyle(.secondary) }
            }
            Spacer()
            HStack {
                if step > 0 { Button("Back") { step -= 1 } }
                Spacer()
                Button(step < Self.last ? "Continue" : "Done") {
                    if step < Self.last {
                        if step == 5, model.config.duckEnabled { model.playTestLine() }   // the first tap: macOS asks now
                        step += 1
                    } else {
                        onboarded = true
                        dismissWindow(id: "onboarding")
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 480, height: 320)
    }
}
```

- [ ] **Step 5: Build**

Run: `cd app && xcodegen generate && xcodebuild -project Earshot.xcodeproj -scheme Earshot -configuration Debug -destination 'platform=macOS' build | tail -3 && cd ..`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 6: Check it by hand**

1. Reset onboarding (`defaults delete com.earshot.app onboarded`), launch: seven steps, Back works, each permission button shows its macOS prompt once.
2. Hold the hotkey: the orb appears at the top center within a moment, says "Listening", then "Working on it", stays while the answer plays, then goes.
3. With Reduce Motion on (System Settings, Accessibility, Display), the mic icon does not pulse.
4. Settings, Listening: each control writes its key to `~/.config/earshot/config` (`cat` it).

- [ ] **Step 7: Commit**

```bash
git add app/Earshot/OrbPanel.swift app/Earshot/EarshotApp.swift app/Earshot/SettingsView.swift app/Earshot/OnboardingView.swift
git commit -m "App: the orb while listening or speaking, Listening settings, onboarding in seven steps"
```

---
### Task 21: Evals, budgets, the integration check and the release checklist

The spec's section 7 checks that need the real models, real audio and real sessions. Nothing here ships to users; it decides whether listening is ready to release.

**Files:**
- Modify: `app/EarshotKit/Package.swift` (the probe also depends on `EarshotKit`)
- Modify: `app/EarshotKit/Sources/earshot-probe/main.swift` (add `parse-eval`, `wake-eval`, `send`)
- Create: `tests/eval/parser-cases.tsv`
- Create: `scripts/eval-parser.sh`, `scripts/eval-listener.sh`, `scripts/latency.sh`, `scripts/send-integration.sh`
- Modify: `tests/app-e2e.md`, `README.md`, `.gitignore`

**Interfaces:**
- Consumes: `CommandParser`, `FoundationCommandModel` (Task 11), `Command`, `NameMatch` (Task 14), `CtcWakeSpotter`, `ParakeetTranscriber` (Task 18), `SessionDirectory`, `Dispatcher` (Task 16), and the probe from Task 0.
- Produces: `earshot-probe parse-eval TSV`, `earshot-probe wake-eval DIR`, `earshot-probe send TARGET PROMPT`; the four scripts.

- [ ] **Step 1: Let the probe use EarshotKit**

In `app/EarshotKit/Package.swift`, change the probe target:

```swift
        .executableTarget(name: "earshot-probe", dependencies: ["EarshotKit", .product(name: "FluidAudio", package: "FluidAudio")]),
```

Add `import EarshotKit` to `main.swift`, and three cases to the `switch` in `main()`:

```swift
        case "parse-eval" where a.count == 2: try await parseEval(URL(fileURLWithPath: a[1]))
        case "wake-eval" where a.count == 2: try await wakeEval(URL(fileURLWithPath: a[1]))
        case "send" where a.count == 3: await send(target: a[1], prompt: a[2])
```

Add the functions at the end of `main.swift`:

```swift
// MARK: - Evals (plan 2, task 21)

/// One line per case: transcript, tab, expected. Expected is one of
///   send|<target or empty>   status|<target or empty>   stop|<target or empty>
///   start|<project>   answer|allow|<target or empty>   answer|deny|<target or empty>   unknown
/// Action and target are scored, as the spec asks; the prompt is not.
func parseEval(_ url: URL) async throws {
    let sessions = ["billing service", "blog", "earshot", "finebrief", "refund rounding", "invoice export", "docs site"]
    let parser = CommandParser(model: FoundationCommandModel())
    var pass = 0, total = 0, grammar = 0
    for line in try String(contentsOf: url, encoding: .utf8).split(separator: "\n") where !line.hasPrefix("#") {
        let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 else { continue }
        total += 1
        if Grammar.parse(parts[0], known: sessions) != nil { grammar += 1 }
        let got = await parser.parse(parts[0], sessions: sessions)
        if matches(got, parts[1]) { pass += 1 } else { print("MISS\t\(parts[0])\twant \(parts[1])\tgot \(got)") }
    }
    print(String(format: "%d of %d (%.0f%%), %d by the grammar", pass, total, Double(pass) / Double(max(total, 1)) * 100, grammar))
}

func matches(_ c: Command, _ want: String) -> Bool {
    let w = want.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
    func same(_ got: String?, _ expected: String?) -> Bool {
        let e = expected.flatMap { $0.isEmpty ? nil : $0 }
        guard let e else { return got == nil || got!.isEmpty }
        return got.map { NameMatch.score($0, e) >= 0.78 } ?? false
    }
    switch (c, w.first ?? "") {
    case (.send(let t, _), "send"): return same(t, w.count > 1 ? w[1] : nil)
    case (.status(let t), "status"): return same(t, w.count > 1 ? w[1] : nil)
    case (.stop(let t, _), "stop"): return same(t, w.count > 1 ? w[1] : nil)
    case (.start(let p, _), "start"): return same(p, w.count > 1 ? w[1] : nil)
    case (.answer(let allow, let t), "answer"):
        return (allow ? "allow" : "deny") == (w.count > 1 ? w[1] : "") && same(t, w.count > 2 ? w[2] : nil)
    case (.unknown, "unknown"): return true
    default: return false
    }
}

/// DIR holds WAV files and manifest.tsv: file, tab, 1 if it says the wake
/// phrase else 0, tab, words the transcript must contain (may be empty).
func wakeEval(_ dir: URL) async throws {
    let spotter = CtcWakeSpotter()
    try await spotter.load()
    let transcriber = ParakeetTranscriber()
    var hits = 0, misses = 0, falseWakes = 0, words = 0, wordsTotal = 0
    for line in try String(contentsOf: dir.appending(path: "manifest.tsv"), encoding: .utf8).split(separator: "\n") {
        let p = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard p.count >= 2 else { continue }
        let samples = try AudioConverter().resampleAudioFile(dir.appending(path: p[0]))
        let woke = await spotter.heardWake(Array(samples.prefix(32_000)), sensitivity: 5)
        switch (p[1] == "1", woke) {
        case (true, true): hits += 1
        case (true, false): misses += 1; print("MISSED WAKE\t\(p[0])")
        case (false, true): falseWakes += 1; print("FALSE WAKE\t\(p[0])")
        default: break
        }
        if p.count > 2, !p[2].isEmpty {
            wordsTotal += 1
            let text = (try? await transcriber.transcribe(samples, vocabulary: ["billing service", "finebrief", "earshot", "blog"])) ?? ""
            if text.lowercased().contains(p[2].lowercased()) { words += 1 } else { print("WORDS\t\(p[0])\twant \(p[2])\tgot \(text)") }
        }
    }
    print("wake: \(hits) hit, \(misses) missed, \(falseWakes) false; transcripts: \(words) of \(wordsTotal) right")
}

/// Sends one prompt through the real directory and dispatcher, as a voice command would.
func send(target: String, prompt: String) async {
    guard let path = ClaudeCLI.locate() else { print("claude not found"); return }
    let runner = ClaudeCLI(path: path)
    let store = SessionStore()
    let directory = SessionDirectory(runner: runner, store: store, labeler: Labeler(model: nil))
    let dispatcher = Dispatcher(directory: directory, store: store, transport: CCSocketTransport(), runner: runner,
                                approvals: ApprovalBook(), say: { print("later: \($0)") }, receiptTimeout: .seconds(8))
    let o = await dispatcher.run(.send(target: target, prompt: prompt))
    print(o.line ?? "(nothing said)")
    try? await Task.sleep(for: .seconds(9))   // time for the receipt check
}
```

Run: `swift build --package-path app/EarshotKit -c release --product earshot-probe`
Expected: builds.

- [ ] **Step 2: The parser cases**

`tests/eval/parser-cases.tsv` (tab separated; a `#` line is a comment). These are the phrasings the grammar mostly does not match, so they test the model:

```
# transcript	expected
could billing service run the integration tests again	send|billing service
have blog rebuild the RSS feed	send|blog
I need finebrief to look at the failing build	send|finebrief
earshot should commit what it has	send|earshot
let billing know the API key changed	send|billing service
get the docs site to fix the broken links	send|docs site
can the refund rounding session add a test for zero	send|refund rounding
billing service, push the branch when you're done	send|billing service
make blog write a draft about the launch	send|blog
run the tests again	send|
keep going	send|
can you have it summarize what it did	send|
ask the invoice export one to retry	send|invoice export
tell the blog session it can deploy now	send|blog
send finebrief a message to pull main first	send|finebrief
see if billing can speed up the query	send|billing service
let earshot rename the file to config dot swift	send|earshot
blog, use the dark theme	send|blog
I want billing to undo the last change	send|billing service
over in finebrief please rerun the linter	send|finebrief
docs site should regenerate the sitemap	send|docs site
let it finish then open a PR	send|
tell whoever is on refunds to stop logging so much	send|refund rounding
billing service needs to update the changelog	send|billing service
could the earshot session check the hooks file	send|earshot
have docs site bump the version number	send|docs site
let finebrief know it can merge	send|finebrief
billing service can you rerun the migration	send|billing service
what's invoice export doing right now	status|invoice export
how many sessions are open	status|
what's billing up to	status|billing service
how far along is blog	status|blog
is finebrief done yet	status|finebrief
any news from earshot	status|earshot
where are we with the docs site	status|docs site
how is the refund rounding thing going	status|refund rounding
did invoice export finish	status|invoice export
give me the rundown	status|
who needs me	status|
what's going on with everything	status|
anything need my attention	status|
catch me up	status|
what are my sessions doing	status|
is anybody stuck	status|
how's it all going	status|
what's the blog session working on	status|blog
has billing finished the tests	status|billing service
check how finebrief is doing	status|finebrief
tell me what earshot did	status|earshot
update on docs site	status|docs site
make billing stop	stop|billing service
kill the blog session	stop|blog
cancel what finebrief is doing	stop|finebrief
earshot stop right now	stop|earshot
pause the docs site	stop|docs site
halt everything on refund rounding	stop|refund rounding
billing service stop what you're doing	stop|billing service
shut down the invoice export one	stop|invoice export
stop the blog now please	stop|blog
end finebrief	stop|finebrief
spin up a new one in blog	start|blog
open claude in finebrief and fix the readme	start|finebrief
I want a fresh session in the docs site	start|docs site
kick off a session in earshot to write tests	start|earshot
new claude session for billing service	start|billing service
start something in blog to update dependencies	start|blog
fire up finebrief	start|finebrief
launch a session in the docs site to check links	start|docs site
create a session in earshot	start|earshot
begin work in billing service on the refund bug	start|billing service
yes go for it	answer|allow|
sure thing	answer|allow|
let billing do it	answer|allow|billing service
approve the blog one	answer|allow|blog
yeah allow finebrief	answer|allow|finebrief
go ahead with earshot	answer|allow|earshot
OK for docs site	answer|allow|docs site
fine let it run	answer|allow|
no don't let billing do that	answer|deny|billing service
deny the blog request	answer|deny|blog
nope not for finebrief	answer|deny|finebrief
reject earshot	answer|deny|earshot
don't allow it	answer|deny|
absolutely not	answer|deny|
tell docs site no	answer|deny|docs site
the weather is nice today	unknown
what time is it	unknown
play some music	unknown
uh never mind	unknown
I was talking to someone else	unknown
open safari	unknown
remind me to call mom	unknown
how do I make pasta	unknown
mm hmm	unknown
testing one two three	unknown
earshot is a cool name	unknown
what's two plus two	unknown
turn off the lights	unknown
that's all for now	unknown
sorry wrong button	unknown
```

That is 100 cases. The spec's bar is 95% or better on action and target.

- [ ] **Step 3: The eval scripts**

`scripts/eval-parser.sh`:

```bash
#!/bin/bash
# eval-parser.sh: the command parser (grammar, then the on-device model) on
# tests/eval/parser-cases.tsv. Needs Apple Intelligence on. Bar: 95%.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
swift run --package-path "$ROOT/app/EarshotKit" -c release earshot-probe parse-eval "$ROOT/tests/eval/parser-cases.tsv"
```

`scripts/eval-listener.sh`:

```bash
#!/bin/bash
# eval-listener.sh [record]: wake word and transcription on recordings of
# your own voice. "record" walks you through making them (they stay in
# tests/eval/listener, which git ignores: it is your voice). Then it scores
# them. Includes Earshot's own lines played through the speakers, which
# must never wake it.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; D=$ROOT/tests/eval/listener
P="swift run --package-path $ROOT/app/EarshotKit -c release earshot-probe"
mkdir -p "$D"
if [ "$1" = record ]; then
  : > "$D/manifest.tsv"
  rec() {   # rec <file> <wake 0|1> <words> <what to do>
    read -r -p "$4 Press Return, then speak within 4 s." _
    $P record 4 "$D/$1" >/dev/null && printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$D/manifest.tsv"
  }
  rec quiet-1.wav 1 everyone 'Quiet room: say "Hey Earshot, what is everyone doing?"'
  rec quiet-2.wav 1 "billing" 'Say "Hey Earshot, tell billing service to run the tests."'
  rec quiet-3.wav 1 finebrief 'Say "Hey Earshot, what is finebrief doing?"'
  rec music-1.wav 1 everyone 'Play music out loud, then say "Hey Earshot, what is everyone doing?"'
  rec music-2.wav 0 "" 'Keep the music playing. Say nothing.'
  rec talk-1.wav 0 "" 'Have someone talk, or play a podcast. Say nothing to Earshot.'
  rec talk-2.wav 0 "" 'Say "Hey, are you there? I will be right back."'
  rec silence.wav 0 "" 'Stay silent.'
  for line in "Hey, billing service needs your OK to run the migration." "Still on blog, about six minutes in." "Three sessions. Billing service is working."; do
    f="own-$((++n)).wav"
    echo "Recording Earshot's own line: $line"
    ( sleep 0.5; say "$line" ) & $P record 4 "$D/$f" >/dev/null; wait
    printf '%s\t0\t\n' "$f" >> "$D/manifest.tsv"
  done
fi
$P wake-eval "$D"
```

`scripts/latency.sh`:

```bash
#!/bin/bash
# latency.sh [hours]: p50 and p95 from the end of a command to the start of
# Earshot's answer, from the app's log. Bar: p50 under 1000 ms, p95 under 1500 ms over 20 hotkey commands.
h=${1:-2}
log show --last "${h}h" --style compact --predicate 'subsystem == "com.earshot.app" AND category == "latency"' 2>/dev/null \
  | grep -oE 'latency [0-9]+ ms' | awk '{print $2}' | sort -n \
  | awk '{ v[NR] = $1 } END { if (NR == 0) { print "no commands logged"; exit 1 }
          p50 = v[int((NR - 1) * 0.5) + 1]; p95 = v[int((NR - 1) * 0.95) + 1]
          printf "%d commands: p50 %d ms, p95 %d ms\n", NR, p50, p95 }'
```

`scripts/send-integration.sh`:

```bash
#!/bin/bash
# send-integration.sh: a real background session gets a prompt through the
# Dispatcher and answers it. Uses a little Claude usage. Terminal and desktop
# sessions are checked by hand (tests/app-e2e.md).
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
P="swift run --package-path $ROOT/app/EarshotKit -c release earshot-probe"
cd "$ROOT" || exit 1
claude --bg "Wait for the next message." >/dev/null || { echo "couldn't start a background session"; exit 1; }
sleep 8
id=$(claude agents --json | jq -r --arg cwd "$ROOT" '[.[] | select(.kind == "background" and .cwd == $cwd)] | last | .sessionId')
[ -n "$id" ] && [ "$id" != null ] || { echo "no background session found"; exit 1; }
token="EARSHOT-$RANDOM"
$P send earshot "Reply with exactly $token and nothing else."
sleep 20
if claude logs "$id" 2>/dev/null | grep -q "$token"; then echo "ok: the background session answered"; r=0
else echo "FAIL: no answer with $token in claude logs $id"; r=1; fi
claude stop "$id" >/dev/null 2>&1
exit $r
```

Run: `chmod +x scripts/eval-parser.sh scripts/eval-listener.sh scripts/latency.sh scripts/send-integration.sh`

Add to `.gitignore`:

```
tests/eval/listener/
```

- [ ] **Step 4: Run the evals and record the numbers**

These need the user (Apple Intelligence on, the mic, real recordings, a little Claude usage). Ask them to run, in order, and paste the output:

```bash
bash scripts/eval-parser.sh
bash scripts/eval-listener.sh record
bash scripts/send-integration.sh
```

Then, with the app built from this branch running and the wake word on: 20 hotkey commands, then `bash scripts/latency.sh 1`; and 10 minutes in a quiet room with `bash scripts/listen-power.sh Earshot 10`.

Append the results to `docs/superpowers/specs/2026-10-11-listening-probe.md` under "Plan 2 evals", with pass or fail against: parser 95%; every wake recording hit at sensitivity 5; 0 false wakes, including all `own-*.wav`; session names right in at least 4 of 5 transcripts; latency p50 under 1000 ms and p95 under 1500 ms; Earshot idle with the wake word off at about 0% CPU and under 50 MB; wake word on in a quiet room at "Low" energy impact.

A miss on the parser bar: add the missed phrasings' shapes to the grammar (Task 10) where they are unambiguous, and adjust the model instructions in `FoundationCommandModel.session` for the rest; re-run. A false wake: lower the default sensitivity by one and re-run the wake eval.

- [ ] **Step 5: The release checklist**

Append to `tests/app-e2e.md`:

~~~markdown
## Listening (plan 2)

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
| Hotkey command | Hold Right Option: "what's everyone doing", release | Chime, orb "Listening" then "Working on it", the roll call |
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
| Diagnostics | Copy Diagnostics | Listening, models, permissions and claude path; no transcripts, no prompts |
~~~

- [ ] **Step 6: README**

In `README.md`, replace the "Earshot for Mac (optional)" bullet list with:

```markdown
- It turns music and videos down while it talks or listens, then back up.
- Hold Right Option and talk, or turn on the wake word, "Hey Earshot". You can:
  - send a session a prompt: "tell billing service to run the tests"
  - ask what is going on: "what's everyone doing?" or "what's billing doing?"
  - stop a session: "stop billing", or "stop billing now" for a background session
  - start a session: "start a new session in blog to fix the header"
  - answer a permission prompt: after "billing service needs your OK", say "yes" or "no"
- Everything it hears stays on your Mac. Audio is kept in memory for a few seconds and never saved or sent. Commands are understood on the Mac too (Apple Intelligence, with a fixed set of phrases when it is off).
- The menu shows your open sessions, the ones that need you first.
- "Mute for 1 hour" is in the menu.
- Settings for the voice, the level, the style and listening are in one place.

Listening needs macOS 26, the microphone permission, Input Monitoring for the hotkey, and about 1 GB of speech models, downloaded once.
```

- [ ] **Step 7: Commit**

```bash
git add app/EarshotKit/Package.swift app/EarshotKit/Sources/earshot-probe/main.swift tests/eval/parser-cases.tsv scripts/eval-parser.sh scripts/eval-listener.sh scripts/latency.sh scripts/send-integration.sh tests/app-e2e.md README.md .gitignore docs/superpowers/specs/2026-10-11-listening-probe.md
git commit -m "Listening: evals, budgets, an integration check and the release checklist"
```

The release itself (version bump, signing, notarization, Sparkle, the cask, and `/earshot:setup` offering the download) needs the user's Developer ID certificate and keys; it follows `scripts/release-app.sh` and is not part of this plan.

---

## Self-review notes

- Spec coverage: section 2 (cascade: Tasks 4, 5, 7, 18; latency: Tasks 7, 17, 21; memory: Task 18; power: Tasks 0, 9, 19, 21; budgets: Tasks 0, 21), section 3 (protocol: Tasks 1, 2; finding the target: Task 14; the four commands: Task 16; barge-in and calls: Tasks 7, 8, 19; lowering audio while listening: Task 8; safety: Tasks 2, 15, 16), section 4 (names: Task 13), section 5 "Sending into sessions" (Tasks 12, 16), "Hearing" (Tasks 5, 7, 9, 18, 19), section 6 first launch, menu and settings (Tasks 19, 20), section 7 (Tasks 0, 10 to 18, 21), section 8 items 1 and 7 to 9. Voice approvals "The app side": Tasks 2, 10, 16, 17.
- Left out on purpose: the Keychain move (see Deviations), the release (needs the user), VS Code sessions and other languages (out of scope in the spec).
