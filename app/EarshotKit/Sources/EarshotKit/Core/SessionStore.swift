import Foundation

public struct SessionInfo: Sendable, Equatable, Identifiable {
    public let id: String
    public var name: String
    public var state: SessionState
    public var detail: String?
    public var updated: Date
    public var project: String?
    public var title: String?
    /// When the session entered this state. Unlike updated, a repeat of the
    /// same state leaves it alone, so "at it for an hour" counts the whole run.
    public var since: Date = .distantPast
}

/// Open sessions, from the plugin's status messages. Sessions that need you
/// come first, as in the roll call.
///
/// The store also holds the name of every open session (`SpokenNames.names`),
/// given once and kept while the session lives, so the list, Activity, the
/// recap and the lines Earshot says all call a session the same thing. The
/// plugin's own name for it ("the tax export session") is kept only to find
/// it in the plugin's lines.
public actor SessionStore {
    /// Sessions quiet this long count as closed, as the plugin's live files do.
    public static let maxAge: TimeInterval = 6 * 3600

    private var byID: [String: SessionInfo] = [:]
    /// The name each session goes by.
    private var given: [String: String] = [:]
    /// The sessions as `claude agents` last listed them (see SessionDirectory).
    private var listed: [SpokenNames.Entry] = []
    private var lastSent: [String: Double] = [:]
    private var conts: [UUID: AsyncStream<[SessionInfo]>.Continuation] = [:]
    private let clock: @Sendable () -> Date

    public init(clock: @escaping @Sendable () -> Date = Date.init) { self.clock = clock }

    /// Applies a status. Returns the state the session had before, or nil
    /// when the status was older than one already applied and was ignored.
    @discardableResult
    public func apply(_ status: AppMessage.Status) -> SessionState? {
        if let sent = status.sent {
            if status.state != .closed, let last = lastSent[status.session], sent < last { return nil }
            lastSent[status.session] = max(sent, lastSent[status.session] ?? 0)
        }
        let before = byID[status.session]?.state
        if status.state == .closed {
            byID[status.session] = nil
            given[status.session] = nil
            listed.removeAll { $0.id == status.session }
        } else {
            let name = [status.name, status.project, byID[status.session]?.name]
                .compactMap { $0 }.first { !$0.isEmpty } ?? "a session"
            let old = byID[status.session]
            let now = clock()
            byID[status.session] = SessionInfo(id: status.session, name: name, state: status.state,
                                               detail: status.detail, updated: now,
                                               project: status.project ?? old?.project, title: status.title ?? old?.title,
                                               since: old.map { $0.state == status.state ? $0.since : now } ?? now)
            // A session `claude agents` has not listed yet is named now, beside the others.
            if given[status.session] == nil {
                given.merge(SpokenNames.names(namingEntries(), keeping: given)) { _, new in new }
            }
        }
        prune()
        let list = sessions
        conts.values.forEach { $0.yield(list) }
        return before ?? .open
    }

    public var sessions: [SessionInfo] {
        let cutoff = clock().addingTimeInterval(-Self.maxAge)
        return byID.values.filter { $0.updated > cutoff }
            .sorted { (Self.rank($0.state), $0.updated) < (Self.rank($1.state), $1.updated) }
            .map { s in
                var s = s
                s.name = given[s.id] ?? SpokenNames.tidy(s.name)
                return s
            }
    }

    /// The name the session goes by, once it is known.
    public func name(of session: String) -> String? {
        given[session] ?? byID[session].map { SpokenNames.tidy($0.name) }
    }

    /// Names the sessions `claude agents` lists, and the ones only the plugin
    /// reports, keeping every name already given. `complete`: the list is
    /// all the open sessions, so names of sessions gone from it are dropped.
    /// After a failed check nothing is dropped: a session missing from it may
    /// still be open, and must keep its name.
    @discardableResult
    public func nameSessions(_ entries: [SpokenNames.Entry], complete: Bool = true) -> [String: String] {
        if complete {
            listed = entries
        } else {
            let ids = Set(entries.map(\.id))
            listed = listed.filter { !ids.contains($0.id) } + entries
        }
        let before = byID.keys.map { given[$0] }
        let names = SpokenNames.names(namingEntries(), keeping: given)
        given = complete ? names : given.merging(names) { _, new in new }
        if byID.keys.map({ given[$0] }) != before {
            let list = sessions
            conts.values.forEach { $0.yield(list) }
        }
        return given
    }

    /// Every session there is to name: as `claude agents` listed it, else as the plugin reported it.
    private func namingEntries() -> [SpokenNames.Entry] {
        let ids = Set(listed.map(\.id))
        let reported = byID.values.filter { !ids.contains($0.id) }.sorted { ($0.since, $0.id) < ($1.since, $1.id) }
            .map { s in
                SpokenNames.Entry(id: s.id, project: SpokenNames.project(plugin: s.project ?? SpokenNames.tidy(s.name)),
                                  title: s.title ?? "", label: "")
            }
        return listed + reported
    }

    /// The plugin's line, said with the session's name: the name the plugin
    /// put in it ("Still on reflow", "Hey, the tax export session") becomes
    /// the one Earshot gives the session.
    public func renamed(_ say: AppMessage.Say) -> AppMessage.Say {
        guard let name = given[say.session] else { return say }
        let forms = [say.name, byID[say.session]?.name].compactMap { $0 }.flatMap(SpokenNames.pluginForms)
        var s = say
        s.text = SpokenNames.renamed(say.text, forms: forms, to: name)
        s.name = name
        return s
    }

    private func prune() {
        let cutoff = clock().addingTimeInterval(-Self.maxAge)
        for (id, s) in byID where s.updated <= cutoff {
            byID[id] = nil
            lastSent[id] = nil
            if !listed.contains(where: { $0.id == id }) { given[id] = nil }
        }
    }

    public func changes() -> AsyncStream<[SessionInfo]> {
        let (stream, cont) = AsyncStream<[SessionInfo]>.makeStream()
        let id = UUID()
        conts[id] = cont
        cont.yield(sessions)
        cont.onTermination = { [weak self] _ in Task { await self?.remove(id) } }
        return stream
    }

    private func remove(_ id: UUID) { conts[id] = nil }

    static func rank(_ s: SessionState) -> Int {
        switch s {
        case .needs, .reply: 0
        case .stuck, .failed: 1
        case .working: 2
        case .done: 3
        case .open, .closed: 4
        }
    }
}
