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
            return w.trimmingTail()
        }

        /// Trailing um and uh always go. Trailing please, thanks and thank you go
        /// only when the word before them ends with a comma ("deploy, thanks").
        func trimmingTail() -> Words {
            var w = self
            while let l = w.keys.last {
                let n = w.count
                if ["um", "uh"].contains(l) {
                    w = w.slice(0..<(n - 1))
                } else if l == "please" || l == "thanks", n >= 2, w.said[n - 2].hasSuffix(",") {
                    w = w.slice(0..<(n - 1))
                } else if n >= 3, Array(w.keys[(n - 2)...]) == ["thank", "you"], w.said[n - 3].hasSuffix(",") {
                    w = w.slice(0..<(n - 2))
                } else {
                    break
                }
            }
            return w
        }

        /// What a prompt keeps: only um, uh, erm, hmm and please go from its edges (G4).
        func trimmingPromptFillers() -> Words {
            var w = self
            while let f = w.keys.first, Grammar.promptFillers.contains(f) { w = w.slice(1..<w.count) }
            if let rest = w.after(Grammar.leadIns) { w = rest }
            while let f = w.keys.first, Grammar.promptFillers.contains(f) { w = w.slice(1..<w.count) }
            return w.trimmingTail()
        }

        /// True when nothing is left but articles and fillers.
        var isBlankPrompt: Bool {
            keys.allSatisfy { Grammar.promptFillers.contains($0) || Grammar.articles.contains($0) }
        }
    }

    static let fillers: Set<String> = ["um", "uh", "erm", "hmm", "so", "okay", "ok", "please", "hey", "and", "like"]
    static let leadIns = ["can you", "could you", "would you", "will you", "i want you to", "i need you to",
                          "go ahead and", "i'd like you to"]
    static let promptFillers: Set<String> = ["um", "uh", "erm", "hmm", "please"]
    static let articles: Set<String> = ["the", "a", "an"]
    /// A word that ends a "to" phrase in a negation or a question: the grammar leaves it to the model (G1).
    static let blockersBeforeTo: Set<String> = ["not", "how", "what", "where", "when", "whether", "why", "which", "never"]

    /// An answer is a yes or no word, then at most a few words from its tail
    /// ("okay, go ahead", "no, don't"). Any other word makes it no answer.
    static let yesWords: Set<String> = ["yes", "yeah", "yep", "yup", "sure", "okay", "ok", "allow", "approve", "approved",
                                        "go", "do", "alright", "fine"]
    /// The yes words that count outside a window, where a short noise is often heard as "okay" or "yeah".
    static let plainYesWords: Set<String> = ["yes", "allow", "approve", "approved"]
    static let yesTail: Set<String> = ["go", "ahead", "do", "it", "for", "that", "that's", "please", "thing", "once",
                                       "thanks", "now", "sure", "yes", "yeah", "yep", "okay", "ok", "fine", "alright",
                                       "right", "then", "allow", "approve"]
    static let noWords: Set<String> = ["no", "nope", "nah", "not", "don't", "dont", "deny", "stop", "cancel"]
    static let noTail: Set<String> = ["don't", "dont", "do", "it", "that", "way", "thanks", "thank", "you", "please",
                                      "not", "now", "yet", "stop", "deny", "no", "nope", "cancel"]

    static let everyone: Set<String> = [
        "what's everyone doing", "what is everyone doing", "whats everyone doing", "what's everybody doing",
        "what is everybody doing", "what's everyone up to", "what's everybody up to", "roll call", "status",
        "status update", "give me a status update", "give me a status", "status report", "what's happening",
        "what's going on", "what is going on", "how's everything going", "how is everything going",
        "how's everything", "what's the status", "everyone's status",
        // What needs you: the roll call says those first.
        "who needs me", "what needs me", "does anything need me", "does anyone need me", "does anybody need me",
        "is anyone waiting on me", "is anything waiting on me", "is anybody waiting on me", "who's waiting on me",
        "who is waiting on me", "is anyone waiting for me", "who's waiting for me", "anything need me",
        "what needs my attention", "does anything need my attention",
    ]

    /// Asked of Earshot itself: a short answer with what needs you.
    static let greetings: Set<String> = [
        "how are you doing", "how are you", "how you doing", "how're you doing", "how's it going",
        "how is it going", "how are things", "how are things going", "what's up", "what's new", "how are we doing",
        "how's it looking", "how are you doing today", "hi", "hello", "hey there", "hi there", "hello there",
        "how ya doing", "how ya doin", "how you doing today", "how ya doing today", "how are you today",
        "how's your day", "how's your day going", "good morning", "good afternoon", "good evening", "morning",
    ]

    /// Nothing to do, and nothing to say back.
    static let noOps: Set<String> = [
        "thanks", "thank you", "thanks earshot", "thank you earshot", "thanks a lot", "thank you very much",
        "thanks so much", "never mind", "nevermind", "forget it", "cancel", "cancel that", "that's all", "that's it",
        "got it", "cool", "great", "perfect", "nice", "awesome", "all right", "alright", "good",
    ]

    static let repeatPhrases: Set<String> = [
        "repeat that", "repeat it", "repeat", "repeat that please", "say that again", "say it again", "say again",
        "say that again please", "come again", "what did you say", "what was that", "sorry what was that",
        "pardon", "pardon me", "one more time", "again",
    ]

    /// (starts with, ends with) around a target.
    static let statusShapes: [(String, String)] = [
        ("what's the status of", ""), ("what is the status of", ""), ("what's", "doing"), ("what is", "doing"),
        ("whats", "doing"), ("how's", "doing"), ("how is", "doing"), ("how's", "going"), ("how is", "going"),
        ("status of", ""), ("status on", ""), ("what's up with", ""), ("where's", "at"), ("where is", "at"),
        ("check on", ""), ("what's", "working on"), ("what is", "working on"), ("whats", "working on"),
        ("what's", "up to"), ("what is", "up to"), ("whats", "up to"), ("is", "done"), ("is", "done yet"),
        ("is", "finished"), ("is", "finished yet"), ("how's it going with", ""), ("how is it going with", ""),
        // A bare "how's billing", and how it is often misheard ("how you billing").
        // Only a known session name counts, so other questions still reach the model.
        ("how's the", ""), ("how is the", ""), ("how's", ""), ("how is", ""), ("how are", ""), ("how you", ""),
        ("how's your", ""), ("how your", ""),
        ("", "status"),
    ]

    /// Said to quiet Earshot. A bare stop never reaches a session: you often say it
    /// over Earshot's own line, and the session it would pick is only a guess.
    static let quietWords: Set<String> = ["stop", "stop it", "stop that", "halt", "pause", "stop talking", "quiet",
                                          "be quiet", "quiet please", "shut up", "hush", "enough", "that's enough"]
    static let everyoneWords: Set<String> = ["everyone", "everybody", "everything", "all", "all sessions",
                                             "all the sessions", "all of them", "them all", "every session",
                                             "all of you", "you all"]

    static let questionWords: Set<String> = ["what", "what's", "why", "how", "whether", "if", "when", "where",
                                             "which", "who", "is", "are", "does", "did"]
    static let pronouns: Set<String> = ["it", "them", "him", "her", "claude", "that session", "this session"]

    /// True when a target could be one of the known names. With no names known, any target passes.
    public static func looksKnown(_ target: String, known: [String]) -> Bool {
        if known.isEmpty { return true }
        let t = nameWords(target)
        guard !t.isEmpty else { return false }
        return known.contains { k in
            let n = nameWords(k)
            return !n.isEmpty && (t.starts(with: n) || n.starts(with: t))
        }
    }

    /// A name as words: lowercase, no leading "the", no trailing "session".
    static func nameWords(_ s: String) -> [String] {
        var w = Words(s).keys
        if w.first == "the" { w.removeFirst() }
        if w.last == "session" { w.removeLast() }
        return w
    }

    /// The answer in an approval window: any yes or no word, with a short tail.
    public static func windowAnswer(_ text: String) -> Bool? { yesOrNo(text, yes: yesWords, no: noWords) }

    /// An answer outside a window: only yes, allow or approve says yes, unless a
    /// session is named with it (`named`). "Stop" and "cancel" are the Stop command there.
    public static func plainAnswer(_ text: String, named: Bool = false) -> Bool? {
        yesOrNo(text, yes: named ? yesWords : plainYesWords, no: noWords.subtracting(["stop", "cancel"]))
    }

    static func yesOrNo(_ text: String, yes: Set<String>, no: Set<String>) -> Bool? {
        var w = Words(text)
        while let f = w.keys.first, ["um", "uh", "erm", "hmm", "oh", "well"].contains(f) { w = w.slice(1..<w.count) }
        guard let first = w.keys.first, w.count <= 5 else { return nil }
        let tail = Set(w.keys.dropFirst())
        if yes.contains(first), tail.isSubset(of: yesTail) { return true }
        if no.contains(first), tail.isSubset(of: noTail) { return false }
        return nil
    }

    public static func parse(_ transcript: String, known: [String] = []) -> Command? {
        if let allow = plainAnswer(transcript) { return .answer(allow: allow, target: nil) }
        // "Okay" or "yeah" alone outside a window answers nothing: it is often a noise
        // or a false start, so Earshot stays quiet. "Go ahead" or "do it" was meant as
        // an answer, so Earshot says it didn't get it.
        if windowAnswer(transcript) == true {
            return Words(transcript).keys.contains { $0 == "go" || $0 == "do" } ? .unknown : .quiet
        }
        var w = Words(transcript).trimmingFillers()
        // "Earshot, ..." speaks to Earshot itself, not to a session called earshot.
        if w.keys.first == "earshot", w.said.first?.hasSuffix(",") == true { w = w.slice(1..<w.count).trimmingFillers() }
        guard !w.isEmpty else { return .unknown }
        if noOps.contains(w.key) { return .quiet }
        if repeatPhrases.contains(w.key) { return .repeatLast }
        if let c = answer(w, known: known) ?? status(w, known: known) ?? stop(w, known: known) ?? start(w) ?? send(w, known: known) { return c }
        return nil
    }

    // MARK: - Shapes

    private static func answer(_ w: Words, known: [String]) -> Command? {
        for (prefixes, allow) in [(["yes to", "yes for", "yes", "yeah", "approve", "allow", "go ahead for"], true),
                                  (["no to", "no for", "no", "deny", "don't allow", "reject"], false)] {
            guard var rest = w.after(prefixes), !rest.isEmpty, rest.count <= 4, rest.keys.first != "and" else { continue }
            if rest.keys.first == "it" { rest = rest.slice(1..<rest.count) }
            if rest.isEmpty { return .answer(allow: allow, target: nil) }
            guard looksKnown(rest.text, known: known) else { continue }
            return .answer(allow: allow, target: rest.text)
        }
        return nil
    }

    private static func status(_ w: Words, known: [String]) -> Command? {
        if everyone.contains(w.key) { return .status(target: nil) }
        if greetings.contains(w.key) { return .greet }
        for (pre, post) in statusShapes {
            guard var t = pre.isEmpty ? Optional(w) : w.after([pre]) else { continue }
            if !post.isEmpty { guard let b = t.before([post]) else { continue }; t = b }
            guard !t.isEmpty, t.count <= 5 else { continue }
            if ["everyone", "everybody", "everything"].contains(t.key) || pronouns.contains(t.key) { return .status(target: nil) }
            guard looksKnown(t.text, known: known) else { continue }
            return .status(target: t.text)
        }
        return nil
    }

    private static func stop(_ w: Words, known: [String]) -> Command? {
        if quietWords.contains(w.key) { return .quiet }
        let nowWords = ["right now", "now", "immediately", "at once"]
        // "Billing, stop."
        if let (t, p) = w.splitAtComma(), startsKnownName(t, known: known) {
            switch p.key {
            case "stop", "stop it", "halt", "pause": return .stop(target: Words(t.text).text, now: false)
            case "stop now", "stop right now", "stop immediately": return .stop(target: Words(t.text).text, now: true)
            default: break
            }
        }
        if let rest = w.after(["tell", "ask"]), let (t, p) = rest.split(at: ["to"]), !t.isEmpty {
            if blockersBeforeTo.contains(t.keys.last ?? "") { return nil }
            if everyoneWords.contains(t.key), p.keys.first == "stop", p.count <= 3 { return .stopAll }
            if pronouns.contains(t.key) || looksKnown(t.text, known: known) {
                let target = pronouns.contains(t.key) ? nil : t.text
                switch p.key {
                case "stop": return .stop(target: target, now: false)
                case "stop now", "stop right now", "stop immediately", "stop at once": return .stop(target: target, now: true)
                default: break
                }
            }
        }
        guard var t = w.after(["stop", "halt", "pause"]), !t.isEmpty, t.count <= 6 else { return nil }
        var now = false
        if let b = t.before(nowWords) { t = b; now = true }
        if t.isEmpty || ["it", "that", "this", "talking"].contains(t.key) { return .quiet }
        if everyoneWords.contains(t.key) { return .stopAll }
        if pronouns.contains(t.key) { return .stop(target: nil, now: now) }
        guard looksKnown(t.text, known: known) else { return nil }
        return .stop(target: t.text, now: now)
    }

    /// True when the words are a known name, or the start of one ("billing" for
    /// "billing service"). Stricter than looksKnown: for a name said first,
    /// where an ordinary sentence could start the same way. A name that starts
    /// like a question ("What's next"), or after "the" ("so the wedding, it's
    /// next week"), never counts here.
    static func startsKnownName(_ w: Words, known: [String]) -> Bool {
        let t = nameWords(w.text)
        guard !t.isEmpty, t.count <= 4, w.keys.first != "the", !questionWords.contains(t[0]) else { return false }
        return known.contains { k in
            let n = nameWords(k)
            return !n.isEmpty && n.starts(with: t)
        }
    }

    private static func start(_ w: Words) -> Command? {
        let shapes = ["start a new session in", "start a new session for", "start a new session on",
                      "start a session in", "start a session for", "start a session on", "start new session in",
                      "open a new session in", "open a session in", "new session in", "new session for",
                      "spin up a session in", "start claude in"]
        guard let rest = w.after(shapes) else { return nil }
        guard !rest.isEmpty else { return .unknown }
        if let (p, prompt) = rest.split(at: ["to", "and"]), !p.isEmpty {
            let pr = prompt.trimmingPromptFillers()
            return .start(project: p.text, prompt: pr.isEmpty ? nil : pr.text)
        }
        return .start(project: rest.text, prompt: nil)
    }

    private static func send(_ w: Words, known: [String]) -> Command? {
        // tell X to P, ask X to P, get X to P
        if let rest = w.after(["tell", "ask", "get"]) {
            if let (t, p) = rest.split(at: ["to"]), !t.isEmpty {
                if blockersBeforeTo.contains(t.keys.last ?? "") { return nil }
                return make(target: t, prompt: p, known: known)
            }
            // ask X what / why / how ...: the question is the prompt
            if w.keys.first == "ask", let i = rest.keys.indices.dropFirst().first(where: { questionWords.contains(rest.keys[$0]) }) {
                return make(target: rest.slice(0..<i), prompt: rest.slice(i..<rest.count), known: known)
            }
            return nil
        }
        // in X, P / on X: P / for X P (with a known name)
        if let rest = w.after(["in", "on", "for", "over in"]) {
            if let (t, p) = rest.splitAtComma() ?? rest.splitAtKnown(known), !t.isEmpty {
                return make(target: t, prompt: p, known: known)
            }
            if rest.said.last?.hasSuffix(",") == true || rest.said.last?.hasSuffix(":") == true { return .unknown }
            return nil
        }
        // X, P: a session named first ("blog, run the tests"). "Blog, yes" answers its prompt.
        if let (t, p) = w.splitAtComma(), startsKnownName(t, known: known) {
            if let allow = plainAnswer(p.text, named: true) { return .answer(allow: allow, target: Words(t.text).text) }
            // "Billing, cancel" is not a prompt to send: the model decides.
            if noOps.contains(p.key) || quietWords.contains(p.key) { return nil }
            return make(target: t, prompt: p, known: known)
        }
        // send P to X
        if let rest = w.after(["send"]), let i = rest.keys.lastIndex(of: "to"), i > 0, i < rest.count - 1 {
            return make(target: rest.slice((i + 1)..<rest.count), prompt: rest.slice(0..<i), known: known)
        }
        return nil
    }

    private static func make(target: Words, prompt: Words, known: [String]) -> Command? {
        let t = Words(target.text)   // drops a trailing comma or colon
        let named = !t.isEmpty && !pronouns.contains(t.key)
        if named && !looksKnown(t.text, known: known) { return nil }
        let p = prompt.trimmingPromptFillers()
        guard !p.isBlankPrompt else { return .unknown }
        return .send(target: named ? t.text : nil, prompt: p.text)
    }
}
