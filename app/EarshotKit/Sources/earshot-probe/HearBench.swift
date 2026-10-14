import EarshotKit
@preconcurrency import FluidAudio
import Foundation

/// hear-bench MANIFEST SESSIONS: recorded or synthesized commands through the
/// transcriber and the parser, scored against what was meant. Read-only.
///   MANIFEST: file, condition, expected, text (tab separated; # lines skipped).
///             Files are relative to the manifest, or absolute.
///   SESSIONS: one session name per line, as the directory would offer them.
/// Expected: send|T  status|T  stop|T  start|P  answer|allow|T  answer|deny|T  greet  quiet  repeat  unknown
/// Switches (environment):
///   BENCH_ASR=parakeet|apple|both|dual
///                                   both: Apple's transcriber when Parakeet's words make no command;
///                                   dual: both at once, Apple's words as the parser's `second`
///   BENCH_MODEL=0                   without Apple's language model fallback
///   BENCH_GATED=auto|on|off         tell the parser the mic's gate cut the start (auto: ClipLevel.gated)
/// Each clip goes through ParakeetTranscriber as in the app, so short clips are padded there.
///   BENCH_ONLY=SUBSTRING            only files whose name contains it
func hearBench(_ manifest: URL, sessionsFile: URL) async throws {
    let env = ProcessInfo.processInfo.environment
    let asrMode = env["BENCH_ASR"] ?? "parakeet"
    let useModel = env["BENCH_MODEL"] != "0"
    let only = env["BENCH_ONLY"]
    let names = try String(contentsOf: sessionsFile, encoding: .utf8).split(separator: "\n")
        .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("#") }
    let parakeet = ParakeetTranscriber()
    let apple = AppleSpeech()
    let parser = CommandParser(model: useModel ? FoundationCommandModel() : nil)
    await parakeet.prewarm()
    print("asr \(asrMode), model \(useModel ? "on" : "off"), \(names.count) sessions")

    struct Tally { var n = 0, right = 0, asks = 0, missed = 0, wrong = 0, unsafe = 0 }
    var tallies: [String: Tally] = [:]
    var order: [String] = []
    var latencies: [Int] = []
    let base = manifest.deletingLastPathComponent()
    for line in try String(contentsOf: manifest, encoding: .utf8).split(separator: "\n") where !line.hasPrefix("#") {
        let p = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard p.count >= 3 else { continue }
        if let only, !p[0].contains(only) { continue }
        let url = p[0].hasPrefix("/") ? URL(fileURLWithPath: p[0]) : base.appending(path: p[0])
        let samples = try AudioConverter().resampleAudioFile(url)
        let gatedMode = env["BENCH_GATED"] ?? "auto"
        let gated = gatedMode == "on" || (gatedMode == "auto" && ClipLevel.gated(samples))
        let t = ContinuousClock.now
        var heard = "", plainHeard: String?
        var c = Command.unknown
        if asrMode == "dual" {
            async let apples = apple.transcribe(samples, names: names)
            let (text, plain) = try await parakeet.transcribeBoth(samples, vocabulary: names)
            let second = (try? await apples) ?? ""
            heard = "\(text) | apple: \(second)"; plainHeard = plain
            c = await parser.parse(text, plain: plain, second: second, sessions: names, gated: gated)
        } else if asrMode != "apple" {
            let (text, plain) = try await parakeet.transcribeBoth(samples, vocabulary: names)
            heard = text; plainHeard = plain
            c = await parser.parse(text, plain: plain, sessions: names, gated: gated)
        }
        if asrMode == "apple" || (asrMode == "both" && c == .unknown) {
            let text = try await apple.transcribe(samples, names: names)
            let c2 = await parser.parse(text, sessions: names, gated: gated)
            if asrMode == "apple" || c2 != .unknown { heard = asrMode == "both" ? "\(heard) | apple: \(text)" : text; c = c2 }
        }
        let elapsed = ms(t)
        latencies.append(elapsed)
        let verdict = score(c, p[2], names: names)
        let cond = p[1]
        if tallies[cond] == nil { order.append(cond) }
        var tl = tallies[cond, default: Tally()]
        tl.n += 1
        switch verdict {
        case .right: tl.right += 1
        case .asks: tl.asks += 1
        case .missed: tl.missed += 1
        case .wrong: tl.wrong += 1
        case .unsafe: tl.wrong += 1; tl.unsafe += 1
        }
        tallies[cond] = tl
        if verdict != .right {
            let shown = plainHeard.map { "\(heard) (plain: \($0))" } ?? heard
            print("\(verdict)\t\(gated ? "gated" : "-")\t\(p[0])\twant \(p[2])\theard \"\(shown)\"\tgot \(c)\t\(elapsed) ms")
        }
    }
    print("\ncondition\tn\tright\tasks\tdidn't get it\twrong\tunsafe")
    var all = Tally()
    for cond in order {
        let tl = tallies[cond]!
        all.n += tl.n; all.right += tl.right; all.asks += tl.asks; all.missed += tl.missed; all.wrong += tl.wrong; all.unsafe += tl.unsafe
        print("\(cond)\t\(tl.n)\t\(tl.right)\t\(tl.asks)\t\(tl.missed)\t\(tl.wrong)\t\(tl.unsafe)")
    }
    print("all\t\(all.n)\t\(all.right)\t\(all.asks)\t\(all.missed)\t\(all.wrong)\t\(all.unsafe)")
    print(String(format: "understood (right or asks): %.0f%%", Double(all.right + all.asks) / Double(max(all.n, 1)) * 100))
    let sorted = latencies.sorted()
    if !sorted.isEmpty {
        print("latency ms: median \(sorted[sorted.count / 2]), p90 \(sorted[sorted.count * 9 / 10]), max \(sorted.last!)")
    }
}

enum Verdict: String, CustomStringConvertible {
    /// The command meant. `asks`: Earshot asks before doing the command meant.
    case right, asks, missed, wrong
    /// Wrong, and it would act on a session (send, stop, answer, start) without asking.
    case unsafe
    var description: String { rawValue.uppercased() }
}

func score(_ c: Command, _ want: String, names: [String]) -> Verdict {
    if case .confirmSend(let t, let prompt) = c {
        let v = score(.send(target: t, prompt: prompt), want, names: names)
        return v == .right ? .asks : (v == .unsafe ? .wrong : v)
    }
    if matchesExpected(c, want) { return .right }
    if c == .unknown { return .missed }
    // A target that is no session: Earshot says it doesn't know one by that name, and does nothing.
    func unknownName(_ t: String?) -> Bool {
        guard let t else { return false }
        return !names.contains { NameMatch.score(t, $0) >= 0.78 }
    }
    switch c {
    case .send(let t, _), .stop(let t, _), .answer(_, let t), .status(let t) where unknownName(t): return .missed
    case .start(let p, _) where unknownName(p): return .missed
    case .send, .stop, .stopAll, .start, .answer: return .unsafe
    default: return .wrong
    }
}

func matchesExpected(_ c: Command, _ want: String) -> Bool {
    switch (c, want) {
    case (.greet, "greet"), (.quiet, "quiet"), (.repeatLast, "repeat"): return true
    default: return matches(c, want)
    }
}

/// parse SESSIONS TEXT...: what the grammar and the tolerant reading make of each text, as if gated and not.
func parseText(sessionsFile: URL, _ texts: [String]) async {
    let names = ((try? String(contentsOf: sessionsFile, encoding: .utf8)) ?? "").split(separator: "\n")
        .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("#") }
    let parser = CommandParser(model: nil)
    for t in texts {
        let open = await parser.parse(t, sessions: names, gated: false)
        let gated = await parser.parse(t, sessions: names, gated: true)
        print("\(t)\t-> \(open)\t(gated: \(gated))")
        if ProcessInfo.processInfo.environment["BENCH_EXPLAIN"] != nil { print("  " + Tolerant.explain(t, gated: true)) }
    }
}
