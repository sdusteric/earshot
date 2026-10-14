import Foundation

/// One turn of a session's conversation, as the session view shows it:
/// what you typed, what Claude said, and a short note of the work between.
public struct SessionTurn: Sendable, Equatable, Identifiable {
    public enum Role: Sendable, Equatable { case you, claude, work }
    public let id: String
    public let role: Role
    /// For `.work`: "Ran 2 commands, edited about.md".
    public let text: String
    public let at: Date?

    public init(id: String, role: Role, text: String, at: Date?) {
        self.id = id; self.role = role; self.text = text; self.at = at
    }
}

/// A question Claude asked with AskUserQuestion and you haven't answered.
public struct AskedQuestion: Sendable, Equatable {
    public let question: String
    public let options: [String]

    public init(question: String, options: [String]) { self.question = question; self.options = options }
}

/// Reads a Claude Code session's transcript (the .jsonl file Claude Code keeps
/// under ~/.claude/projects). Read on demand for the session view, on the Mac;
/// nothing of it is logged or kept.
public enum SessionTranscript {
    public struct Recent: Sendable, Equatable {
        public let turns: [SessionTurn]
        public let asked: AskedQuestion?
    }

    /// Where Claude Code keeps the session's transcript: its folder with every
    /// character but letters and digits turned into "-", then the session ID.
    /// When that file is missing, any project folder holding the ID.
    public static func file(sessionID: String, cwd: String,
                            home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        guard !sessionID.isEmpty, !sessionID.contains("/") else { return nil }
        let projects = home.appending(path: ".claude/projects", directoryHint: .isDirectory)
        let slug = String(cwd.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
        let direct = projects.appending(path: slug).appending(path: "\(sessionID).jsonl")
        if FileManager.default.fileExists(atPath: direct.path) { return direct }
        let dirs = (try? FileManager.default.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? []
        return dirs.map { $0.appending(path: "\(sessionID).jsonl") }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// The last `limit` turns of the file, read from its last `tailBytes`.
    public static func recent(_ url: URL, limit: Int = 12, tailBytes: Int = 600_000) -> Recent? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        let start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        try? h.seek(toOffset: start)
        guard let data = try? h.readToEnd() else { return nil }
        var lines = data.split(separator: UInt8(ascii: "\n"))
        // A read from the middle starts inside a line.
        if start > 0, !lines.isEmpty { lines.removeFirst() }
        return parse(lines.map { Data($0) }, limit: limit)
    }

    public static func parse(_ lines: [Data], limit: Int = 12) -> Recent {
        var turns: [SessionTurn] = []
        var work: [String] = []
        var workID: String?
        var workAt: Date?
        var asked: (id: String, q: AskedQuestion)?
        var answered = Set<String>()

        func flushWork() {
            guard let id = workID, !work.isEmpty else { return }
            turns.append(SessionTurn(id: id, role: .work, text: summary(work), at: workAt))
            work = []; workID = nil; workAt = nil
        }

        for line in lines {
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let type = obj["type"] as? String, type == "user" || type == "assistant",
                  obj["isSidechain"] as? Bool != true, obj["isMeta"] as? Bool != true,
                  let message = obj["message"] as? [String: Any] else { continue }
            let id = obj["uuid"] as? String ?? UUID().uuidString
            let at = (obj["timestamp"] as? String).flatMap(date)
            if type == "user" {
                if let text = message["content"] as? String {
                    guard let said = typed(text) else { continue }
                    flushWork()
                    turns.append(SessionTurn(id: id, role: .you, text: said, at: at))
                } else if let blocks = message["content"] as? [[String: Any]] {
                    for b in blocks {
                        if b["type"] as? String == "tool_result", let use = b["tool_use_id"] as? String { answered.insert(use) }
                        if b["type"] as? String == "text", let text = b["text"] as? String, let said = typed(text) {
                            flushWork()
                            turns.append(SessionTurn(id: id, role: .you, text: said, at: at))
                        }
                    }
                }
                continue
            }
            for b in message["content"] as? [[String: Any]] ?? [] {
                switch b["type"] as? String {
                case "text":
                    guard let text = (b["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                          !text.isEmpty else { continue }
                    flushWork()
                    turns.append(SessionTurn(id: "\(id)-\(turns.count)", role: .claude, text: text, at: at))
                case "tool_use":
                    let name = b["name"] as? String ?? ""
                    let input = b["input"] as? [String: Any] ?? [:]
                    if name == "AskUserQuestion", let use = b["id"] as? String, let q = question(input) {
                        asked = (use, q)
                    }
                    if workID == nil { workID = "\(id)-work"; workAt = at }
                    work.append(step(name, input))
                default: continue
                }
            }
        }
        flushWork()
        let open = asked.flatMap { answered.contains($0.id) ? nil : $0.q }
        return Recent(turns: Array(turns.suffix(limit)), asked: open)
    }

    /// What you typed, or nil for what Claude Code itself put in your turn
    /// (slash command wrappers, reminders, interrupted-turn notes).
    static func typed(_ text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !t.hasPrefix("<"), !t.hasPrefix("[Request interrupted") else { return nil }
        return t
    }

    static func question(_ input: [String: Any]) -> AskedQuestion? {
        guard let first = (input["questions"] as? [[String: Any]])?.first,
              let q = first["question"] as? String else { return nil }
        let options = (first["options"] as? [[String: Any]] ?? []).compactMap { $0["label"] as? String }
        return AskedQuestion(question: q, options: options)
    }

    /// One tool call in a few words.
    static func step(_ name: String, _ input: [String: Any]) -> String {
        let file = (input["file_path"] as? String).map { ($0 as NSString).lastPathComponent }
        switch name {
        case "Bash": return "ran a command"
        case "Read": return file.map { "read \($0)" } ?? "read a file"
        case "Edit", "MultiEdit": return file.map { "edited \($0)" } ?? "edited a file"
        case "Write": return file.map { "wrote \($0)" } ?? "wrote a file"
        case "Grep", "Glob": return "searched the code"
        case "WebFetch", "WebSearch": return "looked on the web"
        case "Agent", "Task": return "started a helper"
        case "AskUserQuestion": return "asked you a question"
        case "TodoWrite": return "updated its plan"
        default: return "used \(name)"
        }
    }

    /// "Ran 3 commands, edited about.md and config.ts, read 2 files".
    static func summary(_ steps: [String]) -> String {
        var order: [String] = []
        var counts: [String: Int] = [:]
        for s in steps {
            if counts[s] == nil { order.append(s) }
            counts[s, default: 0] += 1
        }
        let plural = ["ran a command": "ran %d commands", "read a file": "read %d files", "edited a file": "edited %d files",
                      "wrote a file": "wrote %d files", "searched the code": "searched the code %d times",
                      "looked on the web": "looked on the web %d times", "started a helper": "started %d helpers"]
        let parts = order.prefix(4).map { s -> String in
            let n = counts[s] ?? 1
            if n > 1, let p = plural[s] { return String(format: p, n) }
            return s
        }
        var text = parts.joined(separator: ", ")
        if order.count > 4 { text += ", and more" }
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    private static func date(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }
}
