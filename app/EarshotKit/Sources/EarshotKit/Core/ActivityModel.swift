import Foundation

/// The sessions as the Activity window speaks of them: the recap, their
/// order, and one name for each session.
public struct ActivitySessions: Sendable {
    /// A session the plugin reported.
    public struct Known: Sendable, Equatable {
        public let id: String
        public let name: String
        public let state: SessionState

        public init(id: String, name: String, state: SessionState) {
            self.id = id; self.name = name; self.state = state
        }

        public init(_ s: SessionInfo) { self.init(id: s.id, name: s.name, state: s.state) }
    }

    /// A session Claude Code itself lists, with its own view of what it is doing.
    public struct Live: Sendable, Equatable {
        public let id: String
        public let name: String
        public let busy: Bool
        public let waiting: Bool

        public init(id: String, name: String, busy: Bool, waiting: Bool) {
            self.id = id; self.name = name; self.busy = busy; self.waiting = waiting
        }

        public init(_ s: LiveSession) { self.init(id: s.id, name: s.name, busy: s.busy, waiting: s.waiting) }
    }

    /// One sentence of the recap and the session it is about.
    public struct RecapLine: Sendable, Equatable {
        public let id: String
        public let sentence: String
    }

    public let known: [Known]
    public let live: [Live]
    /// Today's history, newest last.
    public let history: [HistoryEntry]

    public init(known: [Known], live: [Live], history: [HistoryEntry]) {
        self.known = known; self.live = live; self.history = history
    }

    public static func title(_ name: String) -> String { name.prefix(1).uppercased() + name.dropFirst() }

    /// One name per session everywhere in the window: the plugin's, then
    /// the name today's lines used, then Claude Code's own label.
    public func displayName(_ id: String) -> String {
        known.first { $0.id == id }?.name
            ?? history.last { $0.session == id && $0.sessionName != nil }?.sessionName
            ?? live.first { $0.id == id }?.name
            ?? "session"
    }

    /// The sessions the recap speaks about, in its order, at most three: who
    /// needs you, then who is stuck or failed, then who finished. Working
    /// sessions are a count, not a name (see `workingCount`).
    public var recapLines: [RecapLine] {
        let order: [SessionState] = [.needs, .reply, .stuck, .failed, .done]
        let fromPlugin = known
            .filter { order.contains($0.state) }
            .sorted { (order.firstIndex(of: $0.state) ?? 9) < (order.firstIndex(of: $1.state) ?? 9) }
            .map { s -> RecapLine in
                let n = Self.title(displayName(s.id))
                let verb = switch s.state {
                case .needs: "needs you."
                case .reply: "is waiting on your answer."
                case .stuck: "might be stuck."
                case .failed: "hit an error."
                default: "finished."
                }
                return RecapLine(id: s.id, sentence: "\(n) \(verb)")
            }
        // Claude Code says it waits on you but the plugin hasn't (a blocked
        // background session, or the plugin is muted): that comes first.
        let pluginNeeds = Set(known.filter { $0.state == .needs || $0.state == .reply }.map(\.id))
        let waitingOnly = live.filter { $0.waiting && !pluginNeeds.contains($0.id) }
            .map { RecapLine(id: $0.id, sentence: "\(Self.title(displayName($0.id))) needs you.") }
        if !fromPlugin.isEmpty {
            let rest = fromPlugin.filter { line in !waitingOnly.contains { $0.id == line.id } }
            let isNeed: (RecapLine) -> Bool = { line in
                known.first { $0.id == line.id }.map { [.needs, .reply].contains($0.state) } ?? false
            }
            let needs = rest.prefix(while: isNeed)
            return Array((Array(needs) + waitingOnly + rest.dropFirst(needs.count)).prefix(3))
        }
        // The plugin hasn't reported yet: what Claude Code itself says.
        return Array(waitingOnly.prefix(3))
    }

    /// Sessions working now, by the plugin's account, else Claude Code's.
    public var workingCount: Int {
        let knownIDs = Set(known.map(\.id))
        let ids = Set(known.filter { $0.state == .working }.map(\.id))
            .union(live.filter { $0.busy && !knownIDs.contains($0.id) }.map(\.id))
        return ids.count
    }

    /// The recap and, after it, how many sessions are working: what Say the Recap says.
    public var spokenRecap: String {
        let n = workingCount
        guard n > 0 else { return recap }
        let count = n == 1 ? "One session is working." : "\(n) sessions are working."
        return recapLines.isEmpty ? count : "\(recap) \(count)"
    }

    /// Who needs you first, then who is stuck or finished: one short sentence each.
    public var recap: String {
        let parts = recapLines.map(\.sentence)
        if !parts.isEmpty { return parts.joined(separator: " ") }
        return known.isEmpty && live.isEmpty ? "No Claude Code sessions are open." : "Nothing needs you right now."
    }

}

extension SessionInfo {
    /// A session Claude Code lists that the plugin has not reported, in the
    /// plugin's terms: waiting on you, working, or open.
    public init(live s: LiveSession, now: Date = Date()) {
        let state = s.state ?? (s.waiting ? .needs : s.busy ? .working : .open)
        self.init(id: s.id, name: s.name, state: state, detail: s.detail, updated: s.since ?? now,
                  project: s.project, title: s.title)
    }

    /// The panel's sessions: the plugin's, then the ones only `claude agents`
    /// lists (without the plugin, that is all of them), all ranked so those
    /// waiting on you come first, then stuck or failed, then working. The panel
    /// shows only the first few, so what needs you is never below the cut.
    public static func panelList(known: [SessionInfo], live: [LiveSession], now: Date = Date()) -> [SessionInfo] {
        let ids = Set(known.map(\.id))
        let rank: (SessionInfo) -> Int = { s in
            switch s.state {
            case .needs, .reply: 0
            case .stuck, .failed: 1
            case .working: 2
            default: 3
            }
        }
        let extra = live.filter { !ids.contains($0.id) }.map { SessionInfo(live: $0, now: now) }
        return (known + extra).enumerated()
            .sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
    }
}

extension HistoryEntry {
    /// A line that waits on you: a "needs you" line, or one that ends by asking
    /// something ("Want one more round, or ship it?"), which the plugin sends
    /// as a finished turn.
    public var asksYou: Bool {
        guard kind == .said else { return false }
        if lineKind == .need || lineKind == .reply { return true }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("?")
    }
}
