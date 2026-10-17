import Foundation

/// What changed while you were away from the Mac (locked or asleep), said as
/// one line when you come back: "While you were away: Blog needs you.
/// Billing service finished."
public struct AwayRecap: Sendable {
    /// Away for less than this, nothing is said.
    public static let minAway: TimeInterval = 10 * 60
    static let maxSessions = 4

    /// What happened to a session, in the order the recap says them.
    public enum Change: Int, Sendable, Comparable {
        case needs, failed, stuck, finished
        public static func < (a: Change, b: Change) -> Bool { a.rawValue < b.rawValue }
    }

    public struct Recap: Sendable, Equatable {
        public let text: String
        /// The sessions it names, so their held lines are not said again.
        public let sessions: Set<String>
        /// When you left.
        public let since: Date
    }

    private struct Note {
        let change: Change
        let name: String?
        let at: Date
    }

    public private(set) var leftAt: Date?
    /// The latest change of each session while you were away.
    private var notes: [String: Note] = [:]

    public init() {}

    /// The Mac locked or went to sleep. A second call while away keeps the first time.
    public mutating func left(at date: Date) {
        guard leftAt == nil else { return }
        leftAt = date
        notes = [:]
    }

    /// A line from a session arrived, said or not. Only lines while you are
    /// away count, and only the ones that change something.
    public mutating func note(_ line: SpokenLine) {
        guard let leftAt, line.received >= leftAt, !line.session.isEmpty,
              let change = Self.change(for: line) else { return }
        notes[line.session] = Note(change: change, name: line.name, at: line.received)
    }

    /// What a line says changed, or nil for progress updates and Kobi's own lines.
    static func change(for line: SpokenLine) -> Change? {
        if line.asksYou { return .needs }
        switch line.kind {
        case .done: return .finished
        case .alert: return line.text.localizedCaseInsensitiveContains("error") ? .failed : .stuck
        default: return nil
        }
    }

    /// You came back. Returns the recap to say, or nil when you were away for
    /// less than minAway or nothing changed. `states` is each session's state
    /// now: a session that went back to work, or was answered, is not news.
    public mutating func back(at now: Date, states: [String: SessionState], names: [String: String]) -> Recap? {
        defer { leftAt = nil; notes = [:] }
        guard let leftAt, now.timeIntervalSince(leftAt) >= Self.minAway else { return nil }
        var items: [(session: String, change: Change, name: String, at: Date)] = []
        for (session, note) in notes {
            guard let change = Self.current(note.change, state: states[session]) else { continue }
            let name = note.name ?? names[session] ?? "a session"
            items.append((session, change, name, note.at))
        }
        guard !items.isEmpty else { return nil }
        items.sort { ($0.change, $0.at) < ($1.change, $1.at) }
        let text = Self.sentence(items.map { ($0.name, $0.change) })
        return Recap(text: text, sessions: Set(items.map(\.session)), since: leftAt)
    }

    /// The same, from the sessions as the store lists them. A wait you
    /// dismissed in Activity reads as open, as it does there, so the recap
    /// never says a dismissed session needs you. A wait that began after the
    /// dismissal is news again.
    public mutating func back(at now: Date, sessions: [SessionInfo], dismissals: Dismissals) -> Recap? {
        let list = dismissals.apply(sessions)
        let states = Dictionary(list.map { ($0.id, $0.state) }, uniquingKeysWith: { a, _ in a })
        let names = Dictionary(list.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        return back(at: now, states: states, names: names)
    }

    /// The change as it stands, given the session's state now (nil: unknown).
    /// nil when it is no longer news.
    static func current(_ change: Change, state: SessionState?) -> Change? {
        switch state {
        case .working, .open: return nil   // back at work: answered, or on its way again
        case .failed where change == .stuck: return .failed
        case .stuck where change == .failed: return .stuck
        default: return change
        }
    }

    /// "While you were away: Blog needs you. Docs and billing service finished."
    /// Sessions past the first few are counted, not named.
    static func sentence(_ items: [(name: String, change: Change)]) -> String {
        let named = items.prefix(maxSessions)
        var parts: [String] = []
        for change in [Change.needs, .failed, .stuck, .finished] {
            var names: [String] = []
            for item in named where item.change == change && !names.contains(item.name) { names.append(item.name) }
            guard !names.isEmpty else { continue }
            parts.append(upperFirst(list(names)) + " " + phrase(change, plural: names.count > 1) + ".")
        }
        if items.count > maxSessions { parts.append("And \(items.count - maxSessions) more.") }
        return "While you were away: " + parts.joined(separator: " ")
    }

    private static func phrase(_ change: Change, plural: Bool) -> String {
        switch change {
        case .needs: plural ? "need you" : "needs you"
        case .failed: "hit an error"
        case .stuck: "might be stuck"
        case .finished: "finished"
        }
    }

    /// "a", "a and b", "a, b and c".
    private static func list(_ names: [String]) -> String {
        guard names.count > 1 else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
    }

    private static func upperFirst(_ s: String) -> String { s.prefix(1).uppercased() + s.dropFirst() }
}

/// The recap's state, shared by the socket loop and the lock and sleep events.
actor AwayBook {
    private var recap = AwayRecap()
    func left(at date: Date) { recap.left(at: date) }
    func note(_ line: SpokenLine) { recap.note(line) }
    func back(at date: Date, sessions: [SessionInfo], dismissals: Dismissals) -> AwayRecap.Recap? {
        recap.back(at: date, sessions: sessions, dismissals: dismissals)
    }
}
