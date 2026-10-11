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
