import KobiKit
import Foundation

/// What a fire that passes does, counted apart on the negatives, since only one kind is dangerous.
/// Ordered: a file's outcome is the worst of its segments'.
enum WakeOutcome: Int, Comparable {
    /// The chime, and nothing of this segment is sent: it opens the command window to speech
    /// that starts after the chime ("Kobi" alone first), or, for a wake passed on the strict
    /// score alone whose transcript lacks the phrase, closes at once.
    case window
    /// The phrase alone ("Hey Kobi."): the chime, and the command window opens with carry-over,
    /// so speech begun while the wake was being confirmed is the command. Nothing of this
    /// segment is sent, but the next thing said in the same breath may be.
    case carry
    /// The chime, and words of this segment go out as a command: the literal tier (a greeting,
    /// then the phrase standing apart) with words after it. On a negative it is the dangerous
    /// kind: "Keep going." would go to the last session.
    case dispatch

    static func < (a: WakeOutcome, b: WakeOutcome) -> Bool { a.rawValue < b.rawValue }
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
/// the phrase alone carries over, and "Kobi" alone first (bare) opens the window.
func tierRule(_ words: String) -> WakeOutcome? {
    switch Listener.wakeWords(words) {
    case .literal(let rest)?: return rest.isEmpty ? .carry : .dispatch
    case .bare?: return .window
    case nil: return nil
    }
}

/// The old rule, for comparison: any text stripWake takes the phrase off.
func stripWakeRule(_ words: String) -> WakeOutcome? {
    Listener.stripWake(words).map { $0.isEmpty ? .carry : .dispatch }
}

/// End to end, as the listener runs a wake. Apple's confirm on the head passes the wake (any
/// tier, or with no answer the strict score); then the finish rule (Listener.finishRemainder)
/// on the whole segment's hearings (wake-bench's full columns): Parakeet's is the unboosted
/// transcript (the bench hears it with no names, so it is the boosted one too) and Apple's the
/// second hearing, kept only when it came within Timing.secondGrace of Parakeet's and Parakeet
/// heard something or the wake passed on words, as in the listener. A segment past the length
/// cap sends nothing (too long). A TSV from before the full columns has only the heads: then
/// Parakeet's and Apple's head texts stand in for the whole segment's.
/// The outcome: words after a greeting and the phrase dispatch, the phrase alone carries over,
/// and anything else that passed the confirm only opens the window (or closes at once).
func endToEndOutcome(_ r: RescoreRow) -> WakeOutcome? {
    let onWords: Bool
    switch r.heard("apple") {
    case .skipped: return nil
    case .noAnswer:
        guard (r.score ?? -.infinity) >= CtcWakeSpotter.unconfirmedThreshold else { return nil }
        onWords = false
    case .words(let w):
        guard Listener.confirmsWake(w) else { return nil }
        onWords = true
    }
    let text: String, second: String?
    if let full = r.texts["full_parakeet"] {
        if full == "(toolong)" { return .window }
        text = Heard(full).words ?? ""
        let g = Listener.Timing().secondGrace.components
        let grace = Double(g.seconds) * 1000 + Double(g.attoseconds) / 1e15
        let inTime = (r.ms["full_apple"] ?? .infinity) <= (r.ms["full_parakeet"] ?? 0) + grace
        second = inTime && (!text.isEmpty || onWords) ? r.heard("full_apple").words : nil
    } else {
        text = r.heard("parakeet").words ?? ""
        second = r.heard("apple").words
    }
    let rest = Listener.finishRemainder(text, plain: text, second: second, passedOnWords: onWords)
    return rest.map { $0.isEmpty ? .carry : .dispatch } ?? .window
}

struct RescoreRow {
    let file: String, cls: String, condition: String, split: String
    /// The manifest's text: what the clip says ("" in a TSV without the column).
    var text = ""
    let score: Float?
    /// The score of "kobi" alone (CtcWakeSpotter.barePhrase), nil in a TSV without the column.
    var bare: Float? = nil
    /// What each look heard, by look name ("apple", "parakeet", and the whole segment's
    /// "full_parakeet" and "full_apple"), as wake-bench writes it.
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

    /// Files picked, and of them those that chime at all, then by the worst of their segments'
    /// outcomes: those that dispatch, that carry over and that only open the window.
    func count(_ t: Float, _ outcome: (RescoreRow) -> WakeOutcome?, _ pick: (RescoreRow) -> Bool)
        -> (all: Int, woken: Int, dispatch: Int, carry: Int, window: Int) {
        let picked = files.filter { $0.first.map(pick) ?? false }
        var n: [WakeOutcome: Int] = [:]
        for f in picked {
            if let worst = f.compactMap({ at($0, t, outcome) }).max() { n[worst, default: 0] += 1 }
        }
        let (d, c, w) = (n[.dispatch] ?? 0, n[.carry] ?? 0, n[.window] ?? 0)
        return (picked.count, d + c + w, d, c, w)
    }

    /// One table: per threshold, positives woken by split and condition, then per class and split
    /// the negatives' false wakes of each kind (dispatch, carry, window), the collisions' wakes of each
    /// kind (expected: "Hey Kobe" sounds the same as "Hey Kobi"), LibriSpeech fires and false
    /// wakes of each kind an hour, and the confirm's p50 and p95 over the fires (`msLooks` run
    /// side by side, so the slower). `knowsDispatch` false (the spotter alone): every fire is
    /// counted under window, and dispatch and carry are "-".
    func table(_ title: String, thresholds: [Float], knowsDispatch: Bool = true, msLooks: [String],
               _ outcome: (RescoreRow) -> WakeOutcome?) {
        print("\n== \(title) ==")
        let negatives = ["nearmiss", "mention", "collision"].filter { c in rows.contains { $0.cls == c } }
        var header = ["threshold"] + splits.map { "pos \($0)" } + conditions.map { "pos \($0)" }
        for c in negatives { for s in splits { header += ["\(c) \(s) dispatch", "\(c) \(s) carry", "\(c) \(s) window"] } }
        header += ["libri spotter fires/h", "libri dispatch/h", "libri carry/h", "libri window/h", "confirm p50 ms", "confirm p95 ms"]
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
                    cols += [knowsDispatch ? "\(n.dispatch)/\(n.all)" : "-", knowsDispatch ? "\(n.carry)/\(n.all)" : "-",
                             "\(knowsDispatch ? n.window : n.woken)/\(n.all)"]
                }
            }
            let fired = libri.filter { fires($0, t) }
            let o = libri.compactMap { at($0, t, outcome) }
            cols.append(perHour(fired.count))
            cols.append(knowsDispatch ? perHour(o.filter { $0 == .dispatch }.count) : "-")
            cols.append(knowsDispatch ? perHour(o.filter { $0 == .carry }.count) : "-")
            cols.append(perHour(knowsDispatch ? o.filter { $0 == .window }.count : o.count))
            let ms = rows.filter { fires($0, t) }.compactMap { r in msLooks.compactMap { r.ms[$0] }.max() }.sorted()
            cols.append(percentile(ms, 0.5).map { String(format: "%.1f", $0) } ?? "-")
            cols.append(percentile(ms, 0.95).map { String(format: "%.1f", $0) } ?? "-")
            print(cols.joined(separator: "\t"))
        }
    }

    /// Positives woken at `t`, split x condition, and of them in brackets those that dispatch: the
    /// words after the phrase go out in the same breath (the rest carry over or only open the
    /// command window).
    func positives(at t: Float, label: String, _ outcome: (RescoreRow) -> WakeOutcome?) {
        print("positives woken at \(t)\(label) (dispatching in the same breath), split x condition:")
        print((["split"] + conditions).joined(separator: "\t"))
        for s in splits {
            let cols = conditions.map { c in
                let n = count(t, outcome) { $0.cls == "positive" && $0.split == s && $0.condition == c }
                return "\(n.woken)/\(n.all) (\(n.dispatch))"
            }
            print(([s] + cols).joined(separator: "\t"))
        }
    }

    /// Every near-miss, mention, collision and LibriSpeech segment that wakes at `t`, its kind, and
    /// what each look heard (a collision is listed as "wake", since it is expected to wake).
    func listFalse(at t: Float, looks: [String], _ outcome: (RescoreRow) -> WakeOutcome?) {
        for r in rows where ["nearmiss", "mention", "collision", "librispeech"].contains(r.cls) {
            guard let o = at(r, t, outcome) else { continue }
            let heard = looks.map { "\($0): \(r.texts[$0] ?? "-")" }.joined(separator: " | ")
            let bare = r.bare.map { "\tbare \(scoreText($0))" } ?? ""
            print("\(r.cls == "collision" ? "wake" : "false wake")\t\(o)\t\(r.cls)\t\(r.split)\t\(r.file)\t\(scoreText(r.score))\(bare)\t\(heard)")
        }
    }

    /// Per near-miss, mention and collision phrase (the manifest's text) that wakes at `t`, and per
    /// split, its files and those that dispatch, carry over and open the window. Needs the text column.
    func byPhrase(at t: Float, _ outcome: (RescoreRow) -> WakeOutcome?) {
        let picked = files.compactMap(\.first).filter { ["nearmiss", "mention", "collision"].contains($0.cls) && !$0.text.isEmpty }
        guard !picked.isEmpty else { return }
        print("negatives and collisions woken at \(t), by phrase: class, phrase, then per split files, dispatch, carry, window")
        var seen = Set<String>()
        for p in picked where seen.insert("\(p.cls)\t\(p.text)").inserted {
            let n = splits.map { s in count(t, outcome) { $0.cls == p.cls && $0.text == p.text && $0.split == s } }
            guard n.contains(where: { $0.woken > 0 }) else { continue }
            let cols = zip(splits, n).map { s, n in "\(s) \(n.all) d\(n.dispatch) c\(n.carry) w\(n.window)" }
            print(([p.cls, p.text] + cols).joined(separator: "\t"))
        }
    }
}

// MARK: - The bare term (an experiment)

/// A second spotter term, "kobi" alone (CtcWakeSpotter.barePhrase), for a wake whose
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
