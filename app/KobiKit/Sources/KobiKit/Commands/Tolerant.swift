import Foundation

/// Understands what the grammar missed because the words came through
/// garbled: a webcam's or headset's noise gate that opens a beat late eats
/// the first word or two, and a quiet mic turns "sessions" into "seconds".
/// Read-only commands (the roll call, a greeting, one session's status) are
/// taken from their content words and may lose their first words. A session
/// name may be found anywhere and by sound; a prompt sent on such a guess is
/// always asked about first (`confirmSend`). It never answers a permission
/// prompt and never stops anything.
public enum Tolerant {
    /// How alike two words are, each pair worked out once per command: the
    /// alignments below ask for the same pairs many times.
    final class Memo {
        private var sims: [String: Double] = [:]
        func sim(_ a: String, _ b: String) -> Double {
            let k = a + "|" + b
            if let v = sims[k] { return v }
            let v = SoundsLike.similarity(a, b)
            sims[k] = v
            return v
        }
    }

    /// `gated`: the mic sent exact zeros, then speech began at once, so its
    /// start was likely cut (see ClipLevel.gated). It allows a little more.
    public static func parse(_ text: String, known: [String], gated: Bool) -> Command? {
        let w = Grammar.Words(text).trimmingFillers()
        guard !w.isEmpty, w.count <= 14 else { return nil }
        let keys = w.keys.map(SoundsLike.letters)
        let memo = Memo()
        if let c = template(keys, gated: gated, memo) { return c }
        if keys.contains(where: { ["everyone", "everybody"].contains($0) }),
           !keys.contains(where: { ["tell", "ask", "stop", "send"].contains($0) }) {
            return .status(target: nil)
        }
        guard let spot = findName(keys, known: known, gated: gated) else { return nil }
        return withName(w, keys, spot, gated: gated, memo)
    }

    // MARK: - Whole commands

    /// The roll call and greetings, by the words they are said with.
    static let rollCall = [
        "how are all the other sessions going", "how are the other sessions going", "how are the other sessions doing",
        "how are my sessions doing", "how are all my sessions doing", "whats everyone doing", "what is everyone working on", "whats everyone up to",
        "hows everything going", "give me a status update", "who needs me", "what needs my attention",
        "is anyone waiting on me", "is anybody waiting for me", "whats happening", "roll call", "status report",
    ].map { $0.split(separator: " ").map(String.init) }
    static let greetings = [
        "how are you doing", "how are you doing today", "hows it going", "how are you", "good morning",
        "good afternoon", "good evening", "how is your day going",
    ].map { $0.split(separator: " ").map(String.init) }

    /// Words that carry little: a template must match at least two others.
    static let light: Set<String> = ["how", "hows", "are", "is", "the", "a", "an", "to", "of", "on", "me", "my", "it",
                                     "its", "what", "whats", "all", "do", "does", "for", "in", "at", "i", "we", "with"]

    static func weight(_ t: String) -> Double { light.contains(t) ? 0.5 : 1 }

    private static func template(_ heard: [String], gated: Bool, _ memo: Memo) -> Command? {
        var best: (ratio: Double, command: Command)?
        for (templates, command) in [(rollCall, Command.status(target: nil)), (greetings, .greet)] {
            for t in templates {
                guard let r = fit(heard, t, gated: gated, memo), r <= (best?.ratio ?? 0.3) else { continue }
                best = (r, command)
            }
        }
        return best?.command
    }

    /// How far the heard words are from the template, as a share of the
    /// template's weight (0 is the same; nil when too little of it was heard).
    /// The template's first words may be missing: the gate ate them.
    static func fit(_ heard: [String], _ template: [String], gated: Bool, _ memo: Memo = Memo()) -> Double? {
        var best: Double?
        // Gated, all but the last two words may be gone ("sessions going").
        let maxDrop = min(gated ? template.count - 2 : 2, template.count - 1)
        for k in 0...max(0, maxDrop) {
            let t = Array(template[k...])
            let total = t.reduce(0) { $0 + weight($1) }
            guard t.filter({ !light.contains($0) }).count >= 2 || k == 0 else { continue }
            let (cost, matched) = align(heard, t, cutStart: k > 0 || gated, memo)
            guard matched >= min(2, t.filter({ !light.contains($0) }).count) else { continue }
            let r = (cost + 0.05 * Double(k)) / total
            if r < (best ?? .infinity) { best = r }
        }
        return best
    }

    /// Edit distance over words, where a substitution costs by how unalike the
    /// words sound. Returns the cost and how many heavy template words were heard.
    static func align(_ h: [String], _ t: [String], cutStart: Bool, _ memo: Memo) -> (Double, Int) {
        let insert = 0.5
        let n = h.count, m = t.count
        var cost = [[Double]](repeating: [Double](repeating: 0, count: m + 1), count: n + 1)
        var hits = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        // Up to two words heard before the template starts cost less: what is
        // left of words the gate cut ("or have" for "how are").
        for i in 1...max(1, n) where i <= n { cost[i][0] = cost[i - 1][0] + (i <= 2 ? 0.25 : insert) }
        for j in 1...max(1, m) where j <= m { cost[0][j] = cost[0][j - 1] + weight(t[j - 1]) }
        guard n > 0, m > 0 else { return (cost[n][m], 0) }
        for i in 1...n {
            for j in 1...m {
                var sim = memo.sim(h[i - 1], t[j - 1])
                // The first word heard may be the end of a word the gate cut.
                if i == 1, cutStart, h[0].count >= 2, t[j - 1].count > h[0].count, t[j - 1].hasSuffix(h[0]) {
                    sim = max(sim, 0.8)
                }
                let w = weight(t[j - 1])
                let sub = sim >= 0.4 ? w * (1 - sim) : w + 0.25
                let hit = sim >= 0.5 && !light.contains(t[j - 1]) ? 1 : 0
                var c = cost[i - 1][j - 1] + sub, k = hits[i - 1][j - 1] + hit
                if cost[i - 1][j] + insert < c || (cost[i - 1][j] + insert == c && hits[i - 1][j] > k) {
                    c = cost[i - 1][j] + insert; k = hits[i - 1][j]
                }
                if cost[i][j - 1] + w < c || (cost[i][j - 1] + w == c && hits[i][j - 1] > k) {
                    c = cost[i][j - 1] + w; k = hits[i][j - 1]
                }
                cost[i][j] = c; hits[i][j] = k
            }
        }
        return (cost[n][m], hits[n][m])
    }

    // MARK: - Session names

    struct Spot: Equatable {
        let name: String
        let start: Int
        let end: Int
        let score: Double
    }

    /// Words a name is never made of alone.
    static let notName: Set<String> = light.union(["you", "your", "doing", "going", "up", "session", "sessions", "and",
                                                   "so", "that", "this", "there", "be", "can", "should", "would"])

    /// Words of a command: never taken for the end of a cut name ("check" is not "deny check").
    static let commandWords: Set<String> = ["check", "status", "stop", "tell", "ask", "send", "start", "update", "next",
                                            "new", "yes", "no", "approve", "deny", "allow", "cancel"]
    static let stopWords: Set<String> = ["stop", "halt", "pause", "cancel", "quit", "kill", "interrupt"]

    static let nameThreshold = 0.75
    /// For "<a whole ask> for NAME", which is always asked about first.
    static let askThreshold = 0.7

    /// How well heard letters match a name: SoundsLike.similarity, or a little
    /// less than the sound alone when the sound key is long enough to say much
    /// ("your child" and "earshot" sound alike and are spelled apart).
    static func nameScore(_ heard: String, _ name: String, heardKey: String? = nil, nameKey: String? = nil) -> Double {
        if heard == name { return 1 }
        let kh = heardKey ?? SoundsLike.key(heard), kn = nameKey ?? SoundsLike.key(name)
        let bySound = min(kh.count, kn.count) >= 4 ? 0.9 * SoundsLike.ratio(Array(kh), Array(kn)) : 0
        return max(SoundsLike.similarity(heard, kh, name, kn), bySound)
    }

    /// The session name that best matches some run of the heard words, by
    /// sound or spelling. A run that opens what was heard may be the end of a
    /// name, cut by the gate ("shot" for "earshot").
    static func findName(_ keys: [String], known: [String], gated: Bool) -> Spot? {
        var best: Spot?
        // Each run of heard words as one string and its sound key, worked out once.
        var runs: [[Int]: (text: String, key: String)] = [:]
        func run(_ s: Int, _ len: Int, _ span: [String]) -> (text: String, key: String) {
            if let r = runs[[s, len]] { return r }
            let text = span.joined()
            let r = (text, SoundsLike.key(text))
            runs[[s, len]] = r
            return r
        }
        for name in known {
            let nameWords = Grammar.nameWords(name).map(SoundsLike.letters).filter { !$0.isEmpty }
            guard !nameWords.isEmpty else { continue }
            let whole = nameWords.joined(), wholeKey = SoundsLike.key(whole)
            for s in keys.indices {
                for len in 1...min(nameWords.count + 1, keys.count - s) {
                    var span = Array(keys[s..<(s + len)])
                    if span.first == "the", span.count > 1 { span.removeFirst() }
                    if span.last == "session", span.count > 1 { span.removeLast() }
                    guard !span.allSatisfy(notName.contains) else { continue }
                    let heard = run(s, len, span)
                    var score = nameScore(heard.text, whole, heardKey: heard.key, nameKey: wholeKey)
                    if s == 0, gated, !span.contains(where: commandWords.contains),
                       SoundsLike.endsName(span.joined(separator: " "), name) {
                        score = max(score, 0.85)
                    }
                    guard score >= askThreshold else { continue }
                    let spot = Spot(name: name, start: s, end: s + len, score: score)
                    if best == nil || score > best!.score || (score == best!.score && len > best!.end - best!.start) {
                        best = spot
                    }
                }
            }
        }
        return best
    }

    /// What comes after a name in a status question.
    static let statusTails = [
        "doing", "going", "working on", "up to", "done", "done yet", "finished", "finished yet", "doing right now",
        "status", "at",
    ].map { $0.split(separator: " ").map(String.init) }
    /// What comes before a name in a status question that ends with it.
    static let statusLeads = ["check on", "status of", "whats the status of", "status on", "hows", "how is",
                              "whats up with", "how about"].map { $0.split(separator: " ").map(String.init) }

    private static func withName(_ w: Grammar.Words, _ keys: [String], _ spot: Spot, gated: Bool,
                                 _ memo: Memo) -> Command? {
        let lead = Array(keys[..<spot.start]), rest = Array(keys[spot.end...])
        // A stop is never guessed: it goes by the grammar only.
        if keys.contains(where: stopWords.contains) { return nil }
        // "<prompt> for NAME", when the prompt is a whole ask.
        if spot.end == keys.count, spot.start >= 4, keys[spot.start - 1] == "for" {
            return send(spot.name, w.slice(0..<(spot.start - 1)))
        }
        guard spot.score >= nameThreshold else { return nil }
        // A known name and nothing else: how is it doing.
        if lead.isEmpty, rest.isEmpty, spot.score >= 0.9 { return .status(target: spot.name) }
        // A status question: "<how's> NAME doing", "what's NAME working on".
        if lead.count <= 3, !rest.isEmpty, statusTails.contains(where: { closeEnough(rest, $0, gated: gated, memo) }) {
            return .status(target: spot.name)
        }
        if rest.isEmpty, !lead.isEmpty, statusLeads.contains(where: { closeEnough(lead, $0, gated: gated, endOnly: true, memo) }) {
            return .status(target: spot.name)
        }
        // "[tell] NAME to <prompt>": the tell or ask may be cut or garbled.
        if lead.count <= 1, rest.count >= 3, rest[0] == "to" {
            if lead.isEmpty || ["tell", "ask", "get"].contains(where: { SoundsLike.similarity(lead[0], $0) >= 0.5 }) || gated {
                return send(spot.name, w.slice((spot.end + 1)..<w.count))
            }
        }
        // "NAME, <prompt>", or with the comma lost when the start was cut.
        if lead.isEmpty, rest.count >= 2, rest[0] != "to", gated || w.said[spot.end - 1].hasSuffix(",") {
            return send(spot.name, w.slice(spot.end..<w.count))
        }
        return nil
    }

    private static func send(_ name: String, _ prompt: Grammar.Words) -> Command? {
        let p = prompt.trimmingPromptFillers()
        guard !p.isBlankPrompt, p.count >= 2 else { return nil }
        return .confirmSend(target: name, prompt: p.text)
    }

    /// The words are this phrase, near enough. `endOnly`: the phrase's start may be missing (a cut).
    static func closeEnough(_ heard: [String], _ phrase: [String], gated: Bool, endOnly: Bool = false,
                            _ memo: Memo) -> Bool {
        guard heard.count <= phrase.count + 1 else { return false }
        let total = phrase.reduce(0) { $0 + weight($1) }
        let (cost, _) = align(heard, phrase, cutStart: gated, memo)
        if cost / total <= 0.35 { return true }
        guard endOnly || gated, phrase.count > 1 else { return false }
        for k in 1..<phrase.count {
            let t = Array(phrase[k...])
            let (c, _) = align(heard, t, cutStart: true, memo)
            if c / t.reduce(0, { $0 + weight($1) }) <= 0.3 { return true }
        }
        return false
    }

    /// For kobi-probe: how near the words come to the nearest whole-command templates.
    public static func explain(_ text: String, gated: Bool) -> String {
        let keys = Grammar.Words(text).trimmingFillers().keys.map(SoundsLike.letters)
        return (rollCall + greetings).compactMap { t in
            fit(keys, t, gated: gated).map { String(format: "%.2f %@", $0, t.joined(separator: " ")) }
        }.sorted().prefix(3).joined(separator: "; ")
    }
}
