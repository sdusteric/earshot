import Foundation

/// The roll call, as the plugin says it (speak.sh rollcall): how many, then
/// the sessions that need you first, at most six.
public enum RollCall {
    static let counts = ["No", "One", "Two", "Three", "Four", "Five", "Six", "Seven", "Eight", "Nine"]

    public static func line(_ sessions: [LiveSession], now: Date) -> String {
        guard !sessions.isEmpty else { return "No Claude sessions are open." }
        let total = sessions.count
        let head = total <= 9 ? "\(counts[total]) session\(total == 1 ? "" : "s")." : "\(total) sessions."
        let ordered = sessions.sorted { (rank($0), $0.since ?? now) < (rank($1), $1.since ?? now) }
        var parts = [head] + ordered.prefix(6).map { sentence($0, now: now) }
        if total > 6 { parts.append("And \(total - 6) more.") }
        return parts.joined(separator: " ")
    }

    public static func sentence(_ s: LiveSession, now: Date) -> String {
        let n = s.name.prefix(1).uppercased() + s.name.dropFirst()
        switch effectiveState(s) {
        case .needs: return "\(n) \(s.detail.flatMap { $0.isEmpty ? nil : $0 } ?? "is waiting on you")."
        case .reply: return "\(n) is waiting on your answer."
        case .stuck: return "\(n) might be stuck."
        case .failed: return "\(n) hit an error."
        case .working:
            guard let since = s.since, s.state == .working else { return "\(n) is working." }
            let m = Int(now.timeIntervalSince(since) / 60)
            return m == 0 ? "\(n) is working, just started." : "\(n) is working, \(m) minute\(m == 1 ? "" : "s") in."
        case .done:
            guard let d = s.detail, !d.isEmpty else { return "\(n) finished." }
            let detail = d.prefix(1).lowercased() + d.dropFirst()
            return "\(n) finished: \(detail)\(".!?".contains(d.last ?? " ") ? "" : ".")"
        default: return "\(n) is open."
        }
    }

    /// The plugin's state, else what Claude Code shows.
    static func effectiveState(_ s: LiveSession) -> SessionState {
        if let st = s.state { return st }
        if s.waiting { return .needs }
        return s.busy ? .working : .open
    }

    static func rank(_ s: LiveSession) -> Int { SessionStore.rank(effectiveState(s)) }
}
