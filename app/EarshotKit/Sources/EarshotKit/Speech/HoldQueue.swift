import Foundation

/// Lines kept while another app uses the mic, and the order they are said in
/// afterwards. A port of catch_up in speak.sh.
public struct HoldQueue: Sendable {
    public static let maxAge: TimeInterval = 4 * 3600
    static let introAge: TimeInterval = 30
    static let maxLines = 4

    private var lines: [SpokenLine] = []

    public init() {}

    public var isEmpty: Bool { lines.isEmpty }
    public var count: Int { lines.count }

    public mutating func hold(_ line: SpokenLine) {
        guard line.kind.isHeld else { return }
        lines.append(line)
    }

    /// You answered this session, so its "needs you" lines are stale.
    public mutating func dropAnswered(session: String) {
        lines.removeAll { $0.session == session && ($0.kind == .need || $0.kind == .reply) }
    }

    /// Takes every held line and returns what to say, in order.
    public mutating func takeCatchUp(now: Date, answered: (SpokenLine) -> Bool) -> [SpokenLine] {
        let batch = lines.filter { now.timeIntervalSince($0.received) <= Self.maxAge }
        lines.removeAll()
        // Per session and kind: the first "needs you" line, the most specific
        // one, and the newest line of every other kind.
        var picked: [String: SpokenLine] = [:]
        for line in batch {
            let key = line.session + "\u{1f}" + line.kind.rawValue
            if line.kind != .need || picked[key] == nil { picked[key] = line }
        }
        let kept = picked.values
            .filter { !($0.kind == .need && answered($0)) }
            .sorted { ($0.kind.catchUpRank, $0.received) < ($1.kind.catchUpRank, $1.received) }
        guard let oldest = kept.map({ $0.received }).min() else { return [] }
        var out: [SpokenLine] = []
        if now.timeIntervalSince(oldest) >= Self.introAge {
            out.append(SpokenLine(text: "While you were on the mic:", kind: .intro, session: "", received: now))
        }
        out += kept.prefix(Self.maxLines)
        if kept.count > Self.maxLines {
            out.append(SpokenLine(text: "And \(kept.count - Self.maxLines) more.", kind: .intro, session: "", received: now))
        }
        return out
    }
}
