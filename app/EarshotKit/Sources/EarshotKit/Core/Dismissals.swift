import Foundation

/// Sessions you dismissed while they waited on you. A dismissed session reads
/// as open everywhere a waiting one would stand out (Waiting on You, the
/// "Needs You" count, the recap, the menu bar panel). It is not stopped and
/// nothing is sent to it. It waits on you again when it asks something new:
/// it stops waiting, or enters a waiting state after you dismissed it.
public struct Dismissals: Sendable, Equatable, Codable {
    /// When each session was dismissed.
    public private(set) var at: [String: Date] = [:]

    public init(at: [String: Date] = [:]) { self.at = at }

    public mutating func dismiss(_ id: String, now: Date = Date()) { at[id] = now }
    public mutating func restore(_ id: String) { at[id] = nil }
    public func isDismissed(_ id: String) -> Bool { at[id] != nil }

    /// The session as the app shows it: open while its wait is dismissed.
    public func apply(_ s: SessionInfo) -> SessionInfo {
        guard s.state == .needs || s.state == .reply, let when = at[s.id], s.since <= when else { return s }
        var out = s
        out.state = .open
        return out
    }

    /// The same for a session only `claude agents` lists.
    public func apply(_ s: LiveSession) -> LiveSession {
        guard Self.waits(s), let when = at[s.id], (s.since ?? .distantPast) <= when else { return s }
        var out = s
        out.waiting = false
        if out.state == .needs || out.state == .reply { out.state = .open }
        return out
    }

    /// A session missing from both lists may only be missing from one check;
    /// its dismissal is dropped after this long. Session ids are never reused.
    public static let keepGone: TimeInterval = 7 * 86_400

    /// Drops the dismissals that no longer hold back a wait: the session
    /// stopped waiting or waited again after you dismissed it, so a new wait
    /// shows. Pass both lists only once both have loaded. Returns true when
    /// anything was dropped.
    @discardableResult
    public mutating func prune(known: [SessionInfo], live: [LiveSession], now: Date = Date()) -> Bool {
        let before = at.count
        at = at.filter { id, when in
            let k = known.first { $0.id == id }
            let l = live.first { $0.id == id }
            guard k != nil || l != nil else { return now.timeIntervalSince(when) < Self.keepGone }
            if let k, k.state == .needs || k.state == .reply { return k.since <= when }
            if let l, Self.waits(l) { return (l.since ?? .distantPast) <= when }
            return false
        }
        return at.count != before
    }

    private static func waits(_ s: LiveSession) -> Bool {
        s.waiting || s.state == .needs || s.state == .reply
    }
}
