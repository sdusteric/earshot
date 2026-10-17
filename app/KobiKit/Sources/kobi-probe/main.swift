// kobi-probe: measures Kobi's listening cascade on this Mac (plan 2, task 0).
//   record SECS OUT.wav      records the mic at 16 kHz mono, for evals
//   spot WAV...              VAD, then the keyword spotter once per speech segment
//   transcribe WAV [TERM...] Parakeet TDT v2, then vocabulary rescoring with TERMs
//   listen MINUTES           the live cascade on the mic, with CPU use per minute
//   parse-eval TSV           the command parser on tests/eval/parser-cases.tsv
//   wake-eval DIR            wake word (spotter, Apple's confirm, the finish rule) and
//                            transcripts on recordings (DIR/manifest.tsv)
//   hear WAV...              a recorded command as the app takes it: Parakeet with the
//                            live session names, the parser, then the answer for a
//                            status or greeting (read-only: nothing is sent)
//   parse SESSIONS TEXT...   the grammar and the tolerant reading of each text (no model)
//   hear-bench MANIFEST SESSIONS
//                            commands through the transcriber and parser, scored
//                            (tests/hearing: make-audio.sh makes the audio)
//   wake-bench MANIFEST... [--out OUT.tsv] [--confirmers ctc,apple,parakeet] [--limit N]
//                            the wake word's spotter and second looks on many files, cut
//                            into segments as the listener cuts them, swept over thresholds
//   wake-rescore TSV... [--threshold T]
//                            wake-bench's --out rows rescored from the heard text, stripWake vs
//                            Listener.wakeWords, for apple, parakeet and the two OR'd, and end to
//                            end (Apple's confirm, then the finish rule on the head texts), with
//                            false wakes counted as dispatch or window
//   send TARGET PROMPT       one prompt through the real directory and dispatcher
//   send-id ID PROMPT        the same, to the session with this id
import AVFoundation
import Darwin
import KobiKit
@preconcurrency import FluidAudio
import Foundation

let wakePhrase = CtcWakeSpotter.phrase
let segmentSpotAt = 24_000          // 1.5 s: spot a segment this long, or when it ends
let spotWindow = 32_000             // at most 2 s; at the 1.5 s spot only the first 1.5 s is there
let energyThreshold: Float = 0.008  // RMS; below it the VAD does not run

@main struct Probe {
    static func main() async throws {
        let a = Array(CommandLine.arguments.dropFirst())
        switch a.first {
        case "record" where a.count == 3: try await record(seconds: Double(a[1]) ?? 5, to: URL(fileURLWithPath: a[2]))
        case "spot" where a.count >= 2: try await spot(a.dropFirst().map { URL(fileURLWithPath: $0) })
        case "transcribe" where a.count >= 2: try await transcribe(URL(fileURLWithPath: a[1]), terms: Array(a.dropFirst(2)))
        case "listen": try await listen(minutes: Double(a.count > 1 ? a[1] : "5") ?? 5)
        case "parse-eval" where a.count == 2: try await parseEval(URL(fileURLWithPath: a[1]))
        case "wake-eval" where a.count == 2: try await wakeEval(URL(fileURLWithPath: a[1]))
        case "parse" where a.count >= 3: await parseText(sessionsFile: URL(fileURLWithPath: a[1]), Array(a.dropFirst(2)))
        case "hear-bench" where a.count == 3: try await hearBench(URL(fileURLWithPath: a[1]), sessionsFile: URL(fileURLWithPath: a[2]))
        case "wake-bench" where a.count >= 2: try await wakeBench(Array(a.dropFirst()))
        case "wake-rescore" where a.count >= 2: try wakeRescore(Array(a.dropFirst()))
        case "hear" where a.count >= 2: try await hear(a.dropFirst().map { URL(fileURLWithPath: $0) })
        case "send" where a.count == 3: await send(target: a[1], prompt: a[2])
        case "send-id" where a.count == 3: await send(id: a[1], prompt: a[2])
        default:
            print("usage: kobi-probe record SECS OUT.wav | spot WAV... | transcribe WAV [TERM...] | listen MINUTES | parse-eval TSV | wake-eval DIR | hear WAV... | hear-bench MANIFEST SESSIONS | wake-bench MANIFEST... [--out OUT.tsv] [--confirmers ctc,apple,parakeet] [--limit N] | wake-rescore TSV... [--threshold T] | send TARGET PROMPT | send-id ID PROMPT")
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
/// segment with its first 1.5 s: when it reaches 1.5 s, or all of it when it ends sooner.
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
    print("Listening for \(minutes) min. Say \"Hey Kobi\" now and then.")
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

// MARK: - Evals (plan 2, task 21)

/// One line per case: transcript, expected. Expected is one of
///   send|<target or empty>   status|<target or empty>   stop|<target or empty>
///   start|<project>   answer|allow|<target or empty>   answer|deny|<target or empty>   unknown
/// Action and target are scored, as the spec asks; the prompt is not.
func parseEval(_ url: URL) async throws {
    let sessions = ["billing service", "blog", "kobi", "finebrief", "refund rounding", "invoice export", "docs site"]
    let parser = CommandParser(model: FoundationCommandModel())
    // KOBI_EVAL_RAW=1: for each miss, also what the model alone answered, before the checks on it.
    let raw = ProcessInfo.processInfo.environment["KOBI_EVAL_RAW"] == "1" ? FoundationCommandModel() : nil
    var pass = 0, total = 0
    // Which stage decided each case, and how many of those it got right: the grammar,
    // the tolerant reading, the model (as CommandParser.parse runs them with one
    // hearing), or the approval window, where only Grammar.windowAnswer runs.
    let stages = ["grammar", "tolerant", "model", "window"]
    var decided: [String: Int] = [:], right: [String: Int] = [:]
    var timings: [Int] = []
    let talkMs = Int(ProcessInfo.processInfo.environment["KOBI_EVAL_TALK_MS"] ?? "") ?? 1000
    for line in try String(contentsOf: url, encoding: .utf8).split(separator: "\n") where !line.hasPrefix("#") {
        let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 else { continue }
        total += 1
        let got: Command
        let stage: String
        if parts[1] == "noanswer" {
            // Said in the approval window, it must answer nothing ("let it go", "let me think").
            stage = "window"
            got = Grammar.windowAnswer(parts[0]).map { .answer(allow: $0, target: nil) } ?? .quiet
        } else if parts[1].hasPrefix("answer|"), parts[1].hasSuffix("|") {
            // A yes or no naming no session is said in the approval window, where only a clear answer counts.
            stage = "window"
            got = Grammar.windowAnswer(parts[0]).map { .answer(allow: $0, target: nil) } ?? .unknown
        } else {
            // With one hearing the grammar's answer is final, .unknown and .quiet included.
            stage = Grammar.parse(parts[0], known: sessions) != nil ? "grammar"
                : Tolerant.parse(parts[0], known: sessions, gated: false) != nil ? "tolerant" : "model"
            // As the app does when the hotkey or wake word fires: the model warms up while
            // you talk. KOBI_EVAL_TALK_MS is how long that is (default 1000, under most commands).
            await parser.prewarm(sessions: sessions)
            try? await Task.sleep(for: .milliseconds(talkMs))
            let t0 = ContinuousClock.now
            got = await parser.parse(parts[0], sessions: sessions)
            timings.append(ms(t0))
        }
        decided[stage, default: 0] += 1
        if matches(got, parts[1]) { pass += 1; right[stage, default: 0] += 1 } else {
            var line = "MISS\t\(parts[0])\twant \(parts[1])\tgot \(got) (\(stage))"
            if let raw {
                line += "\tmodel \(String(describing: await raw.parse(parts[0], sessions: sessions)))"
                await raw.prewarm(sessions: sessions)
                line += "\twarm \(String(describing: await raw.parse(parts[0], sessions: sessions)))"
            }
            print(line)
        }
    }
    print(String(format: "%d of %d (%.0f%%)", pass, total, Double(pass) / Double(max(total, 1)) * 100))
    print("right by stage: " + stages.filter { decided[$0] != nil }
        .map { "\($0) \(right[$0] ?? 0) of \(decided[$0]!)" }.joined(separator: ", "))
    if !timings.isEmpty {
        let t = timings.sorted()
        print("parse ms: median \(t[t.count / 2]), p90 \(t[t.count * 9 / 10]), max \(t.last!), over 3 s: \(t.filter { $0 >= 3000 }.count)")
    }
    if total == 0 { print("FAIL: no cases"); exit(1) }
    if Double(pass) / Double(total) < 0.95 { print("FAIL: below the 95% bar"); exit(1) }
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
    // Read back and sent on a yes: understood, with one more step.
    case (.confirmSend(let t, _), "send"): return same(t, w.count > 1 ? w[1] : nil)
    case (.status(let t), "status"): return same(t, w.count > 1 ? w[1] : nil)
    case (.stop(let t, _), "stop"): return same(t, w.count > 1 ? w[1] : nil)
    case (.start(let p, _), "start"): return same(p, w.count > 1 ? w[1] : nil)
    case (.answer(let allow, let t), "answer"):
        return (allow ? "allow" : "deny") == (w.count > 1 ? w[1] : "") && same(t, w.count > 2 ? w[2] : nil)
    case (.unknown, "unknown"): return true
    case (.quiet, "quiet"), (.greet, "greet"), (.stopAll, "stopall"), (.repeatLast, "repeat"), (.quiet, "noanswer"): return true
    default: return false
    }
}

/// DIR holds WAV files and manifest.tsv: file, 1 if it says the wake phrase
/// else 0, words the transcript must contain (may be empty), and for Kobi's
/// own lines the line it was saying (may be left out).
/// A recording wakes as the listener would wake on it at sensitivity 5: the spotter fires
/// on its head (CtcWakeSpotter.threshold), Apple's recognizer reads the head within the
/// confirm limit and the wake passes when its words start with the phrase in any tier
/// (Listener.wakeWords), or, with no answer, only on the strict score
/// (CtcWakeSpotter.unconfirmedThreshold). Then the finish rule (Listener.finishRemainder) on
/// the transcripts, heard without the names that spell the wake phrase (Listener.wakeVocabulary):
/// a greeting and the phrase written as such, in the unboosted words or the second hearing,
/// sends what follows it; a wake passed on words without it sends nothing and only opens the
/// command window; a wake passed on the score alone without it is dropped (it chimed, then closes).
/// False wakes are counted in two kinds: dispatch (words went out as a command) and window
/// (a chime and nothing sent). A wake that only opened the window counts as a hit, and is
/// listed, since its command would have to be said again.
func wakeEval(_ dir: URL) async throws {
    let timing = Listener.Timing()
    let spotter = CtcWakeSpotter()
    try await spotter.load()
    let apple = AppleTranscriber()
    let confirmer = AppleHeadConfirmer(apple)
    await confirmer.prepare()
    print("apple ready: \(await apple.isReady)")
    let transcriber = ParakeetTranscriber()
    // A session named kobi, as the app would have; the wake's own clip is heard without it.
    let vocabulary = Listener.wakeVocabulary(["billing service", "finebrief", "kobi", "blog"])
    var hits = 0, windowHits = 0, misses = 0, dispatches = 0, windows = 0, words = 0, wordsTotal = 0, rows = 0
    for line in try String(contentsOf: dir.appending(path: "manifest.tsv"), encoding: .utf8).split(separator: "\n") {
        let p = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard p.count >= 2 else { continue }
        rows += 1
        let samples = try AudioConverter().resampleAudioFile(dir.appending(path: p[0]))
        // The head the listener spots and confirms on. It spots on the start of a speech
        // segment, so a recording should start with the wake phrase.
        let head = Array(samples.prefix(timing.spotWindowSamples))
        let score = await spotter.wakeScore(head) ?? -.infinity
        var woke = score >= CtcWakeSpotter.threshold(5)
        var why = "spotter \(scoreText(score))"
        var passedOnWords = false
        // What the finish sends: nil when it sends nothing (the window, or a dropped wake).
        var sent: String?
        // Passed on the score alone and the transcript lacks the phrase: it chimed, then closed.
        var dropped = false
        if woke {
            // Nil past the limit, as the listener takes a confirm that runs too long.
            let heard = await benchBounded(timing.confirmLimit, String?.none) { await confirmer.headText(head) }
            if let heard {
                let tier = Listener.wakeWords(heard)
                passedOnWords = tier != nil
                woke = passedOnWords
                why += ", confirm heard \"\(heard)\"\(tier == .bare ? " (bare)" : "")"
            } else {
                woke = score >= CtcWakeSpotter.unconfirmedThreshold
                why += ", no confirm answer"
            }
        }
        var text = ""
        let wantWords = p.count > 2 && !p[2].isEmpty
        if woke || wantWords {
            let r = try? await transcriber.transcribeBoth(samples, vocabulary: vocabulary)
            text = r?.text ?? ""
            if woke {
                let second = await apple.hear(samples, names: vocabulary)
                let rest = Listener.finishRemainder(text, plain: r?.plain, second: second, passedOnWords: passedOnWords)
                sent = rest.flatMap { $0.isEmpty ? nil : $0 }
                why += ", transcript \"\(text)\""
                why += rest == nil ? (passedOnWords ? ", no phrase in it: only the window opens" : ", fails the finish rule")
                    : sent.map { ", sends \"\($0)\"" } ?? ", the phrase alone: the window opens"
                dropped = rest == nil && !passedOnWords
            }
        }
        // Column 4: the line Kobi was saying. The listener ignores the spotter while Kobi
        // says the wake phrase itself. Any other line it would cut off, so that counts as a false wake.
        if woke, p.count > 3, Listener.mentionsWake(p[3]) {
            woke = false
            print("OWN WAKE PHRASE, IGNORED\t\(p[0])")
        }
        switch (p[1] == "1", woke) {
        case (true, true) where dropped: misses += 1; print("MISSED WAKE\t\(p[0])\t\(why)")
        case (true, true):
            hits += 1
            if sent == nil, wantWords { windowHits += 1; print("WINDOW ONLY\t\(p[0])\t\(why)") }
        case (true, false): misses += 1; print("MISSED WAKE\t\(p[0])\t\(why)")
        case (false, true) where sent != nil: dispatches += 1; print("FALSE WAKE, DISPATCH\t\(p[0])\t\(why)")
        case (false, true): windows += 1; print("FALSE WAKE, WINDOW\t\(p[0])\t\(why)")
        default: break
        }
        if wantWords {
            wordsTotal += 1
            if text.lowercased().contains(p[2].lowercased()) { words += 1 } else { print("WORDS\t\(p[0])\twant \(p[2])\tgot \(text)") }
        }
    }
    print("wake: \(hits) hit (\(windowHits) of them only opened the window, the command lost), \(misses) missed, "
          + "\(dispatches + windows) false (\(dispatches) dispatch, \(windows) window); transcripts: \(words) of \(wordsTotal) right")
    var reasons: [String] = []
    if rows == 0 { reasons.append("the manifest is empty") }
    if misses > 0 { reasons.append("\(misses) missed wake(s)") }
    if dispatches > 0 { reasons.append("\(dispatches) false wake(s) that dispatch") }
    if windows > 0 { reasons.append("\(windows) false wake(s) that open the window") }
    if wordsTotal - words > wordsTotal / 5 { reasons.append("\(wordsTotal - words) of \(wordsTotal) transcripts wrong (at most 1 in 5)") }
    if !reasons.isEmpty { print("FAIL: " + reasons.joined(separator: "; ")); exit(1) }
}

/// Sends one prompt through the real directory and dispatcher, as a voice command would.
func hear(_ files: [URL]) async throws {
    guard let (directory, dispatcher) = rig() else { return }
    await directory.refresh()
    let names = await directory.vocabulary()
    print("sessions: \(names.joined(separator: ", "))")
    let transcriber = ParakeetTranscriber()
    let parser = CommandParser(model: FoundationCommandModel())
    for url in files {
        let samples = try AudioConverter().resampleAudioFile(url)
        let t = ContinuousClock.now
        let (text, plain) = try await transcriber.transcribeBoth(samples, vocabulary: names)
        let c = await parser.parse(text, plain: plain, sessions: names)
        var line = "(not run: it would act on a session)"
        switch c {
        case .greet, .status, .unknown: line = await dispatcher.run(c).line ?? "(nothing said)"
        default: break
        }
        print("\(url.lastPathComponent): heard \"\(text)\"\(plain.map { " (plain: \"\($0)\")" } ?? "") -> \(c), \(ms(t)) ms")
        print("  says: \(line)")
    }
}

func send(target: String, prompt: String) async {
    guard let (_, dispatcher) = rig() else { return }
    let o = await dispatcher.run(.send(target: target, prompt: prompt))
    print(o.line ?? "(nothing said)")
    try? await Task.sleep(for: .seconds(9))   // time for the receipt check
}

/// The same, to the session with this id, by its spoken name.
func send(id: String, prompt: String) async {
    guard let (directory, dispatcher) = rig() else { return }
    await directory.refresh()
    guard let s = await directory.session(id) else { print("no session with id \(id)"); exit(1) }
    guard case .one(let found) = await directory.resolve(s.name), found.id == id else {
        print("the name \"\(s.name)\" does not pick out that session alone"); exit(1)
    }
    let o = await dispatcher.run(.send(target: s.name, prompt: prompt))
    print(o.line ?? "(nothing said)")
    try? await Task.sleep(for: .seconds(9))
}

func rig() -> (SessionDirectory, Dispatcher)? {
    guard let path = ClaudeCLI.locate() else { print("claude not found"); exit(1) }
    let runner = ClaudeCLI(path: path)
    let store = SessionStore()
    let directory = SessionDirectory(runner: runner, store: store, labeler: Labeler(model: nil))
    let dispatcher = Dispatcher(directory: directory, store: store, transport: CCSocketTransport(), runner: runner,
                                approvals: ApprovalBook(), say: { print("later: \($0)") }, receiptTimeout: .seconds(8))
    return (directory, dispatcher)
}
