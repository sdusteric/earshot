import Foundation

/// The roll call, as the plugin says it (speak.sh rollcall): how many, then
/// the sessions that need you first, at most six.
///
/// Kobi talks like a coworker who keeps an eye on your sessions: it says
/// what it noticed (a long run, a long wait, a late night), in plain words
/// with contractions, and never makes up feelings or facts.
public enum RollCall {
    static let counts = ["No", "One", "Two", "Three", "Four", "Five", "Six", "Seven", "Eight", "Nine"]
    /// A run this long is worth a mention ("Billing's been at it for an hour").
    static let longRun: TimeInterval = 30 * 60
    /// A wait on you this long is worth a mention.
    static let longWait: TimeInterval = 10 * 60
    /// A finish older than this is old news: the roll call counts the session as idle.
    static let oldFinish: TimeInterval = 20 * 60

    static func finishedLongAgo(_ s: LiveSession, now: Date) -> Bool {
        guard effectiveState(s) == .done, let since = s.since else { return false }
        return now.timeIntervalSince(since) > oldFinish
    }

    /// hour: the local hour now, for the late-night note (nil: from the clock).
    /// A wait you dismissed in Activity reads as open here too, so the roll
    /// call never says a dismissed session needs you.
    public static func line(_ sessions: [LiveSession], now: Date, hour: Int? = nil,
                            dismissals: Dismissals = Dismissals()) -> String {
        let sessions = dismissals.apply(sessions)
        guard !sessions.isEmpty else { return "No Claude sessions are open." }
        let total = sessions.count
        let head = "\(count(total)) session\(total == 1 ? "" : "s")."
        let ordered = sessions.sorted { (rank($0), $0.since ?? now) < (rank($1), $1.since ?? now) }
        // Sessions doing something are named; idle ones are only counted, so
        // fourteen sessions don't mean fourteen "is idle"s. A session that
        // finished a while ago is idle by now.
        let named = ordered.filter { effectiveState($0) != .open && !finishedLongAgo($0, now: now) }
        let idle = total - named.count
        var parts = [head] + named.prefix(6).map { sentence($0, now: now) }
        if named.count > 6 { parts.append("And \(named.count - 6) more.") }
        if idle > 0 {
            parts.append(named.isEmpty ? (idle == 1 ? "It's idle." : "All idle.")
                         : idle == 1 ? "One other is idle." : "The other \(idle) are idle.")
        }
        if let note = closing(sessions, hour: hour ?? Calendar.current.component(.hour, from: now)) { parts.append(note) }
        return parts.joined(separator: " ")
    }

    /// One session's sentence. Pass the dismissals for a session said on its
    /// own ("how's billing?"); line and greeting apply them already.
    public static func sentence(_ s: LiveSession, now: Date, dismissals: Dismissals = Dismissals()) -> String {
        let s = dismissals.apply(s)
        let n = title(s.name)
        let waited = s.since.map { now.timeIntervalSince($0) } ?? 0
        switch effectiveState(s) {
        case .needs:
            if let d = s.detail, !d.isEmpty {
                return "\(n) \(d)\(".!?".contains(d.last ?? " ") ? "" : ".")" + (waited >= longWait ? " That was \(duration(waited)) ago." : "")
            }
            return waited >= longWait ? "\(hasBeen(n)) waiting on you for \(duration(waited))." : "\(n) is waiting on you."
        case .reply:
            return waited >= longWait ? "\(hasBeen(n)) waiting on your answer for \(duration(waited))." : "\(n) is waiting on your answer."
        case .stuck: return "\(n) might be stuck."
        case .failed: return "\(n) hit an error."
        case .working:
            guard s.since != nil, s.state == .working else { return "\(n) is working." }
            if waited >= longRun { return "\(hasBeen(n)) at it for \(duration(waited))." }
            let m = Int(waited / 60)
            return m == 0 ? "\(n) is working, just started." : "\(n) is working, \(m) minute\(m == 1 ? "" : "s") in."
        case .done:
            guard let d = s.detail, !d.isEmpty else { return "\(n) finished." }
            let detail = d.prefix(1).lowercased() + d.dropFirst()
            return "\(n) finished: \(detail)\(".!?".contains(d.last ?? " ") ? "" : ".")"
        default: return "\(n) is idle."
        }
    }

    /// "How are you doing?": a short answer, then only what matters. Unlike
    /// the roll call it doesn't list every session. pick(n) chooses one of n
    /// ways to open, so Kobi doesn't say the same words every time.
    /// Dismissed waits read as open, as in the roll call.
    public static func greeting(_ sessions: [LiveSession], now: Date, hour: Int? = nil,
                                dismissals: Dismissals = Dismissals(),
                                pick: (Int) -> Int = { Int.random(in: 0..<$0) }) -> String {
        let sessions = dismissals.apply(sessions)
        let hour = hour ?? Calendar.current.component(.hour, from: now)
        let ordered = sessions.sorted { (rank($0), $0.since ?? now) < (rank($1), $1.since ?? now) }
        let attention = ordered.filter { needsYou($0) }
        let working = ordered.filter { effectiveState($0) == .working }
        let openers = attention.isEmpty ? calmOpeners : busyOpeners
        var parts = [openers[min(max(pick(openers.count), 0), openers.count - 1)]]
        guard !sessions.isEmpty else { return (parts + ["No sessions are open."]).joined(separator: " ") }
        parts += attention.prefix(2).map { sentence($0, now: now) }
        if attention.count > 2 { parts.append("And \(attention.count - 2) more need you.") }
        switch working.count {
        case 0:
            parts.append(attention.isEmpty ? "Nothing's running, and nothing needs you." : "Nothing else is running.")
        case 1:
            parts.append(sentence(working[0], now: now))
        default:
            // The longest run gets a mention when it has been going a while.
            let longest = working.compactMap { s in s.since.map { (s, now.timeIntervalSince($0)) } }.max { $0.1 < $1.1 }
            if let (s, t) = longest, t >= longRun, s.state == .working {
                parts.append("\(count(working.count)) are working. \(hasBeen(s.name)) at it for \(duration(t)).")
            } else {
                parts.append("\(count(working.count)) are working.")
            }
        }
        if attention.isEmpty, working.isEmpty == false, let late = lateNote(working.count, hour: hour) { parts.append(late) }
        return parts.joined(separator: " ")
    }

    static let calmOpeners = ["Doing fine.", "All good here.", "Pretty good, thanks.", "Not bad."]
    static let busyOpeners = ["Doing okay.", "Good, mostly."]

    /// The roll call's last word: the late hour while sessions still run, or
    /// that nothing needs you.
    static func closing(_ sessions: [LiveSession], hour: Int) -> String? {
        let working = sessions.filter { effectiveState($0) == .working }.count
        if let late = lateNote(working, hour: hour) { return late }
        return sessions.contains(where: needsYou) ? nil : "Nothing needs you."
    }

    static func lateNote(_ working: Int, hour: Int) -> String? {
        guard working > 0, hour >= 23 || hour < 5 else { return nil }
        let still = working == 1 ? "one's still going" : "\(count(working).lowercased()) are still going"
        return hour >= 23 ? "It's getting late, and \(still)." : "It's past midnight, and \(still)."
    }

    /// Waiting on you, stuck, or failed.
    static func needsYou(_ s: LiveSession) -> Bool {
        switch effectiveState(s) {
        case .needs, .reply, .stuck, .failed: true
        default: false
        }
    }

    /// "a minute", "12 minutes", "about an hour", "over an hour", "about 3 hours".
    static func duration(_ t: TimeInterval) -> String {
        let m = Int(t / 60)
        switch m {
        case ..<2: return "a minute"
        case ..<55: return "\(m) minutes"
        case ..<70: return "about an hour"
        case ..<100: return "over an hour"
        default: return "about \(Int((Double(m) / 60).rounded())) hours"
        }
    }

    /// "Billing's been", "Billing service has been": a contraction where it reads naturally.
    static func hasBeen(_ name: String) -> String {
        let n = title(name)
        return ["s", "x", "z"].contains(n.last.map { String($0).lowercased() } ?? "") ? "\(n) has been" : "\(n)'s been"
    }

    static func title(_ name: String) -> String { name.prefix(1).uppercased() + name.dropFirst() }

    static func count(_ n: Int) -> String { n <= 9 ? counts[n] : "\(n)" }

    /// The plugin's state, else what Claude Code shows.
    static func effectiveState(_ s: LiveSession) -> SessionState {
        if let st = s.state { return st }
        if s.waiting { return .needs }
        return s.busy ? .working : .open
    }

    static func rank(_ s: LiveSession) -> Int { SessionStore.rank(effectiveState(s)) }
}
