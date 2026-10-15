import Foundation

/// One turn of a session's conversation, as the session view shows it:
/// what you typed, what Claude said, and a short note of the work between.
public struct SessionTurn: Sendable, Equatable, Identifiable {
    /// `note`: a background job's status line, which may quote you or Claude.
    public enum Role: Sendable, Equatable { case you, claude, work, note }
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

    /// The last `limit` turns of the file. It reads the file's tail, starting
    /// with `tailBytes` and reading further back (up to 32 MB) while the tail
    /// holds fewer than a few things said: screenshots and long tool output can
    /// fill megabytes between two lines of conversation.
    public static func recent(_ url: URL, limit: Int = 12, tailBytes: Int = 600_000) -> Recent? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        var tail = UInt64(tailBytes)
        while true {
            let start = size > tail ? size - tail : 0
            try? h.seek(toOffset: start)
            guard let data = try? h.readToEnd() else { return nil }
            var lines = data.split(separator: UInt8(ascii: "\n"))
            // A read from the middle starts inside a line.
            if start > 0, !lines.isEmpty { lines.removeFirst() }
            let r = parse(lines.map { Data($0) }, limit: limit)
            let said = r.turns.filter { $0.role != .work }.count
            if start == 0 || said >= min(limit, 6) || tail >= 32_000_000 { return r }
            tail *= 4
        }
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

    /// A background session (a job) keeps no transcript in the projects folder:
    /// it has a folder under ~/.claude/jobs, named by the first 8 characters of
    /// its ID, with state.json (what it needs from you) and timeline.jsonl (its
    /// progress notes). Read as status notes, and the need as the question.
    public static func job(sessionID: String, limit: Int = 30,
                           home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Recent? {
        guard sessionID.count >= 8, !sessionID.contains("/") else { return nil }
        let dir = home.appending(path: ".claude/jobs/\(sessionID.prefix(8))", directoryHint: .isDirectory)
        let state = (try? Data(contentsOf: dir.appending(path: "state.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let timeline = (try? Data(contentsOf: dir.appending(path: "timeline.jsonl")))?
            .split(separator: UInt8(ascii: "\n")) ?? []
        guard state != nil || !timeline.isEmpty else { return nil }
        var turns: [SessionTurn] = []
        for (i, line) in timeline.enumerated() {
            guard let o = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let detail = (o["detail"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !detail.isEmpty, turns.last?.text != detail else { continue }
            // A note the next one repeats and finishes ("...the original rsv", then "...rsvp") is dropped.
            if let prev = turns.last, detail.hasPrefix(prev.text) { turns.removeLast() }
            turns.append(SessionTurn(id: "job-\(i)", role: .note, text: detail, at: (o["at"] as? String).flatMap(date)))
        }
        var asked: AskedQuestion?
        if state?["state"] as? String == "blocked",
           let needs = (state?["needs"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !needs.isEmpty {
            asked = AskedQuestion(question: needs.prefix(1).uppercased() + needs.dropFirst(), options: [])
        }
        return Recent(turns: Array(turns.suffix(limit)), asked: asked)
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
        case "ToolSearch", "Skill": return "loaded tools"
        default:
            // "mcp__computer-use__screenshot": the server says enough.
            if name.hasPrefix("mcp__") {
                let server = String(name.dropFirst(5)).components(separatedBy: "__").first ?? name
                return "used \(server.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " "))"
            }
            return "used \(name)"
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

    /// Format styles are values, so one pair serves every read (a new
    /// ISO8601DateFormatter per line cost more than the JSON).
    private static let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let whole = Date.ISO8601FormatStyle()

    static func date(_ s: String) -> Date? {
        (try? fractional.parse(s)) ?? (try? whole.parse(s))
    }
}
