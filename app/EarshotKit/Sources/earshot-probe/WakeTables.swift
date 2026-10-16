import EarshotKit
import Foundation

/// What a fire that passes does, counted apart on the negatives, since only one kind is dangerous.
enum WakeOutcome {
    /// The chime, and words of this segment go out as a command: the literal tier (a greeting,
    /// then the phrase written as such) with words after it. On a negative it is the dangerous
    /// kind: "Approve it." would approve a pending permission prompt.
    case dispatch
    /// The chime, and nothing of this segment is sent: it opens the command window, as "Hey
    /// Earshot" alone does (or, for a wake passed on the strict score alone whose transcript
    /// lacks the phrase, closes at once).
    case window
}

/// A look's text as wake-bench writes it.
enum Heard {
    /// Not run: the segment scored under the sweep floor, or the bench ran without this look.
    case skipped
    /// The recognizer could not tell ("(nil)") or ran past the confirm limit ("(timeout)").
    case noAnswer
    case words(String)

    init(_ cell: String?) {
        switch cell {
        case nil, "(skipped)"?: self = .skipped
        case "(nil)"?, "(timeout)"?: self = .noAnswer
        case let w?: self = .words(w)
        }
    }

    var words: String? { if case .words(let w) = self { return w } else { return nil } }
}

/// One look's confirm alone: its words by `rule`, and no answer only on the strict score, as in
/// the listener. With no words the confirm can't tell what the finish would send: counted as window.
func lookOutcome(_ heard: Heard, score: Float?, rule: (String) -> WakeOutcome?) -> WakeOutcome? {
    switch heard {
    case .skipped: return nil
    case .noAnswer: return (score ?? -.infinity) >= CtcWakeSpotter.unconfirmedThreshold ? .window : nil
    case .words(let w): return rule(w)
    }
}

/// The listener's confirm rule (Listener.wakeWords), with the head's own remainder as the
/// guess at what would be sent: a greeting and the phrase with words after it dispatches;
/// the phrase alone, "Earshot" alone first (bare) or a sound-alike opens the window.
func tierRule(_ words: String) -> WakeOutcome? {
    switch Listener.wakeWords(words) {
    case .literal(let rest)?: return rest.isEmpty ? .window : .dispatch
    case .bare?, .soundAlike?: return .window
    case nil: return nil
    }
}

/// The old rule, for comparison: any text stripWake takes the phrase off.
func stripWakeRule(_ words: String) -> WakeOutcome? {
    Listener.stripWake(words).map { $0.isEmpty ? .window : .dispatch }
}

/// End to end, as the listener runs a wake, with the bench's head texts standing in for the
/// finished command's transcripts (a stand-in: live, the finish hears the whole command, not
/// the head). Apple's confirm passes the wake (any tier, or with no answer the strict
/// score); then the finish rule (Listener.finishRemainder) takes Parakeet's head text as the
/// unboosted transcript (the confirm hears it with no names, so it is the plain one, and the
/// boosted one too) and Apple's as the second hearing. No Parakeet text is an empty
/// transcript, as a failed transcription is.
func endToEndOutcome(apple: Heard, parakeet: Heard, score: Float?) -> WakeOutcome? {
    let onWords: Bool
    switch apple {
    case .skipped: return nil
    case .noAnswer:
        guard (score ?? -.infinity) >= CtcWakeSpotter.unconfirmedThreshold else { return nil }
        onWords = false
    case .words(let w):
        guard Listener.confirmsWake(w) else { return nil }
        onWords = true
    }
    let heard = parakeet.words ?? ""
    let rest = Listener.finishRemainder(heard, plain: heard, second: apple.words, passedOnWords: onWords)
    return rest.map { $0.isEmpty ? .window : .dispatch } ?? .window
}

struct RescoreRow {
    let file: String, cls: String, condition: String, split: String
    let score: Float?
    /// The score of "earshot" alone (CtcWakeSpotter.barePhrase), nil in a TSV without the column.
    var bare: Float? = nil
    /// What each look heard, by look name ("apple", "parakeet"), as wake-bench writes it.
    let texts: [String: String]
    let ms: [String: Double]

    func heard(_ look: String) -> Heard { Heard(texts[look]) }
}

/// The wake tables wake-bench and wake-rescore print, over files of segments.
struct WakeTables {
    /// Per file, its segments (a file with none has one row with no score).
    let files: [[RescoreRow]]
    let libriHours: Double
    let splits: [String], conditions: [String]
    var rows: [RescoreRow] { files.flatMap { $0 } }
    /// Whether a segment fires at threshold `t`: its phrase score reaches it (bareSweep sweeps the bare score instead).
    var fires: (RescoreRow, Float) -> Bool = { r, t in (r.score ?? -.infinity) >= t }

    init(files: [[RescoreRow]], libriHours: Double) {
        self.files = files
        self.libriHours = libriHours
        func unique(_ v: [String]) -> [String] { var seen = Set<String>(); return v.filter { seen.insert($0).inserted } }
        let positives = files.compactMap(\.first).filter { $0.cls == "positive" }
        splits = unique(["tune", "holdout"] + positives.map(\.split)).filter { s in positives.contains { $0.split == s } }
        conditions = unique(positives.map(\.condition))
    }

    /// A segment's outcome at threshold `t`: nil when the spotter does not fire or the wake does not pass.
    private func at(_ r: RescoreRow, _ t: Float, _ outcome: (RescoreRow) -> WakeOutcome?) -> WakeOutcome? {
        guard fires(r, t) else { return nil }
        return outcome(r)
    }

    /// Files picked, and of them those that chime at all, that dispatch, and that only open the window.
    private func count(_ t: Float, _ outcome: (RescoreRow) -> WakeOutcome?, _ pick: (RescoreRow) -> Bool)
        -> (all: Int, woken: Int, dispatch: Int, window: Int) {
        let picked = files.filter { $0.first.map(pick) ?? false }
        var woken = 0, dispatch = 0
        for f in picked {
            let o = f.compactMap { at($0, t, outcome) }
            if !o.isEmpty { woken += 1 }
            if o.contains(.dispatch) { dispatch += 1 }
        }
        return (picked.count, woken, dispatch, woken - dispatch)
    }

    /// One table: per threshold, positives woken by split and condition, then per class and split
    /// the negatives' false wakes of each kind (dispatch, window), LibriSpeech fires and false
    /// wakes of each kind an hour, and the confirm's p50 and p95 over the fires (`msLooks` run
    /// side by side, so the slower). `knowsDispatch` false (the spotter alone): every fire is
    /// counted under window, and dispatch is "-".
    func table(_ title: String, thresholds: [Float], knowsDispatch: Bool = true, msLooks: [String],
               _ outcome: (RescoreRow) -> WakeOutcome?) {
        print("\n== \(title) ==")
        let negatives = ["nearmiss", "mention"]
        var header = ["threshold"] + splits.map { "pos \($0)" } + conditions.map { "pos \($0)" }
        for c in negatives { for s in splits { header += ["\(c) \(s) dispatch", "\(c) \(s) window"] } }
        header += ["libri spotter fires/h", "libri dispatch/h", "libri window/h", "confirm p50 ms", "confirm p95 ms"]
        print(header.joined(separator: "\t"))
        let libri = rows.filter { $0.cls == "librispeech" }
        func perHour(_ n: Int) -> String { libriHours > 0 ? String(format: "%.2f", Double(n) / libriHours) : "-" }
        for t in thresholds {
            var cols = [String(format: "%.2f", t)]
            for s in splits { let n = count(t, outcome) { $0.cls == "positive" && $0.split == s }; cols.append("\(n.woken)/\(n.all)") }
            for c in conditions { let n = count(t, outcome) { $0.cls == "positive" && $0.condition == c }; cols.append("\(n.woken)/\(n.all)") }
            for c in negatives {
                for s in splits {
                    let n = count(t, outcome) { $0.cls == c && $0.split == s }
                    cols += [knowsDispatch ? "\(n.dispatch)/\(n.all)" : "-", "\(knowsDispatch ? n.window : n.woken)/\(n.all)"]
                }
            }
            let fired = libri.filter { fires($0, t) }
            let o = libri.compactMap { at($0, t, outcome) }
            cols.append(perHour(fired.count))
            cols.append(knowsDispatch ? perHour(o.filter { $0 == .dispatch }.count) : "-")
            cols.append(perHour(knowsDispatch ? o.filter { $0 == .window }.count : o.count))
            let ms = rows.filter { fires($0, t) }.compactMap { r in msLooks.compactMap { r.ms[$0] }.max() }.sorted()
            cols.append(percentile(ms, 0.5).map { String(format: "%.1f", $0) } ?? "-")
            cols.append(percentile(ms, 0.95).map { String(format: "%.1f", $0) } ?? "-")
            print(cols.joined(separator: "\t"))
        }
    }

    /// Positives woken at `t`, split x condition.
    func positives(at t: Float, label: String, _ outcome: (RescoreRow) -> WakeOutcome?) {
        print("positives woken at \(t)\(label), split x condition:")
        print((["split"] + conditions).joined(separator: "\t"))
        for s in splits {
            let cols = conditions.map { c in
                let n = count(t, outcome) { $0.cls == "positive" && $0.split == s && $0.condition == c }
                return "\(n.woken)/\(n.all)"
            }
            print(([s] + cols).joined(separator: "\t"))
        }
    }

    /// Every near-miss, mention and LibriSpeech segment that wakes at `t`, its kind, and what each look heard.
    func listFalse(at t: Float, looks: [String], _ outcome: (RescoreRow) -> WakeOutcome?) {
        for r in rows where ["nearmiss", "mention", "librispeech"].contains(r.cls) {
            guard let o = at(r, t, outcome) else { continue }
            let heard = looks.map { "\($0): \(r.texts[$0] ?? "-")" }.joined(separator: " | ")
            let bare = r.bare.map { "\tbare \(scoreText($0))" } ?? ""
            print("false wake\t\(o == .dispatch ? "dispatch" : "window")\t\(r.cls)\t\(r.split)\t\(r.file)\t\(scoreText(r.score))\(bare)\t\(heard)")
        }
    }
}

// MARK: - The bare term (an experiment)

/// A second spotter term, "earshot" alone (CtcWakeSpotter.barePhrase), for a wake whose
/// "Hey" a noise gate cut. A segment fires when the phrase scores at least `phraseAt` (the
/// shipped wake, `main`) or, failing that, the bare term scores at least the swept threshold.
/// A bare fire passes only when `look`'s words pass the confirm (Listener.confirmsWake, any
/// tier; no answer never passes it) and is window only, whatever the words: it chimes and
/// opens the command window and sends nothing of the segment, so it never dispatches.
func bareOutcome(_ r: RescoreRow, phraseAt t: Float, look: String, main: (RescoreRow) -> WakeOutcome?) -> WakeOutcome? {
    if (r.score ?? -.infinity) >= t { return main(r) }
    guard let w = r.heard(look).words, Listener.confirmsWake(w) else { return nil }
    return .window
}

extension WakeTables {
    /// Whether any row has a bare score (a TSV from before the column has none).
    var hasBare: Bool { rows.contains { $0.bare != nil } }

    /// The wake table with the phrase held at `t` and the bare term's threshold swept
    /// (bareOutcome), then positives by split and condition at each of `detail`, and with
    /// `list` the near-misses, mentions and LibriSpeech segments woken at the first of them.
    /// The first row of the sweep, a bare threshold no segment reaches, is the shipped wake.
    func bareSweep(phraseAt t: Float, thresholds: [Float], detail: [Float], look: String,
                   list: Bool = false, main: @escaping (RescoreRow) -> WakeOutcome?) {
        var sweep = self
        sweep.fires = { r, b in (r.score ?? -.infinity) >= t || (r.bare ?? -.infinity) >= b }
        let outcome = { (r: RescoreRow) in bareOutcome(r, phraseAt: t, look: look, main: main) }
        sweep.table("bare term \"\(CtcWakeSpotter.barePhrase)\" (window only), phrase at \(t), second look: \(look); "
                    + "the threshold column is the bare term's (inf: the shipped wake)",
                    thresholds: [.infinity] + thresholds, msLooks: [look], outcome)
        for b in detail { sweep.positives(at: b, label: " (bare term; phrase at \(t))", outcome) }
        if list, let b = detail.first { sweep.listFalse(at: b, looks: [look], outcome) }
    }
}
