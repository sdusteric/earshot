import Foundation

/// What the menu bar panel shows, in order: what waits on you (permission
/// prompts, then sessions waiting on an answer), then the other sessions.
/// A session shown in a waiting card is not listed again below it.
public struct PanelLayout: Sendable, Equatable {
    /// Permission prompts, oldest first, each with Allow and Deny.
    public let approvals: [OpenApproval]
    /// Sessions waiting on your answer that have no open permission prompt.
    public let questions: [SessionInfo]
    /// Waiting items past the cut, for "N more waiting in Activity".
    public let moreWaiting: Int
    /// The sessions under the waiting cards, in rank order.
    public let sessions: [SessionInfo]
    /// Sessions past the cut, for "N more in Activity".
    public let moreSessions: Int

    /// `ranked` is `SessionInfo.panelList`. At most `maxWaiting` waiting cards
    /// and `maxSessions` session rows, so the panel fits on a laptop screen.
    public init(ranked: [SessionInfo], approvals open: [OpenApproval], maxWaiting: Int, maxSessions: Int) {
        let asked = Set(open.map(\.session))
        let waiting = ranked.filter { ($0.state == .needs || $0.state == .reply) && !asked.contains($0.id) }
        let shownApprovals = Array(open.prefix(maxWaiting))
        let shownQuestions = Array(waiting.prefix(max(0, maxWaiting - shownApprovals.count)))
        approvals = shownApprovals
        questions = shownQuestions
        moreWaiting = open.count + waiting.count - shownApprovals.count - shownQuestions.count
        let carded = Set(shownApprovals.map(\.session) + shownQuestions.map(\.id))
        let rest = ranked.filter { !carded.contains($0.id) }
        sessions = Array(rest.prefix(maxSessions))
        moreSessions = rest.count - sessions.count
    }

    public var isWaiting: Bool { !approvals.isEmpty || !questions.isEmpty }
}
