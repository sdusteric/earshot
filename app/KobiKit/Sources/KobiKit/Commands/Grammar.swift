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
            after(split: phrases.sorted(by: { $0.count > $1.count }).map { $0.split(separator: " ").map(String.init) })
        }

        /// The same, for phrases already split into words, longest first.
        func after(split phrases: [[String]]) -> Words? {
            guard let first = keys.first else { return nil }
            for pk in phrases where pk.first == first && keys.starts(with: pk) { return slice(pk.count..<count) }
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

        /// Split after a known name, with an optional "the" before it and "session" or "one" after it.
        func splitAtKnownSession(_ known: [String]) -> (Words, Words)? {
            guard let (t, p) = splitAtKnown(known) else { return nil }
            if let f = p.keys.first, ["session", "one"].contains(f) {
                return (slice(0..<(t.count + 1)), p.slice(1..<p.count))
            }
            return (t, p)
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
                                        "go", "do", "alright", "fine", "let", "absolutely", "definitely"]
    /// The yes words that count outside a window, where a short noise is often heard as "okay" or "yeah".
    static let plainYesWords: Set<String> = ["yes", "allow", "approve", "approved"]
    static let yesTail: Set<String> = ["go", "ahead", "do", "it", "for", "that", "that's", "please", "thing", "once",
                                       "thanks", "now", "sure", "yes", "yeah", "yep", "okay", "ok", "fine", "alright",
                                       "right", "then", "allow", "approve", "let", "run", "with", "them", "ahead"]
    static let noWords: Set<String> = ["no", "nope", "nah", "not", "don't", "dont", "deny", "stop", "cancel"]
    static let noTail: Set<String> = ["don't", "dont", "do", "it", "that", "way", "thanks", "thank", "you", "please",
                                      "not", "now", "yet", "stop", "deny", "no", "nope", "cancel", "let", "them", "for", "allow"]

    static let everyone: Set<String> = [
        "what's everyone doing", "what is everyone doing", "whats everyone doing", "what's everybody doing",
        "what is everybody doing", "what's everyone up to", "what's everybody up to", "roll call", "status",
        "status update", "give me a status update", "give me a status", "status report", "what's happening",
        "what's going on", "what is going on", "how's everything going", "how is everything going",
        "how's everything", "what's the status", "everyone's status", "how's it all going", "how is it all going",
        "catch me up", "fill me in", "what did i miss", "bring me up to speed", "any updates", "give me an update",
        "give me the rundown", "give me a rundown",
        // What needs you: the roll call says those first.
        "who needs me", "what needs me", "does anything need me", "does anyone need me", "does anybody need me",
        "is anyone waiting on me", "is anything waiting on me", "is anybody waiting on me", "who's waiting on me",
        "who is waiting on me", "is anyone waiting for me", "who's waiting for me", "anything need me",
        "what needs my attention", "does anything need my attention",
    ]

    /// Asked of Kobi itself: a short answer with what needs you.
    static let greetings: Set<String> = [
        "how are you doing", "how are you", "how you doing", "how're you doing", "how's it going",
        "how is it going", "how are things", "how are things going", "what's up", "what's new", "how are we doing",
        "how's it looking", "how are you doing today", "hi", "hello", "hey there", "hi there", "hello there",
        "how ya doing", "how ya doin", "how you doing today", "how ya doing today", "how are you today",
        "how's your day", "how's your day going", "good morning", "good afternoon", "good evening", "morning",
    ]

    /// Nothing to do, and nothing to say back.
    static let noOps: Set<String> = [
        "thanks", "thank you", "thanks kobi", "thank you kobi", "thanks kobe", "thank you kobe", "thanks a lot",
        "thank you very much",
        "thanks so much", "never mind", "nevermind", "forget it", "cancel", "cancel that", "that's all", "that's it",
        "got it", "cool", "great", "perfect", "nice", "awesome", "all right", "alright", "good",
    ]

    /// Said to the session Kobi last spoke about: go on with what it was doing.
    static let continuePhrases: Set<String> = ["keep going", "carry on", "continue", "go on", "keep at it",
                                               "keep working", "keep it going"]

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
        ("how are", "going"), ("how are", "doing"),
        ("how's the", ""), ("how is the", ""), ("how's", ""), ("how is", ""), ("how are", ""), ("how you", ""),
        ("how's your", ""), ("how your", ""),
        ("tell me what", "did"), ("tell me what", "is doing"), ("tell me what", "has done"), ("what did", "do"),
        ("what has", "done"), ("has", "finished"), ("did", "finish"),
        ("", "status"),
    ]

    /// What ends a status question after the name ("doing", "working on").
    static let statusTails: Set<String> = ["doing", "going", "working on", "up to", "done", "done yet", "finished",
                                           "finished yet", "doing right now", "working on right now"]

    /// Said to quiet Kobi. A bare stop never reaches a session: you often say it
    /// over Kobi's own line, and the session it would pick is only a guess.
    static let quietWords: Set<String> = ["stop", "stop it", "stop that", "halt", "pause", "stop talking", "quiet",
                                          "be quiet", "quiet please", "shut up", "hush", "enough", "that's enough"]
    /// Every session at once, in a status question ("how are the other sessions going").
    static let allSessions: Set<String> = [
        "everyone", "everybody", "everything", "sessions", "the sessions", "all sessions", "all the sessions",
        "the other sessions", "all the other sessions", "my sessions", "all my sessions", "the others",
        "all the others", "the rest", "all of them", "they all",
    ]

    static let everyoneWords: Set<String> = ["everyone", "everybody", "everything", "all", "all sessions",
                                             "all the sessions", "all of them", "them all", "every session",
                                             "all of you", "you all"]

    static let questionWords: Set<String> = ["what", "what's", "why", "how", "whether", "if", "when", "where",
                                             "which", "who", "is", "are", "does", "did"]
    static let pronouns: Set<String> = ["it", "them", "him", "her", "claude", "that session", "this session"]

    /// True when a target could be one of the known names. With no names known, any target passes.
    public static func looksKnown(_ target: String, known: [String]) -> Bool {
        if known.isEmpty { return true }
        var t = nameWords(target)
        // Untitled sessions in one folder go by age ("the newer blog session").
        if t.count > 1, ["older", "newer", "first", "second", "third"].contains(t[0]) { t.removeFirst() }
        guard !t.isEmpty else { return false }
        return known.contains { k in
            let n = nameWords(k)
            return !n.isEmpty && (t.starts(with: n) || n.starts(with: t))
        }
    }

    /// Words that only point at a session around its name ("the blog one", "the billing session").
    static let nameTails: Set<String> = ["one", "thing", "request", "project", "folder", "job"]

    /// A target as said, without what only points at it: "the blog one" is "the blog".
    static func cleanTarget(_ w: Words) -> Words {
        var t = Words(w.text)
        while let l = t.keys.last, t.count > 1, nameTails.contains(l) || l == "please" { t = t.slice(0..<(t.count - 1)) }
        // "kobi's request": the name without its 's.
        if let l = t.said.last, l.lowercased().hasSuffix("'s") || l.lowercased().hasSuffix("\u{2019}s") {
            t = Words((t.said.dropLast() + [String(l.dropLast(2))]).joined(separator: " "))
        }
        return t
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
        // "Absolutely not": the not answers.
        if w.count >= 2, ["absolutely", "definitely", "certainly"].contains(w.keys[0]), w.keys[1] == "not" { w = w.slice(1..<w.count) }
        guard let first = w.keys.first, w.count <= 5 else { return nil }
        let tail = Set(w.keys.dropFirst())
        // "Let it go", "let that go": drop it, not a yes.
        if first == "let", tail.contains("go") { return nil }
        if yes.contains(first), tail.isSubset(of: yesTail) { return true }
        if no.contains(first), tail.isSubset(of: noTail) { return false }
        return nil
    }

    public static func parse(_ transcript: String, known: [String] = []) -> Command? {
        if let allow = plainAnswer(transcript) { return .answer(allow: allow, target: nil) }
        // "Okay" or "yeah" alone outside a window answers nothing: it is often a noise
        // or a false start, so Kobi stays quiet. "Go ahead" or "do it" was meant as
        // an answer, so Kobi says it didn't get it.
        if windowAnswer(transcript) == true {
            return Words(transcript).keys.contains { $0 == "go" || $0 == "do" } ? .unknown : .quiet
        }
        // Before fillers go: "OK for docs site" starts with its yes.
        if let c = answer(Words(transcript), known: known) { return c }
        var w = Words(transcript).trimmingFillers()
        // "Kobi, ..." speaks to Kobi itself, not to a session called kobi. Recognizers
        // mostly write the name "Kobe" (Listener.nameSpellings). The name stands apart as the
        // wake takes it (Listener.wakeWords): a comma, a stop, ? or ! right after it.
        if let first = w.keys.first, Listener.nameSpellings.contains(first),
           let said = w.said.first?.last, ",.!?".contains(said) {
            w = w.slice(1..<w.count).trimmingFillers()
        }
        guard !w.isEmpty else { return .unknown }
        if noOps.contains(w.key) { return .quiet }
        if repeatPhrases.contains(w.key) { return .repeatLast }
        if continuePhrases.contains(w.key) { return .send(target: nil, prompt: w.text) }
        if let c = answer(w, known: known) ?? status(w, known: known) ?? stop(w, known: known) ?? start(w, known: known) ?? send(w, known: known) { return c }
        return nil
    }

    // MARK: - Shapes

    private static func answer(_ w: Words, known: [String]) -> Command? {
        for (prefixes, allow) in [(["yes to", "yes for", "yes", "yeah", "approve", "allow", "go ahead for", "go ahead with",
                                    "ok for", "okay for", "yes go ahead with"], true),
                                  (["no to", "no for", "no", "deny", "don't allow", "reject", "nope", "nah", "no not for",
                                    "nope not for", "nah not for", "not for", "no not", "nope not", "nah not"], false)] {
            guard var rest = w.after(prefixes), !rest.isEmpty, rest.count <= 4, rest.keys.first != "and" else { continue }
            if rest.keys.first == "it" { rest = rest.slice(1..<rest.count) }
            if rest.isEmpty { return .answer(allow: allow, target: nil) }
            let t = cleanTarget(rest)
            guard looksKnown(t.text, known: known) else { continue }
            return .answer(allow: allow, target: t.text)
        }
        // "Let billing do it", "don't let billing do that", "tell the blog no".
        for (prefixes, allow) in [(["let"], true), (["don't let", "no don't let", "do not let", "no do not let"], false)] {
            guard let rest = w.after(prefixes) else { continue }
            for tail in ["do it", "do that", "go ahead", "run it", "have it"] {
                if let t = rest.before([tail]), plainName(t, known: known) {
                    return .answer(allow: allow, target: cleanTarget(t).text)
                }
            }
        }
        if let rest = w.after(["tell"]), let l = rest.keys.last, rest.count >= 2, ["yes", "no"].contains(l) {
            let t = rest.slice(0..<(rest.count - 1))
            if plainName(t, known: known) { return .answer(allow: l == "yes", target: cleanTarget(t).text) }
        }
        return nil
    }

    private static func status(_ w: Words, known: [String]) -> Command? {
        if everyone.contains(w.key) { return .status(target: nil) }
        if greetings.contains(w.key) { return .greet }
        // A session's whole name and nothing else, even one that ends like a
        // status question would ("Reflow status" is not "reflow, status"). A
        // name that starts like a question ("What's next") is left to the model.
        if isExactName(w.text, known: known), !questionWords.contains(nameWords(w.text).first ?? "") {
            return .status(target: w.text)
        }
        for (pre, post) in statusShapes {
            guard var t = pre.isEmpty ? Optional(w) : w.after([pre]) else { continue }
            if !post.isEmpty { guard let b = t.before([post]) else { continue }; t = b }
            guard !t.isEmpty, t.count <= 5 else { continue }
            if allSessions.contains(t.key) || pronouns.contains(t.key) { return .status(target: nil) }
            guard looksKnown(t.text, known: known) else { continue }
            return .status(target: cleanTarget(t).text)
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
                default:
                    // "Tell blog to stop what it's doing": the whole session stops.
                    if p.keys.first == "stop", p.count > 1, !CommandParser.stopsOneThing(p.keys) {
                        return .stop(target: target.map { cleanTarget(Words($0)).text }, now: CommandParser.saysNow(p.text))
                    }
                }
            }
        }
        // "Billing service, stop what you're doing", the comma lost.
        if let (name, p) = w.splitAtKnownSession(known), p.keys.first == "stop", !CommandParser.stopsOneThing(p.keys) {
            return .stop(target: cleanTarget(name).text, now: CommandParser.saysNow(p.text))
        }
        // "End" stops a session it names. "Cancel billing" may mean its request, so cancel
        // stops only what is plainly the session: "cancel what finebrief is doing", "the docs site session".
        let verb = w.keys.first ?? ""
        guard var t = w.after(["stop", "halt", "pause", "shut down", "kill", "cancel", "end"]), !t.isEmpty, t.count <= 6 else { return nil }
        if t.keys.last == "please", t.count > 1 { t = t.slice(0..<(t.count - 1)) }
        var plainlyTheSession = t.keys.last == "session"
        // "what finebrief is doing", "everything on refund rounding": the session.
        if let r = t.after(["what", "everything on", "everything in", "all the work on", "the work on", "work on"]), !r.isEmpty {
            t = r
            plainlyTheSession = true
        }
        if let r = t.before(["is doing", "'s doing", "is working on", "is up to", "doing"]), !r.isEmpty { t = r }

        if verb == "cancel" {
            guard !known.isEmpty, looksKnown(t.text, known: known), plainlyTheSession else { return nil }
        }
        // "Kill billing service logs" is about logs: these need a session's whole name.
        if ["end", "kill"].contains(verb) || w.keys.starts(with: ["shut", "down"]) {
            guard isExactName(cleanTarget(t).text, known: known) else { return nil }
        }
        var now = false
        if let b = t.before(nowWords) { t = b; now = true }
        // "billing for a sec": the session is the longest name it starts with.
        if t.count > 1, !isExactName(t.text, known: known),
           let n = (1..<t.count).reversed().first(where: { isExactName(t.slice(0..<$0).text, known: known) }) {
            t = t.slice(0..<n)
        }
        if t.isEmpty || ["it", "that", "this", "talking"].contains(t.key) { return .quiet }
        if everyoneWords.contains(t.key) { return .stopAll }
        if pronouns.contains(t.key) { return .stop(target: nil, now: now) }
        guard looksKnown(t.text, known: known) else { return nil }
        return .stop(target: cleanTarget(t).text, now: now)
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

    /// "start a new session in", "open claude in", "spin up a claude session for", ...
    static let startShapes: [String] = {
        let verbs = ["start", "open", "launch", "spin up", "create", "begin", "fire up", "kick off"]
        let things = ["a session", "a new session", "new session", "claude", "a claude session", "a new claude session",
                      "new claude session", "a new one", "a new claude"]
        let preps = ["in", "for", "on"]
        var out = verbs.flatMap { v in things.flatMap { t in preps.map { "\(v) \(t) \($0)" } } }
        out += ["new session in", "new session for", "new claude session for", "new claude session in",
                "begin work in", "start work in", "start working in"]
        return out
    }()
    /// startShapes as words, longest first, split once.
    static let startShapeWords: [[String]] = startShapes.sorted { $0.count > $1.count }.map { $0.split(separator: " ").map(String.init) }

    private static func start(_ w: Words, known: [String]) -> Command? {
        guard let rest = w.after(split: startShapeWords) else { return nil }
        guard !rest.isEmpty else { return .unknown }
        // The project is a known name: what follows is the prompt ("on the refund bug").
        if let (p, after) = rest.splitAtKnown(known) {
            var pr = after
            while let f = pr.keys.first, ["to", "and", "on", "for", "folder", "project", "then", "with"].contains(f) {
                pr = pr.slice(1..<pr.count)
            }
            pr = pr.trimmingPromptFillers()
            return .start(project: p.text, prompt: pr.isEmpty ? nil : pr.text)
        }
        if let (p, prompt) = rest.split(at: ["to", "and"]), !p.isEmpty {
            let pr = prompt.trimmingPromptFillers()
            return .start(project: cleanTarget(p).text, prompt: pr.isEmpty ? nil : pr.text)
        }
        return .start(project: cleanTarget(rest).text, prompt: nil)
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
        // have billing P, make the blog P. With "it" these are too often not for a
        // session at all ("make it so", "have it ready by five"): the model decides.
        if let rest = w.after(["have", "make"]), rest.count >= 2, !pronouns.contains(rest.keys[0]) {
            var t: Words?
            if let (k, _) = rest.splitAtKnownSession(known) { t = k }
            // The start of a name ("make billing stop" for billing service).
            else if let n = (1...min(3, rest.count - 1)).reversed().first(where: { startsKnownName(rest.slice(0..<$0), known: known) }) {
                t = rest.slice(0..<n)
            }
            if let t, let c = sendOrStop(target: t, prompt: rest.slice(t.count..<rest.count), known: known) { return c }
        }
        // let X know P
        if let rest = w.after(["let"]), let (t, p) = rest.split(at: ["know"]), !t.isEmpty, looksKnown(t.text, known: known) {
            return make(target: t, prompt: p, known: known)
        }
        // I want X to P, I need X to P
        if let rest = w.after(["i want", "i need", "i'd like", "i would like"]), let (t, p) = rest.split(at: ["to"]),
           !t.isEmpty, looksKnown(t.text, known: known) {
            return sendOrStop(target: t, prompt: p, known: known)
        }
        // can X P, could the X session P: a known name right after. "Will" and "would"
        // ask whether ("will the blog be done soon"), so they are left to the model.
        if let rest = w.after(["can", "could"]), let (t, p) = rest.splitAtKnownSession(known),
           !p.isEmpty, p.keys.first != "you" {
            return sendOrStop(target: t, prompt: p, known: known)
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
            // "Billing, working on?": a status question that lost its "what's", not a prompt.
            if statusTails.contains(p.key) { return .status(target: Words(t.text).text) }
            return make(target: t, prompt: p, known: known)
        }
        // send P to X
        if let rest = w.after(["send"]), let i = rest.keys.lastIndex(of: "to"), i > 0, i < rest.count - 1 {
            return make(target: rest.slice((i + 1)..<rest.count), prompt: rest.slice(0..<i), known: known)
        }
        // P for X: a question or ask that ends with a session's whole name ("what else
        // should we do for kobi"). Only an exact name counts, so "wait for it" doesn't.
        // Names are often plain words ("the launch", "the wedding"), and "what's the plan
        // for the launch" may not be meant for a session, so Kobi reads it back first.
        if let i = w.keys.lastIndex(of: "for"), i >= 2, i < w.count - 1 {
            let t = w.slice((i + 1)..<w.count)
            if isExactName(t.text, known: known), case .send(let target?, let prompt)? = make(target: t, prompt: w.slice(0..<i), known: known) {
                return .confirmSend(target: target, prompt: prompt)
            }
        }
        return nil
    }

    /// Only a session's name ("the blog", "billing"), with nothing else in it ("blog to say" is not).
    static func plainName(_ w: Words, known: [String]) -> Bool {
        let t = cleanTarget(w)
        return !t.isEmpty && !t.keys.contains("to") && (isExactName(t.text, known: known) || startsKnownName(t, known: known))
    }

    /// The words are one of the known names, whole (an optional "the" and "session" aside).
    static func isExactName(_ text: String, known: [String]) -> Bool {
        let t = nameWords(text)
        return !t.isEmpty && known.contains { nameWords($0) == t }
    }

    /// A prompt for a named session, unless it is about stopping or waiting: a stop
    /// said this way ("make billing stop") is a stop, and the rest of those, and a
    /// question about finishing ("be done", "finish"), go to the model.
    private static func sendOrStop(target t: Words, prompt p: Words, known: [String]) -> Command? {
        let target = cleanTarget(t).text
        switch p.key {
        case "stop", "stop working": return .stop(target: target, now: false)
        case "stop now", "stop right now", "stop immediately": return .stop(target: target, now: true)
        default: break
        }
        if let f = p.keys.first, ["stop", "pause", "halt", "wait", "be", "finish", "finished", "done", "hold"].contains(f) { return nil }
        return p.isEmpty ? nil : make(target: t, prompt: p, known: known)
    }

    private static func make(target: Words, prompt: Words, known: [String]) -> Command? {
        let t = Words(target.text)   // drops a trailing comma or colon
        let named = !t.isEmpty && !pronouns.contains(t.key)
        if named && !looksKnown(t.text, known: known) { return nil }
        let p = prompt.trimmingPromptFillers()
        guard !p.isBlankPrompt else { return .unknown }
        return .send(target: named ? cleanTarget(t).text : nil, prompt: p.text)
    }
}
