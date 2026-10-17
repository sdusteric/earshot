import KobiKit
@preconcurrency import FluidAudio
import Foundation

/// wake-bench MANIFEST... [--out OUT.tsv] [--confirmers ctc,apple,parakeet] [--limit N]
///
/// The wake word as the listener runs it, on files, with the second look (the
/// confirmers) beside the spotter so a threshold and a confirmer can be chosen from data.
///   MANIFEST: one or more, tab separated, # lines and a header line skipped; each file path is
///             relative to the folder of the manifest it is in:
///             file, label (1 wake, 0 not), class (positive, nearmiss, mention, collision, librispeech),
///             voice, condition, split (tune, holdout, neg), text
///   --out OUT.tsv: one row per speech segment: file, label, class, voice, condition, split, seg,
///             score (CtcWakeSpotter.phrase, "hey kobi"), other (CtcWakeSpotter.otherPhrase, "hey
///             kobe"), bare (CtcWakeSpotter.barePhrase, "kobi" alone), all on the same pass, then for
///             each confirmer its text ("(nil)" when it could not tell, "(timeout)" past the
///             listener's confirm limit, "(skipped)" when all scores are below their sweep floors so
///             no threshold fires on it), whether the wake passes it (yes/no, as the listener passes
///             it: the text by Listener.confirmsWake, and nil or a timeout only when the listener's
///             score, CtcWakeSpotter.score, reaches CtcWakeSpotter.unconfirmedThreshold) and its ms.
///             With apple and parakeet both run, then the finish's hearings of the whole segment,
///             as the listener's finish hears a wake's clip (from the segment's start to its end,
///             with no session names): full_parakeet_text (Parakeet, "" when it heard nothing),
///             full_parakeet_ms, full_apple_text (Apple's second hearing, "(nil)" when it heard
///             nothing) and full_apple_ms, both run at once as in the listener. "(toolong)" when
///             the segment runs past the length cap (the listener drops it as too long), and
///             "(skipped)" when the looks were not run. Last, the manifest's text.
///             A file with no speech segment has one row with seg -1 and no score.
///             A name ending in manifest.tsv is refused, so a manifest is never overwritten.
///   --confirmers: which second looks to run (default all three); each runs on every segment's
///             window whose phrase or other score reaches the sweep floor, or whose bare score
///             reaches its own floor, so the sweep can cut at any threshold with any of them.
///             Each look is held to Listener.Timing().confirmLimit, as the listener holds it.
///             Parakeet is kept loaded the whole run: its column is the best case, since live it
///             is loaded only after a command, and when it is not a confirm has no answer and the
///             wake passes only on the strict score.
///   --limit N: only the first N files of each manifest.
/// Segments are cut as Listener.process cuts them: the energy gate, the real SileroGate on 4096-sample
/// chunks, a segment starts one chunk before the VAD's start, and it is spotted once, when it
/// is `spotAtSamples` long or ends sooner, on its first `spotWindowSamples`.
/// The report is wake-rescore's tables (WakeTables), per look and, with apple and parakeet both
/// run, end to end: false wakes in three kinds, dispatch (a greeting and the phrase standing
/// apart with words after it, which would go out as a command), carry (the phrase alone: the
/// command window opens, and speech begun during the confirm is the command) and window (a
/// chime that only opens the command window to speech after it). The end to end block decides
/// as the listener's finish does, on the whole segment's hearings (see endToEndOutcome). With apple run,
/// the report ends with the bare term's sweep (WakeTables.bareSweep, an experiment the
/// listener does not ship).
let wakeBenchUsage = "usage: kobi-probe wake-bench MANIFEST... [--out OUT.tsv] [--confirmers ctc,apple,parakeet] [--limit N]"

/// No threshold in the report's sweep is below this, so a segment that scores under it is
/// not run through the confirmers: nothing would fire on it.
let sweepFloor: Float = -9.5

/// The same for the bare score ("kobi" alone): a segment under all floors is not looked at.
let bareSweepFloor: Float = -9.5

func wakeBench(_ args: [String]) async throws {
    var manifestPaths: [String] = []
    var outPath: String?
    var confirmerNames = ["ctc", "apple", "parakeet"]
    var limit = Int.max
    var bad = false
    var i = 0
    while i < args.count {
        switch args[i] {
        case "--out" where i + 1 < args.count:
            outPath = args[i + 1]
            i += 1
        case "--confirmers" where i + 1 < args.count:
            confirmerNames = args[i + 1].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            i += 1
        case "--limit" where i + 1 < args.count:
            limit = Int(args[i + 1]) ?? Int.max
            i += 1
        case let flag where flag.hasPrefix("--"): bad = true
        default: manifestPaths.append(args[i])
        }
        i += 1
    }
    guard !bad, !manifestPaths.isEmpty, confirmerNames.allSatisfy({ ["ctc", "apple", "parakeet"].contains($0) }) else {
        print(wakeBenchUsage)
        exit(2)
    }
    if let outPath {
        let out = URL(fileURLWithPath: outPath)
        let manifests = Set(manifestPaths.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
        if out.lastPathComponent.hasSuffix("manifest.tsv") || manifests.contains(out.standardizedFileURL.path) {
            print("refusing to write \(outPath): --out must not be a manifest (a name ending in manifest.tsv)")
            exit(2)
        }
    }
    var files: [BenchFile] = []
    for path in manifestPaths { files += try BenchFile.read(URL(fileURLWithPath: path)).prefix(limit) }

    let timing = Listener.Timing()
    let spotter = CtcWakeSpotter()
    try await spotter.load()
    let gate = SileroGate()
    try await gate.load()

    var confirmers: [(name: String, confirmer: any WakeConfirmer)] = []
    let appleTranscriber = AppleTranscriber()
    let parakeet = ParakeetTranscriber()
    for name in confirmerNames {
        switch name {
        case "ctc": confirmers.append((name, CtcHeadConfirmer()))
        case "apple":
            let c = AppleHeadConfirmer(appleTranscriber)
            await c.prepare()
            confirmers.append((name, c))
            print("apple ready: \(await appleTranscriber.isReady)")
        default:
            await parakeet.prewarm()
            confirmers.append((name, ParakeetHeadConfirmer(parakeet)))
            print("parakeet loaded: \(await parakeet.isLoaded)")
        }
    }
    print("\(files.count) files from \(manifestPaths.count) manifest(s), confirm limit \(timing.confirmLimit), floor \(sweepFloor), spot at \(timing.spotAtSamples) samples on a window of \(timing.spotWindowSamples), confirmers: \(confirmerNames.joined(separator: ","))")

    var rows: [[BenchRow]] = []     // per file
    var seconds: [String: Double] = [:]   // per class, audio length
    var skipped = 0
    // The finish's hearings of the whole segment, as the listener's: Parakeet, and Apple as the second hearing.
    let hearsFull = confirmerNames.contains("apple") && confirmerNames.contains("parakeet")
    var out = "file\tlabel\tclass\tvoice\tcondition\tsplit\tseg\tscore\tother\tbare"
    for c in confirmers { out += "\t\(c.name)_text\t\(c.name)_pass\t\(c.name)_ms" }
    if hearsFull { out += "\tfull_parakeet_text\tfull_parakeet_ms\tfull_apple_text\tfull_apple_ms" }
    out += "\ttext\n"
    for (n, f) in files.enumerated() {
        let audio: [Float]
        do { audio = try AudioConverter().resampleAudioFile(f.url) } catch {
            print("skipped \(f.file): \(error.localizedDescription)")
            skipped += 1
            rows.append([])
            continue
        }
        seconds[f.cls, default: 0] += Double(audio.count) / 16_000
        var fileRows: [BenchRow] = []
        // Parakeet's idle timer is not touched by a confirm, so the bench renews it: the column is the best case.
        if confirmerNames.contains("parakeet") { await parakeet.prewarm() }
        let segments = await speechSegments(audio, gate: gate, timing: timing)
        for (seg, segment) in segments.enumerated() {
            let window = segment.window
            let scores = await spotter.wakeScores(window)
            var looks: [Look] = []
            for c in confirmers {
                // Under all floors no threshold fires: not a fire, so not looked at.
                guard let scores, max(scores.phrase, scores.other) >= sweepFloor || scores.bare >= bareSweepFloor else {
                    looks.append(.notRun); continue
                }
                let score = CtcWakeSpotter.score(scores)
                let t0 = ContinuousClock.now
                let answer = await benchBounded(timing.confirmLimit, String??.none) { .some(await c.confirmer.headText(window)) }
                let d = ContinuousClock.now - t0
                let elapsed = Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
                // As the listener passes it: the words by confirmsWake; no answer, or one past the
                // limit, only on the strict score.
                let strict = score >= CtcWakeSpotter.unconfirmedThreshold
                guard let answer else { looks.append(Look(text: nil, passes: strict, ms: elapsed, ran: true, timedOut: true)); continue }
                looks.append(Look(text: answer, passes: answer.map(Listener.confirmsWake) ?? strict, ms: elapsed, ran: true, timedOut: false))
            }
            var full: FullHearing?
            if hearsFull, looks.contains(where: \.ran) {
                full = await hearWhole(segment, parakeet: parakeet, apple: appleTranscriber, timing: timing)
            }
            fileRows.append(BenchRow(seg: seg, scores: scores, looks: looks, full: full))
        }
        rows.append(fileRows)
        for r in fileRows { out += f.tsv(seg: r.seg, scores: r.scores, looks: r.looks, full: hearsFull ? r.full ?? .notRun : nil) }
        if fileRows.isEmpty {
            out += f.tsv(seg: -1, scores: nil, looks: confirmers.map { _ in Look.notRun }, full: hearsFull ? .notRun : nil)
        }
        if (n + 1) % 100 == 0 { print("  \(n + 1)/\(files.count)") }
    }
    if let outPath {
        try out.write(to: URL(fileURLWithPath: outPath), atomically: true, encoding: .utf8)
        print("wrote \(outPath)")
    }
    if skipped > 0 { print("\(skipped) files could not be read") }
    report(Array(files), rows, confirmers.map(\.name), seconds: seconds)
}

// MARK: - Manifest

struct BenchFile {
    let file: String, label: Int, cls: String, voice: String, condition: String, split: String, text: String
    let url: URL

    static func read(_ manifest: URL) throws -> [BenchFile] {
        let base = manifest.deletingLastPathComponent()
        var out: [BenchFile] = []
        for line in try String(contentsOf: manifest, encoding: .utf8).split(separator: "\n") where !line.hasPrefix("#") {
            let p = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard p.count >= 6, p[0] != "file", let label = Int(p[1]) else { continue }
            out.append(BenchFile(file: p[0], label: label, cls: p[2], voice: p[3], condition: p[4], split: p[5],
                                 text: p.count > 6 ? p[6] : "",
                                 url: p[0].hasPrefix("/") ? URL(fileURLWithPath: p[0]) : base.appending(path: p[0])))
        }
        return out
    }

    func tsv(seg: Int, scores: CtcWakeSpotter.WakeScores?, looks: [Look], full: FullHearing?) -> String {
        var s = "\(file)\t\(label)\t\(cls)\t\(voice)\t\(condition)\t\(split)\t\(seg)\t"
            + "\(scoreText(scores?.phrase))\t\(scoreText(scores?.other))\t\(scoreText(scores?.bare))"
        for l in looks { s += "\t\(l.cell)\t\(l.passes ? "yes" : "no")\t\(String(format: "%.1f", l.ms))" }
        if let full {
            s += "\t\(tsvCell(full.parakeet))\t\(String(format: "%.1f", full.parakeetMs))"
                + "\t\(tsvCell(full.apple))\t\(String(format: "%.1f", full.appleMs))"
        }
        return s + "\t\(tsvCell(text))\n"
    }
}

func scoreText(_ s: Float?) -> String {
    guard let s else { return "nil" }
    return s.isFinite ? String(format: "%.3f", s) : (s < 0 ? "-inf" : "inf")
}

/// A text as a TSV cell: tabs and line breaks as spaces.
func tsvCell(_ text: String) -> String {
    text.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ")
}

/// The finish's hearings of a whole segment, as the TSV writes them (see wake-bench's --out).
struct FullHearing {
    let parakeet: String, parakeetMs: Double
    let apple: String, appleMs: Double

    static let notRun = FullHearing(parakeet: "(skipped)", parakeetMs: 0, apple: "(skipped)", appleMs: 0)
    static let tooLong = FullHearing(parakeet: "(toolong)", parakeetMs: 0, apple: "(toolong)", appleMs: 0)
}

/// The whole segment heard as the listener's finish hears a wake's clip: Parakeet and Apple's
/// second hearing at once, with no session names. A segment past the length cap is dropped as
/// too long, and one shorter than Timing.minClipSamples is not transcribed (an empty transcript).
func hearWhole(_ segment: SpeechSegment, parakeet: ParakeetTranscriber, apple: AppleTranscriber,
               timing: Listener.Timing) async -> FullHearing {
    guard let clip = segment.clip else { return .tooLong }
    guard clip.count >= timing.minClipSamples else { return FullHearing(parakeet: "", parakeetMs: 0, apple: "(nil)", appleMs: 0) }
    func ms(_ d: Duration) -> Double { Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15 }
    let t0 = ContinuousClock.now
    async let second: (String?, Double) = { (await apple.hear(clip, names: []), ms(ContinuousClock.now - t0)) }()
    let text = (try? await parakeet.transcribeBoth(clip, vocabulary: []).text) ?? ""
    let parakeetMs = ms(ContinuousClock.now - t0)
    let (heard, appleMs) = await second
    return FullHearing(parakeet: text, parakeetMs: parakeetMs, apple: heard ?? "(nil)", appleMs: appleMs)
}

struct Look {
    let text: String?
    let passes: Bool
    let ms: Double
    /// False when the segment scored under the sweep floor and the confirmer was not run.
    let ran: Bool
    /// True when the look took longer than the listener's confirm limit (no answer, as there).
    let timedOut: Bool

    static let notRun = Look(text: nil, passes: false, ms: 0, ran: false, timedOut: false)

    /// The text column as the TSV has it, which wake-rescore reads back (see Heard).
    var cell: String {
        !ran ? "(skipped)" : timedOut ? "(timeout)"
            : text.map(tsvCell) ?? "(nil)"
    }
}

private final class BenchOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    func claim() -> Bool { lock.lock(); defer { lock.unlock() }; if claimed { return false }; claimed = true; return true }
}

/// The operation's result, or `fallback` when it takes longer than `limit`: the listener's
/// `bounded`, which the library does not export.
func benchBounded<T: Sendable>(_ limit: Duration, _ fallback: T,
                               _ operation: @escaping @Sendable () async -> T) async -> T {
    let once = BenchOnce()
    return await withCheckedContinuation { (cont: CheckedContinuation<T, Never>) in
        Task {
            let result = await operation()
            if once.claim() { cont.resume(returning: result) }
        }
        Task {
            try? await Task.sleep(for: limit)
            if once.claim() { cont.resume(returning: fallback) }
        }
    }
}

struct BenchRow {
    let seg: Int
    /// The spotter's scores on the window: "hey kobi", "hey kobe" and "kobi" alone.
    let scores: CtcWakeSpotter.WakeScores?
    let looks: [Look]
    /// The finish's hearings of the whole segment, when the looks ran (apple and parakeet both run).
    var full: FullHearing?
}

// MARK: - Segments

/// A speech segment as the listener cuts it: the window it spots on, and the clip a wake's finish
/// hears, from the segment's start to the VAD's end. Nil when the segment is as long as the length
/// cap (Timing.maxCommandSamples) or longer: the listener drops a wake's capture that long as too
/// long, and hears only its head. The segments are cut the same either way, since only a wake's
/// capture is capped.
struct SpeechSegment {
    let window: [Float]
    let clip: [Float]?
}

/// The segments the listener would spot in this audio. The audio is followed by two seconds of
/// silence, as a mic would go on sending, so the VAD ends the last segment.
func speechSegments(_ audio: [Float], gate: SileroGate, timing: Listener.Timing) async -> [SpeechSegment] {
    await gate.reset()
    var energy = EnergyGate()
    var chunker = Chunker()
    let all = audio + [Float](repeating: 0, count: 32_000)
    var segments: [SpeechSegment] = []
    var total = 0
    var segmentStart: Int?
    var spotted = false
    var window: [Float] = []

    func spot(at s: Int) {
        spotted = true
        window = Array(all[s..<min(s + timing.spotWindowSamples, total)])
    }
    func end(at s: Int) {
        if !spotted { spot(at: s) }
        segments.append(SpeechSegment(window: window, clip: total - s >= timing.maxCommandSamples ? nil : Array(all[s..<total])))
        segmentStart = nil
    }
    for chunk in chunker.push(all) {
        total += chunk.count
        guard energy.admit(chunk) || segmentStart != nil else { continue }
        let edge = await gate.feed(chunk)
        if edge == .start {
            // The VAD fires a little after speech starts: include the chunk before.
            segmentStart = max(0, total - 2 * chunk.count)
            spotted = false
        }
        guard let s = segmentStart else { continue }
        if !spotted, total - s >= timing.spotAtSamples || edge == .end { spot(at: s) }
        if edge == .end { end(at: s) }
    }
    // Audio ended inside a segment (the VAD saw no end): the listener would spot what there is.
    if let s = segmentStart { end(at: s) }
    return segments
}

// MARK: - Report

func percentile(_ sorted: [Double], _ p: Double) -> Double? {
    guard !sorted.isEmpty else { return nil }
    return sorted[max(0, Int((p * Double(sorted.count)).rounded(.up)) - 1)]
}

func report(_ files: [BenchFile], _ rows: [[BenchRow]], _ confirmers: [String], seconds: [String: Double]) {
    let thresholds = Array(stride(from: -3.0, through: Double(sweepFloor), by: -0.25)).map(Float.init)
    let libriHours = (seconds["librispeech"] ?? 0) / 3600
    // The same rows wake-rescore reads from the TSV, so both print the same tables.
    let grouped: [[RescoreRow]] = zip(files, rows).map { f, fileRows in
        func row(_ s: CtcWakeSpotter.WakeScores?, _ texts: [String: String], _ ms: [String: Double]) -> RescoreRow {
            RescoreRow(file: f.file, cls: f.cls, condition: f.condition, split: f.split, text: f.text,
                       score: s.map(CtcWakeSpotter.score), bare: s?.bare, texts: texts, ms: ms)
        }
        guard !fileRows.isEmpty else { return [row(nil, [:], [:])] }
        return fileRows.map { r in
            var texts = Dictionary(uniqueKeysWithValues: zip(confirmers, r.looks.map(\.cell)))
            var ms = Dictionary(uniqueKeysWithValues: zip(confirmers, r.looks.map(\.ms)))
            if let full = r.full {
                (texts["full_parakeet"], texts["full_apple"]) = (tsvCell(full.parakeet), tsvCell(full.apple))
                (ms["full_parakeet"], ms["full_apple"]) = (full.parakeetMs, full.appleMs)
            }
            return row(r.scores, texts, ms)
        }
    }
    let tables = WakeTables(files: grouped, libriHours: libriHours)
    print("\n\(files.count) files, \(tables.rows.filter { $0.score != nil }.count) segments, LibriSpeech \(String(format: "%.2f", libriHours)) h of audio")
    print("false wakes in three kinds: dispatch (a greeting and the phrase standing apart with words after it: they would go out as a command), "
          + "carry (the phrase alone: the command window opens, and speech begun during the confirm is the command) "
          + "and window (a chime that sends nothing of the segment and only opens the command window to speech after it)")

    let parakeetIndex = confirmers.firstIndex(of: "parakeet")
    func byLook(_ title: String, msLooks: [String], knowsDispatch: Bool = true, _ outcome: (RescoreRow) -> WakeOutcome?) {
        tables.table(title, thresholds: thresholds, knowsDispatch: knowsDispatch, msLooks: msLooks, outcome)
        // Positives woken by split and condition, at the thresholds of sensitivity 1, 5 and 10.
        for sensitivity in [1, 5, 10] {
            tables.positives(at: CtcWakeSpotter.threshold(sensitivity), label: " (sensitivity \(sensitivity))", outcome)
        }
    }
    byLook("second look: none (the spotter alone: every fire chimes, and what it sends is not known)", msLooks: [],
           knowsDispatch: false) { _ in .window }
    for (l, name) in confirmers.enumerated() {
        let all = rows.flatMap { $0 }.filter { $0.looks[l].ran }
        let timeouts = all.filter { $0.looks[l].timedOut }.count
        let nils = all.filter { $0.looks[l].text == nil && !$0.looks[l].timedOut }.count
        let ms = all.map { $0.looks[l].ms }.sorted()
        let best = l == parakeetIndex ? " (best case: always loaded; live it is loaded only after a command, and then a confirm passes)" : ""
        print("\n\(name): ran on \(all.count) segments scoring at least \(sweepFloor) (or bare \(bareSweepFloor)); no answer on \(nils), timed out on \(timeouts) (these pass only at \(CtcWakeSpotter.unconfirmedThreshold)); ms over those: p50 \(ms.isEmpty ? "-" : String(format: "%.1f", percentile(ms, 0.5)!)), p95 \(ms.isEmpty ? "-" : String(format: "%.1f", percentile(ms, 0.95)!))")
        byLook("second look: \(name)\(best), the listener's rule (both tiers)", msLooks: [name]) { r in
            lookOutcome(r.heard(name), score: r.score, rule: tierRule)
        }
    }
    if confirmers.contains("apple"), tables.hasBare {
        tables.bareSweep(phraseAt: CtcWakeSpotter.threshold(5), thresholds: bareThresholds, detail: [], look: "apple") {
            lookOutcome($0.heard("apple"), score: $0.score, rule: tierRule)
        }
    }
    if confirmers.contains("apple"), confirmers.contains("parakeet") {
        byLook("end to end: apple's confirm, then the finish rule on the whole segment's hearings, parakeet's as the "
               + "unboosted transcript and apple's as the second hearing", msLooks: ["apple"], endToEndOutcome)
    }
}
