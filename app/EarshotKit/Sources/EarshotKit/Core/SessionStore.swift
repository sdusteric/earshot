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
    private var byID: [String: SessionInfo] = [:]
    private var conts: [UUID: AsyncStream<[SessionInfo]>.Continuation] = [:]

    public init() {}

    /// Returns the state the session had before, if any.
    @discardableResult
    public func apply(_ status: AppMessage.Status) -> SessionState? {
        let before = byID[status.session]?.state
        if status.state == .closed {
            byID[status.session] = nil
        } else {
            let name = [status.name, status.project, byID[status.session]?.name]
                .compactMap { $0 }.first { !$0.isEmpty } ?? "a session"
            byID[status.session] = SessionInfo(id: status.session, name: name, state: status.state,
                                               detail: status.detail, updated: Date())
        }
        let list = sessions
        conts.values.forEach { $0.yield(list) }
        return before
    }

    public var sessions: [SessionInfo] {
        byID.values.sorted { (Self.rank($0.state), $0.updated) < (Self.rank($1.state), $1.updated) }
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
