import Foundation

public struct SessionInfo: Sendable, Equatable, Identifiable {
    public let id: String
    public var name: String
    public var state: SessionState
    public var detail: String?
    public var updated: Date
}

/// Open sessions, from the plugin's status messages. Sessions that need you
/// come first, as in the roll call.
public actor SessionStore {
    /// Sessions quiet this long count as closed, as the plugin's live files do.
    public static let maxAge: TimeInterval = 6 * 3600

    private var byID: [String: SessionInfo] = [:]
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
        } else {
            let name = [status.name, status.project, byID[status.session]?.name]
                .compactMap { $0 }.first { !$0.isEmpty } ?? "a session"
            byID[status.session] = SessionInfo(id: status.session, name: name, state: status.state,
                                               detail: status.detail, updated: clock())
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
    }

    private func prune() {
        let cutoff = clock().addingTimeInterval(-Self.maxAge)
        for (id, s) in byID where s.updated <= cutoff {
            byID[id] = nil
            lastSent[id] = nil
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
