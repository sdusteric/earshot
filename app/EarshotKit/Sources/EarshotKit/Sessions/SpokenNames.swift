import Foundation

/// How sessions are said out loud. A port of speak.sh, so the app and the
/// plugin name a session the same way.
public enum SpokenNames {
    /// speak.sh's proj: the git root's folder, with _ . - as spaces and
    /// camelCase split. The home folder is "your home folder".
    public static func project(cwd: String, home: String, isGitRoot: (String) -> Bool) -> String {
        var dir = (cwd as NSString).standardizingPath
        var root = dir
        while dir != "/" && !dir.isEmpty {
            if isGitRoot(dir) { root = dir; break }
            dir = (dir as NSString).deletingLastPathComponent
        }
        if root == (home as NSString).standardizingPath { return "your home folder" }
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

    /// The shortest name that is unique among these sessions: the project
    /// when it is the only one there; else "the <label> session" when no
    /// other session has that label; else "<label> in <project>". Untitled
    /// sessions that share a folder go by age: "the older blog session" and
    /// "the newer blog session", or "the first blog session" and on for three
    /// or more (oldest first, or as listed when a start time is missing).
    public static func names(_ entries: [Entry]) -> [String: String] {
        var out = baseNames(entries)
        for (project, group) in Dictionary(grouping: entries.filter { out[$0.id] == $0.project }, by: \.project)
        where group.count > 1 {
            let known = group.allSatisfy { $0.started != nil }
            let aged = known ? group.enumerated().sorted { ($0.element.started!, $0.offset) < ($1.element.started!, $1.offset) }
                .map(\.element) : group
            for (i, e) in aged.enumerated() {
                let place = known && aged.count == 2 ? (i == 0 ? "older" : "newer")
                    : i < places.count ? places[i] : "number \(i + 1)"
                out[e.id] = "the \(place) \(project) session"
            }
        }
        return out
    }

    private static func baseNames(_ entries: [Entry]) -> [String: String] {
        var out: [String: String] = [:]
        for e in entries {
            let others = entries.filter { $0.id != e.id }
            let twins = others.filter { $0.project == e.project }.count
            if e.title.isEmpty || e.label.isEmpty || twins == 0 {
                out[e.id] = e.project
                continue
            }
            let clash = others.contains { $0.label.lowercased() == e.label.lowercased() }
            out[e.id] = clash ? "\(e.label) in \(e.project)" : "the \(e.label) session"
        }
        return out
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
