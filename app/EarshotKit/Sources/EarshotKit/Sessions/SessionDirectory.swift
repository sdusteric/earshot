import Foundation

public struct LiveSession: Sendable, Equatable, Identifiable {
    public let id: String
    public var pid: Int32?
    public var kind: String
    public var cwd: String
    public var project: String
    public var title: String
    public var label: String
    /// The shortest unique spoken name.
    public var name: String
    public var busy: Bool
    /// On a permission prompt or a question (Claude Code's own view).
    public var waiting: Bool
    /// From the plugin, when it reported one.
    public var state: SessionState?
    public var detail: String?
    public var since: Date?

    public var isBackground: Bool { kind == "background" }
}

public struct KnownProject: Sendable, Equatable {
    public let name: String
    public let path: String
    public let trusted: Bool
}

/// Matching what you said against what a session is called.
public enum NameMatch {
    public static func normalize(_ s: String) -> String {
        var w = s.lowercased().split { !$0.isLetter && !$0.isNumber && $0 != "'" }.map(String.init)
        if w.first == "the" { w.removeFirst() }
        if w.last == "session" { w.removeLast() }
        return w.joined(separator: " ")
    }

    /// 1 for the same name, about 0.9 when the words you said start the
    /// name ("billing" for "billing service"), else closeness of the letters
    /// with spaces ignored ("fine brief" and "finebrief" are the same).
    public static func score(_ spoken: String, _ candidate: String) -> Double {
        let a = normalize(spoken), b = normalize(candidate)
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        if a == b { return 1 }
        let sa = a.replacingOccurrences(of: " ", with: ""), sb = b.replacingOccurrences(of: " ", with: "")
        if sa == sb { return 0.99 }
        let aw = a.split(separator: " "), bw = b.split(separator: " ")
        if bw.starts(with: aw) { return 0.9 }
        let d = levenshtein(Array(sa), Array(sb))
        return max(0, 1 - Double(d) / Double(max(sa.count, sb.count)))
    }

    static func levenshtein(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count), cur = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            cur[0] = i
            for j in 1...b.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            swap(&prev, &cur)
        }
        return prev[b.count]
    }
}

/// Every open session, from `claude agents --json` and the plugin's
/// statuses, with the names Earshot says.
public actor SessionDirectory {
    public enum Match: Sendable, Equatable {
        case one(LiveSession)
        case several([LiveSession])
        case none
        /// No session named and no default: ask.
        case noTarget
    }

    static let threshold = 0.78
    static let lastSpokeWindow: TimeInterval = 120

    private let runner: any ClaudeRunner
    private let store: SessionStore
    private let labeler: Labeler
    private let claudeJSON: String
    private let clock: @Sendable () -> Date
    private var list: [LiveSession] = []
    private var lastSpoke: (id: String, at: Date)?
    private var refreshedAt: Date?
    /// False when the last `claude agents` check did not answer.
    public private(set) var lastRefreshSucceeded = true
    private var inflight: Task<Void, Never>?
    private let readFile: @Sendable (String) -> Data?
    private var claudeCache: (stamp: FileStamp, projects: [(path: String, trusted: Bool)])?
    private var projectNames: [String: String] = [:]

    private struct FileStamp: Equatable { var modified: Date?; var size: Int? }

    public init(runner: any ClaudeRunner, store: SessionStore, labeler: Labeler,
                claudeJSON: String = NSHomeDirectory() + "/.claude.json",
                clock: @escaping @Sendable () -> Date = Date.init,
                readFile: @escaping @Sendable (String) -> Data? = { FileManager.default.contents(atPath: $0) }) {
        self.runner = runner; self.store = store; self.labeler = labeler
        self.claudeJSON = claudeJSON; self.clock = clock; self.readFile = readFile
    }

    public var sessions: [LiveSession] { list }
    public func session(_ id: String) -> LiveSession? { list.first { $0.id == id } }

    /// Refreshes unless the list is younger than this: the wake word already
    /// refreshed it, so a command does not pay the 130 ms twice.
    public func refresh(ifOlderThan seconds: TimeInterval) async {
        if let t = inflight { await t.value; return }
        if let r = refreshedAt, clock().timeIntervalSince(r) < seconds { return }
        await refresh()
    }

    /// Reads `claude agents --json` (about 130 ms) and merges the plugin's view.
    /// A refresh that is already running is awaited, not repeated.
    public func refresh() async {
        if let t = inflight { await t.value; return }
        let t = Task { await self.performRefresh() }
        inflight = t
        await t.value
    }

    private func performRefresh() async {
        defer { inflight = nil }
        let r = await runner.run(["agents", "--json"], cwd: nil, timeout: .seconds(3))
        let succeeded = r.status == 0 && !r.timedOut
            && (try? JSONSerialization.jsonObject(with: r.stdout)) is [Any]
        let agents = succeeded ? AgentEntry.decodeList(r.stdout) : []
        let previous = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let reported = Dictionary(await store.sessions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var merged: [LiveSession] = []
        for a in agents {
            let info = reported[a.sessionId]
            let project = info?.project ?? projectName(a.cwd)
            let agentTitle = a.name.flatMap { SpokenNames.isDefaultName($0, cwd: a.cwd) ? nil : $0 } ?? ""
            let title = info?.title.flatMap { $0.isEmpty ? nil : $0 } ?? agentTitle
            let label = title.isEmpty ? "" : await labeler.label(session: a.sessionId, title: title)
            merged.append(LiveSession(id: a.sessionId, pid: a.pid, kind: a.kind, cwd: a.cwd, project: project, title: title,
                                      label: label, name: project, busy: a.isBusy, waiting: a.isWaiting,
                                      state: info?.state, detail: info?.detail, since: info?.since))
        }
        // Sessions only the plugin knows, when agents failed: a session that
        // died without a closed message must not linger as a ghost.
        for (id, info) in reported where !succeeded && !merged.contains(where: { $0.id == id }) {
            let old = previous[id]
            let title = info.title ?? ""
            let label = title.isEmpty ? "" : await labeler.label(session: id, title: title)
            merged.append(LiveSession(id: id, pid: old?.pid, kind: old?.kind ?? "unknown", cwd: old?.cwd ?? "", project: info.project ?? info.name,
                                      title: title, label: label, name: info.name, busy: info.state == .working,
                                      waiting: info.state == .needs, state: info.state,
                                      detail: info.detail, since: info.since))
        }
        let names = SpokenNames.names(merged.map { .init(id: $0.id, project: $0.project, title: $0.title, label: $0.label) })
        for i in merged.indices { merged[i].name = names[merged[i].id] ?? merged[i].project }
        list = merged
        lastRefreshSucceeded = succeeded
        if succeeded { refreshedAt = clock() }
    }

    private func projectName(_ cwd: String) -> String {
        if let n = projectNames[cwd] { return n }
        let n = SpokenNames.project(cwd: cwd)
        projectNames[cwd] = n
        return n
    }

    public func noteSpoke(about session: String) { lastSpoke = (session, clock()) }

    public func resolve(_ target: String?) -> Match {
        guard let target, !NameMatch.normalize(target).isEmpty else {
            if list.isEmpty { return .none }
            if list.count == 1 { return .one(list[0]) }
            if let l = lastSpoke, clock().timeIntervalSince(l.at) <= Self.lastSpokeWindow, let s = session(l.id) { return .one(s) }
            return .noTarget
        }
        return match(target, in: list)
    }

    /// After "Which one?": only the sessions that were offered.
    public func resolve(_ target: String, among ids: [String]) -> Match {
        let offered = list.filter { ids.contains($0.id) }
        if case .one(let s) = match(target, in: offered) { return .one(s) }
        // "the second one invoices": any word that picks out one label.
        let words = Set(NameMatch.normalize(target).split(separator: " ").map(String.init))
        let hits = offered.filter { s in
            [s.label, s.title].contains { name in
                NameMatch.normalize(name).split(separator: " ").contains { w in
                    words.contains { NameMatch.score($0, String(w)) >= 0.8 }
                }
            }
        }
        return hits.count == 1 ? .one(hits[0]) : (hits.isEmpty ? .none : .several(hits))
    }

    private func match(_ target: String, in sessions: [LiveSession]) -> Match {
        // "refund rounding in billing service"
        let t = NameMatch.normalize(target)
        if let r = t.range(of: " in ") {
            let label = String(t[..<r.lowerBound]), project = String(t[r.upperBound...])
            let hits = sessions.filter { NameMatch.score(project, $0.project) >= Self.threshold
                && max(NameMatch.score(label, $0.label), NameMatch.score(label, $0.title)) >= Self.threshold }
            if hits.count == 1 { return .one(hits[0]) }
        }
        // The name Earshot says a session by is unique, so saying it back picks that
        // session, even when another session shares its folder ("reflow" and
        // "Project status", both in reflow).
        let spoken = sessions.filter { !t.isEmpty && NameMatch.normalize($0.name) == t }
        if spoken.count == 1 { return .one(spoken[0]) }
        // In order: the project, the label, the title, the spoken name.
        for key in [\LiveSession.project, \.label, \.title, \.name] {
            let exact = sessions.filter { NameMatch.normalize($0[keyPath: key]) == t && !t.isEmpty }
            if exact.count == 1 { return .one(exact[0]) }
            if exact.count > 1 { return .several(exact) }
        }
        // Then the closest names.
        let scored = sessions.map { s in (s, [s.project, s.label, s.title, s.name].map { NameMatch.score(target, $0) }.max() ?? 0) }
        guard let best = scored.map(\.1).max(), best >= Self.threshold else { return .none }
        let top = scored.filter { $0.1 >= best - 0.02 }.map(\.0)
        return top.count == 1 ? .one(top[0]) : .several(top)
    }

    /// Names to boost in transcription: projects and labels, at most 50.
    public func vocabulary() -> [String] {
        var seen = Set<String>(), out: [String] = []
        for n in list.flatMap({ [$0.project, $0.label] }) + knownProjects().map(\.name) where !n.isEmpty {
            if seen.insert(n.lowercased()).inserted { out.append(n) }
        }
        return Array(out.prefix(50))
    }

    /// Folders Claude Code knows (from ~/.claude.json, with their trust) and
    /// the folders of open sessions.
    public func knownProjects() -> [KnownProject] {
        var out = claudeProjects().map { KnownProject(name: projectName($0.path), path: $0.path, trusted: $0.trusted) }
        for s in list where !s.cwd.isEmpty && !out.contains(where: { $0.path == s.cwd }) {
            out.append(KnownProject(name: s.project, path: s.cwd, trusted: true))
        }
        return out.sorted { $0.path < $1.path }
    }

    /// The folders in ~/.claude.json, parsed again only when the file's date or size changes.
    private func claudeProjects() -> [(path: String, trusted: Bool)] {
        let attrs = try? FileManager.default.attributesOfItem(atPath: claudeJSON)
        let stamp = FileStamp(modified: attrs?[.modificationDate] as? Date, size: (attrs?[.size] as? NSNumber)?.intValue)
        if let c = claudeCache, c.stamp == stamp { return c.projects }
        var found: [(path: String, trusted: Bool)] = []
        if attrs != nil, let data = readFile(claudeJSON),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let projects = root["projects"] as? [String: Any] {
            for (path, value) in projects {
                found.append((path, (value as? [String: Any])?["hasTrustDialogAccepted"] as? Bool ?? false))
            }
        }
        claudeCache = (stamp, found)
        return found
    }

    public func matchProject(_ spoken: String) -> KnownProject? {
        let scored = knownProjects().map { ($0, NameMatch.score(spoken, $0.name)) }.filter { $0.1 >= Self.threshold }
        guard let best = scored.max(by: { $0.1 < $1.1 }) else { return nil }
        // Two folders with the same name: prefer the one with a live session, then the shorter path.
        let ties = scored.filter { $0.1 == best.1 }.map(\.0)
        return ties.first { p in list.contains { $0.cwd == p.path } } ?? ties.min { $0.path.count < $1.path.count }
    }
}
