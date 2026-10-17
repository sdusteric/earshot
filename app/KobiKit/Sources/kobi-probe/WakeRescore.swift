import KobiKit
import Foundation

/// wake-rescore TSV... [--threshold T] [--bare B] [--spotter phrase|other|max]
///
/// The per-segment output of wake-bench (--out) read again, with each look's pass worked out
/// anew from the text it heard, so a confirm rule can be tried without running the audio.
/// For the stripWake rule and the listener's rule (Listener.wakeWords, both tiers: dispatch and
/// window), and for
/// apple, parakeet and the two OR'd, it prints the wake table: positives woken by split and by
/// condition, then near-miss, mention and collision files that wake by split, LibriSpeech spotter
/// fires and false wakes per hour. False wakes are counted in two kinds: "dispatch", a
/// greeting and the phrase written as such with words after it, which would send them as a
/// command (the dangerous kind), and "window", a chime that sends nothing of the segment and
/// only opens the command window ("Kobi" alone first, or the phrase alone).
/// Collisions ("Hey Kobe", which sounds the same as "Hey Kobi") are counted the same way but
/// are not false wakes: they are expected to wake. In the confirm-only tables the head's own
/// words stand in for what the finish sends, and a look with no answer (passed on the strict
/// score) counts as window.
/// Then the same table end to end (endToEndOutcome): Apple's confirm, then the finish rule
/// with Parakeet's head text as the unboosted transcript and Apple's as the second
/// hearing, a stand-in for the finished command's transcripts.
/// A file is woken at T when any of its segments scores at least T and passes; it dispatches
/// when any of them dispatches. A look with no answer ("(nil)") or past the confirm limit
/// ("(timeout)") passes only when the segment scored CtcWakeSpotter.unconfirmedThreshold or
/// more, as in the listener.
///   --threshold T: only that row, then positives by split and condition at T, and the
///                  near-miss, mention and LibriSpeech segments that the listener's rule and
///                  the end to end rule wake at T, with their kind and what was heard.
///   --spotter S:   which score fires a segment: phrase ("hey kobi"), other ("hey kobe") or
///                  max (the higher of the two). Default: the listener's (CtcWakeSpotter.score).
/// With a bare column (the score of "kobi" alone) it ends with the bare term's sweep
/// (WakeTables.bareSweep): the phrase at T (default -8.0) with Apple's confirm and the
/// listener's rule, and "kobi" alone, window only, at each bare threshold.
///   --bare B:      then positives by split and condition at B, and every near-miss, mention
///                  and LibriSpeech segment woken at B.
let wakeRescoreUsage = "usage: kobi-probe wake-rescore TSV... [--threshold T] [--bare B] [--spotter phrase|other|max]"

/// LibriSpeech test-clean as the bench ran it (tests/wake/librispeech.sh): the TSV has no lengths.
let libriHours = 5.40

func wakeRescore(_ args: [String]) throws {
    var paths: [String] = []
    var only: Float?
    var bareAt: Float?
    var spotterMode: String?
    var bad = false
    var i = 0
    while i < args.count {
        switch args[i] {
        case "--threshold" where i + 1 < args.count:
            only = Float(args[i + 1])
            bad = bad || only == nil
            i += 1
        case "--spotter" where i + 1 < args.count && ["phrase", "other", "max"].contains(args[i + 1]):
            spotterMode = args[i + 1]
            i += 1
        case "--bare" where i + 1 < args.count:
            bareAt = Float(args[i + 1])
            bad = bad || bareAt == nil
            i += 1
        case let flag where flag.hasPrefix("--"): bad = true
        default: paths.append(args[i])
        }
        i += 1
    }
    guard !bad, !paths.isEmpty else {
        print(wakeRescoreUsage)
        exit(2)
    }
    let lookNames = ["apple", "parakeet"]
    var rows: [RescoreRow] = []
    for path in paths {
        var header: [String: Int] = [:]
        for line in try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n") {
            let p = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            if p.first == "file" {
                header = Dictionary(p.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
                continue
            }
            func col(_ name: String) -> String? { header[name].flatMap { $0 < p.count ? p[$0] : nil } }
            guard let file = col("file"), let cls = col("class") else { continue }
            var texts: [String: String] = [:], ms: [String: Double] = [:]
            for l in lookNames {
                if let t = col("\(l)_text") { texts[l] = t }
                if let m = col("\(l)_ms").flatMap(Double.init) { ms[l] = m }
            }
            func score(_ s: String?) -> Float? { s == nil || s == "nil" ? nil : s == "-inf" ? -.infinity : Float(s!) }
            // The score that fires: the phrase's, the other phrase's, or as the listener takes them.
            var fired = score(col("score"))
            if let p = fired, let o = score(col("other")) {
                switch spotterMode {
                case "phrase"?: fired = p
                case "other"?: fired = o
                case "max"?: fired = max(p, o)
                default: fired = CtcWakeSpotter.score(.init(phrase: p, other: o, bare: -.infinity))
                }
            }
            rows.append(RescoreRow(file: file, cls: cls, condition: col("condition") ?? "", split: col("split") ?? "",
                                   score: fired, bare: score(col("bare")), texts: texts, ms: ms))
        }
    }
    var byFile: [String: [RescoreRow]] = [:]
    var order: [String] = []
    for r in rows {
        if byFile[r.file] == nil { order.append(r.file) }
        byFile[r.file, default: []].append(r)
    }
    let tables = WakeTables(files: order.map { byFile[$0]! }, libriHours: libriHours)
    let thresholds: [Float] = only.map { [$0] } ?? [-5, -6, -7, -7.5, -8, -8.5, -9, -9.25]
    print("\(tables.files.count) files, \(rows.count) segments from \(paths.count) TSV(s), LibriSpeech taken as \(String(format: "%.2f", libriHours)) h, spotter score: \(spotterMode ?? "the listener's")")

    let rules: [(name: String, rule: (String) -> WakeOutcome?)] = [
        ("stripWake", stripWakeRule),
        ("wakeWords (both tiers)", tierRule),
    ]
    let looks: [[String]] = [["apple"], ["parakeet"], ["apple", "parakeet"]]
    for (n, rule) in rules.enumerated() {
        for look in looks {
            // The looks OR'd: the wake passes when any passes, and dispatches when any dispatches.
            let outcome = { (r: RescoreRow) -> WakeOutcome? in
                let o = look.compactMap { lookOutcome(r.heard($0), score: r.score, rule: rule.rule) }
                return o.contains(.dispatch) ? .dispatch : o.first
            }
            tables.table("\(rule.name), second look: \(look.joined(separator: "|"))", thresholds: thresholds,
                         msLooks: look, outcome)
            guard let t = only else { continue }
            tables.positives(at: t, label: "", outcome)
            if n == rules.count - 1 { tables.listFalse(at: t, looks: lookNames, outcome) }
        }
    }

    // End to end, as the listener runs a wake (endToEndOutcome). Needs the Parakeet column.
    if rows.contains(where: { $0.texts["parakeet"] != nil }) {
        let outcome = { (r: RescoreRow) in endToEndOutcome(apple: r.heard("apple"), parakeet: r.heard("parakeet"), score: r.score) }
        tables.table("end to end: apple's confirm, then the finish rule with parakeet's head text as the unboosted "
                     + "transcript and apple's as the second hearing (a stand-in for the finished command's)",
                     thresholds: thresholds, msLooks: ["apple"], outcome)
        if let t = only {
            tables.positives(at: t, label: "", outcome)
            tables.listFalse(at: t, looks: lookNames, outcome)
        }
    }

    if tables.hasBare {
        tables.bareSweep(phraseAt: only ?? -8.0, thresholds: bareThresholds, detail: bareAt.map { [$0] } ?? [], look: "apple",
                         list: bareAt != nil) { lookOutcome($0.heard("apple"), score: $0.score, rule: tierRule) }
    }
}

/// The bare term's thresholds the sweep prints.
let bareThresholds = Array(stride(from: -3.0, through: Double(bareSweepFloor), by: -0.25)).map(Float.init)
