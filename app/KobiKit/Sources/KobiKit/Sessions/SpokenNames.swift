import Foundation

/// How sessions are named, shown and said. The project and label rules are
/// ports of speak.sh; the names are Kobi's own (see `names`), and the
/// plugin's lines are said with them (see `renamed`).
public enum SpokenNames {
    /// speak.sh's proj: the git root's folder, with _ . - as spaces and
    /// camelCase split. The home folder is "home" (the plugin says "your home folder").
    public static func project(cwd: String, home: String, isGitRoot: (String) -> Bool) -> String {
        var dir = (cwd as NSString).standardizingPath
        var root = dir
        while dir != "/" && !dir.isEmpty {
            if isGitRoot(dir) { root = dir; break }
            dir = (dir as NSString).deletingLastPathComponent
        }
        if root == (home as NSString).standardizingPath { return "home" }
        let base = (root as NSString).lastPathComponent
        var out = ""
        var prev: Character?
        for c in base {
            let ch: Character = "_.-".contains(c) ? " " : c
            if let p = prev, p.isLowercase, ch.isUppercase { out.append(" ") }
            out.append(ch)
            prev = ch
        }
        return out
    }

    public static func project(cwd: String) -> String {
        project(cwd: cwd, home: NSHomeDirectory()) { FileManager.default.fileExists(atPath: $0 + "/.git") }
    }

    /// The plugin's project, as Kobi says it: "your home folder" is "home".
    public static func project(plugin: String) -> String {
        plugin.lowercased() == "your home folder" ? "home" : plugin
    }

    static let verbs: Set<String> = ["fix", "add", "create", "make", "update", "build", "write", "check", "debug",
                                     "refactor", "implement"]
    static let articles: Set<String> = ["a", "an", "the"]
    static let stops: Set<String> = ["for", "with", "and", "to", "in", "on", "of", "vs"]

    /// The title as speak.sh reads it: _ / - as spaces, a trailing " session" dropped.
    static func plain(_ title: String) -> String {
        var t = title.map { "_/-".contains($0) ? " " : $0 }.reduce(into: "") { $0.append($1) }
        if t.lowercased().hasSuffix(" session") { t = String(t.dropLast(" session".count)) }
        return t
    }

    /// speak.sh's label(): 1 to 3 words for a title.
    public static func ruleLabel(_ title: String) -> String {
        let w = plain(title).split(separator: " ").map(String.init)
        if w.count <= 3 { return w.joined(separator: " ") }
        var out: [String] = []
        for (i, word) in w.enumerated() {
            let lw = word.lowercased()
            if i == 0 && verbs.contains(lw) { continue }
            if articles.contains(lw) { continue }
            if !out.isEmpty && stops.contains(lw) { break }
            out.append(word)
            if out.count == 3 { break }
        }
        return out.isEmpty ? w.prefix(3).joined(separator: " ") : out.joined(separator: " ")
    }

    public struct Entry: Sendable, Equatable {
        public let id: String
        public let project: String
        public let title: String
        public let label: String
        public let started: Date?
        public init(id: String, project: String, title: String, label: String, started: Date? = nil) {
            self.id = id; self.project = project; self.title = title; self.label = label; self.started = started
        }
    }

    static let places = ["first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth", "tenth"]

    /// Words a topic never uses: they say nothing about the work.
    static let filler: Set<String> = ["session", "sessions"]
    /// Words that make a poor topic on their own: a command would take them
    /// for its own words ("reflow status" reads as a status question), or
    /// they say too little ("what's", "project").
    static let weak: Set<String> = [
        "status", "done", "doing", "going", "finished", "next", "new", "stop", "start", "check", "update", "yes",
        "no", "project", "projects", "work", "stuff", "things", "misc", "quick", "small", "more", "some", "help",
        "what", "what's", "whats", "how", "why", "where", "when", "which", "who", "it", "this", "that", "my", "our",
        "your", "page", "question", "questions", "one", "two",
    ]

    /// Topics to tell a session apart by, shortest first, from its title: the
    /// first word that says something, then two words from there, then up to
    /// four. "Project status and milestones" gives "milestones" and "project
    /// status milestones"; "What's next" gives "what's next". Leading verbs,
    /// articles, joining words and the folder's own name are left out.
    static func topics(_ title: String, project: String) -> [String] {
        let projectWords = Set(project.lowercased().split(separator: " ").map(String.init)
                               + [project.lowercased().replacingOccurrences(of: " ", with: "")])
        var words: [String] = []
        for (i, raw) in plain(title).split(separator: " ").enumerated() {
            let w = raw.trimmingCharacters(in: CharacterSet(charactersIn: ".,:;!?()[]{}\"\u{201C}\u{201D}"))
                .replacingOccurrences(of: "\u{2019}", with: "'")
            let lw = w.lowercased()
            guard w.contains(where: { $0.isLetter || $0.isNumber }) else { continue }
            if i == 0 && verbs.contains(lw) { continue }
            if articles.contains(lw) || stops.contains(lw) || filler.contains(lw) || projectWords.contains(lw) { continue }
            words.append(spokenCase(w))
        }
        guard !words.isEmpty else { return [] }
        var out: [String] = []
        if let first = words.firstIndex(where: { !weak.contains($0.lowercased()) }) {
            out.append(words[first])
            out.append(words[first...].prefix(2).joined(separator: " "))
        } else {
            // Only weak words: never one alone ("what's next", not "what's").
            out.append(words.prefix(2).joined(separator: " "))
        }
        out.append(words.prefix(4).joined(separator: " "))
        var seen = Set<String>()
        return out.filter { seen.insert($0.lowercased()).inserted }
    }

    /// A title word as a name says it: lowercase, unless it is an acronym or
    /// has capitals inside ("UX", "iOS", "RSS").
    static func spokenCase(_ w: String) -> String {
        let keep = w.dropFirst().contains(where: \.isUppercase)
        return keep ? w : w.lowercased()
    }

    /// The first letter upper case, as a name is shown and said ("Blog",
    /// "Home"), unless the word is like "iOS".
    public static func capitalized(_ s: String) -> String {
        guard let f = s.first, f.isLowercase else { return s }
        if let second = s.dropFirst().first, second.isUppercase { return s }
        return f.uppercased() + s.dropFirst()
    }

    /// The name of every session: short, distinct, and the same shown or said.
    ///
    /// - The folder alone when no other session is there: "Blog", "Wedding", "Home".
    /// - When several share a folder, the folder and a topic from the session's
    ///   title: "Reflow retries", "Reflow docs". A word is added only while two
    ///   topics are the same.
    /// - One untitled session among them keeps the folder alone. Untitled
    ///   sessions that share a folder go by age: "Older blog" and "Newer blog",
    ///   or "First blog", "Second blog" and on for three or more (oldest first,
    ///   or as listed when a start time is missing). Titles that are the same go by age too.
    /// - A name in `keeping` stays while its session lives and no other session
    ///   has it already, so names do not change on a refresh. A new session
    ///   takes a name no other has, which may not be the shortest.
    ///   When two sessions in `keeping` have the same name, the one that
    ///   started first keeps it and the other is named again (a session with
    ///   no start time counts as newest, then the order listed).
    /// - A name in `remembered` (from an earlier launch, or a session that
    ///   closed and came back) is reused only when no name in `keeping` has
    ///   it, so a session back from earlier never renames one that has gone
    ///   by that name all along. Clashes among them go by age, as above.
    public static func names(_ entries: [Entry], keeping previous: [String: String] = [:],
                             remembered: [String: String] = [:]) -> [String: String] {
        let fresh = freshNames(entries)
        var out: [String: String] = [:]
        var taken = Set<String>()
        let oldestFirst = entries.enumerated().sorted { ($0.element.started ?? .distantFuture, $0.offset) < ($1.element.started ?? .distantFuture, $1.offset) }
            .map(\.element)
        for kept in [previous, remembered] {
            for e in oldestFirst {
                if let p = kept[e.id], out[e.id] == nil, taken.insert(key(p)).inserted { out[e.id] = p }
            }
        }
        for e in entries where out[e.id] == nil {
            let base = fresh[e.id] ?? capitalized(e.project)
            let options = [base, capitalized(e.project)]
                + topics(e.title, project: e.project).map { "\(capitalized(e.project)) \($0)" }
            var name = options.first { !taken.contains(key($0)) }
            if name == nil {
                // Nothing else tells it apart.
                var i = 2
                while taken.contains(key("\(base) \(i)")) { i += 1 }
                name = "\(base) \(i)"
            }
            out[e.id] = name
            taken.insert(key(name!))
        }
        return out
    }

    static func key(_ name: String) -> String { NameMatch.normalize(name) }

    /// The names for these sessions taken together, with nothing kept.
    private static func freshNames(_ entries: [Entry]) -> [String: String] {
        var out: [String: String] = [:]
        let groups = Dictionary(grouping: entries.enumerated(), by: { key($0.element.project) })
        for members in groups.values {
            let group = members.sorted { $0.offset < $1.offset }.map(\.element)
            guard let project = group.first?.project else { continue }
            let p = capitalized(project)
            if group.count == 1 { out[group[0].id] = p; continue }
            var options: [String: [String]] = [:]
            for e in group { options[e.id] = topics(e.title, project: project) }
            let titled = group.filter { !(options[$0.id] ?? []).isEmpty }
            let untitled = group.filter { (options[$0.id] ?? []).isEmpty }
            // The shortest topic for each, one step longer while two are the same.
            var level: [String: Int] = [:]
            func topic(_ e: Entry) -> String {
                let o = options[e.id] ?? []
                return o[min(level[e.id] ?? 0, o.count - 1)]
            }
            while true {
                let clashing = Dictionary(grouping: titled, by: { topic($0).lowercased() }).values.filter { $0.count > 1 }
                let bump = clashing.joined().filter { (level[$0.id] ?? 0) < (options[$0.id]?.count ?? 1) - 1 }
                if bump.isEmpty { break }
                for e in bump { level[e.id, default: 0] += 1 }
            }
            for same in Dictionary(grouping: titled, by: { topic($0).lowercased() }).values {
                if same.count == 1 {
                    out[same[0].id] = "\(p) \(topic(same[0]))"
                } else {
                    for (e, place) in byAge(same) { out[e.id] = "\(capitalized(place)) \(project) \(topic(e))" }
                }
            }
            if untitled.count == 1 {
                out[untitled[0].id] = p
            } else {
                for (e, place) in byAge(untitled) { out[e.id] = "\(capitalized(place)) \(project)" }
            }
        }
        return out
    }

    /// Each session with the word for its age: "older" and "newer" for two
    /// with start times, else "first", "second" and on, oldest first (or as listed).
    private static func byAge(_ group: [Entry]) -> [(Entry, String)] {
        let known = group.allSatisfy { $0.started != nil }
        let aged = known ? group.enumerated().sorted { ($0.element.started!, $0.offset) < ($1.element.started!, $1.offset) }
            .map(\.element) : group
        return aged.enumerated().map { i, e in
            (e, known && aged.count == 2 ? (i == 0 ? "older" : "newer") : i < places.count ? places[i] : "number \(i + 1)")
        }
    }

    /// A name the plugin made, said the new way: "the tax export session" is
    /// "Tax export", "your home folder" is "Home". Only for a session Kobi
    /// has not named yet.
    public static func tidy(_ pluginName: String) -> String {
        let n = pluginName.trimmingCharacters(in: .whitespaces)
        if n.lowercased() == "your home folder" { return "Home" }
        return capitalized(plainLabel(n) ?? n)
    }

    /// "tax export" in "the tax export session", else nil.
    static func plainLabel(_ who: String) -> String? {
        let lw = who.lowercased()
        guard lw.hasPrefix("the "), lw.hasSuffix(" session"), who.count > "the  session".count else { return nil }
        return String(who.dropFirst(4).dropLast(8))
    }

    /// The ways the plugin's lines say a session it calls `who`: as a speaker
    /// ("the tax export session needs your OK") and as the work ("still on
    /// tax export"). See session_names in speak.sh.
    public static func pluginForms(_ who: String) -> [String] {
        guard !who.isEmpty else { return [] }
        return [who] + (plainLabel(who).map { [$0] } ?? [])
    }

    /// Where the plugin's lines put a session's name (see `tell` in speak.sh):
    /// what comes before and after it, and whether that opens the line. A
    /// finished line is the session's own words after "From NAME: ", so
    /// nothing past that is touched.
    static let nameShapes: [(lead: String, tail: String, opens: Bool)] = [
        ("Hey, ", " ", true), ("Heads up, ", " ", true), ("Still on ", ",", true), ("From ", ": ", true),
        ("", " hit an error", true), (". ", " is still waiting", false),
    ]

    /// The plugin's line with the session called by Kobi's name, where the
    /// plugin puts a name: "Still on reflow, about 9 minutes in." becomes
    /// "Still on Reflow docs, about 9 minutes in." The same words anywhere
    /// else are left alone.
    public static func renamed(_ text: String, forms: [String], to name: String) -> String {
        for form in Set(forms).sorted(by: { ($0.count, $0) > ($1.count, $1) }) where !form.isEmpty && form != name {
            for shape in nameShapes {
                let options: String.CompareOptions = shape.opens ? [.caseInsensitive, .anchored] : .caseInsensitive
                guard let r = text.range(of: shape.lead + form + shape.tail, options: options) else { continue }
                let start = text.index(r.lowerBound, offsetBy: shape.lead.count)
                let end = text.index(start, offsetBy: form.count)
                return text.replacingCharacters(in: start..<end, with: name)
            }
        }
        return text
    }

    /// Claude Code names an untitled session after its folder and a short
    /// hex suffix ("blog-83"). That is not a title.
    public static func isDefaultName(_ name: String, cwd: String) -> Bool {
        let base = (cwd as NSString).lastPathComponent.lowercased()
        guard name.lowercased().hasPrefix(base + "-") else { return false }
        let suffix = name.dropFirst(base.count + 1)
        return (1...4).contains(suffix.count) && suffix.allSatisfy(\.isHexDigit)
    }
}
