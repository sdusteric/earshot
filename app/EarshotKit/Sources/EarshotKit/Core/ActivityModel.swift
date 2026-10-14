import CoreGraphics
import Foundation

/// Where everything sits on the Activity window's 24-hour dial. Now is at the
/// top and the past runs counterclockwise from it, a full turn per day; the
/// outer ring is what you said, then one ring per session, newest first,
/// around the orb in the middle. Colors and drawing stay in the app.
public struct DialGeometry: Sendable {
    /// A ring on the dial: what you said, or one session.
    public struct Ring: Sendable, Equatable {
        public let id: String
        public let radius: CGFloat
    }

    /// One hour tick around the dial, and whether it carries a clock label.
    public struct HourTick: Sendable, Equatable {
        public let date: Date
        /// Every 6 hours: a longer tick that may carry a label.
        public let major: Bool
        public let labeled: Bool
    }

    public static let youLane = "you"
    public static let day: TimeInterval = 24 * 3600
    /// A gap this long between lines ends a stretch, so an arc never claims
    /// work nobody heard about.
    public static let stretchGap: TimeInterval = 1800
    /// A stretch shorter than this is just its dot.
    public static let shortestStretch: TimeInterval = 900
    /// Lines closer than this on screen draw as one dot.
    public static let mergeDistance: CGFloat = 8
    /// An hour label this close to now, on either side, would crowd the "now" label.
    public static let labelClearance: TimeInterval = 4500

    public let size: CGFloat
    public let now: Date
    public let orbSize: CGFloat
    public let outer: CGFloat
    /// What you said first, then each session in the order given.
    public let rings: [Ring]

    public var center: CGPoint { CGPoint(x: size / 2, y: size / 2) }

    public init(size: CGFloat, now: Date, sessions: [String]) {
        self.size = size
        self.now = now
        outer = size / 2 - 76   // room for the hour labels at the sides
        orbSize = size * 0.3
        let inner = orbSize / 2 + 30
        let count = CGFloat(sessions.count + 1)
        let gap = min(30, (outer - inner) / max(count, 1))
        var rings = [Ring(id: Self.youLane, radius: outer)]
        for (i, s) in sessions.enumerated() {
            rings.append(Ring(id: s, radius: outer - gap * CGFloat(i + 1)))
        }
        self.rings = rings
    }

    /// The angle of a moment: -90 degrees is now, a day ago is a full turn back.
    public func angle(_ t: Date) -> Double {
        let back = min(max(now.timeIntervalSince(t), 0), Self.day)
        return -Double.pi / 2 - back / Self.day * 2 * Double.pi
    }

    public func point(_ t: Date, radius: CGFloat) -> CGPoint {
        let a = angle(t)
        return CGPoint(x: center.x + cos(a) * radius, y: center.y + sin(a) * radius)
    }

    /// The moment under a point on the dial, when it is on the dial's face.
    public func time(at p: CGPoint) -> Date? {
        let dx = p.x - center.x, dy = p.y - center.y
        let r = (dx * dx + dy * dy).squareRoot()
        guard r > orbSize / 2 + 8, r < outer + 24 else { return nil }
        var a = atan2(dy, dx) + Double.pi / 2   // 0 at the top, growing clockwise
        if a > 0 { a -= 2 * Double.pi }
        return now.addingTimeInterval(a / (2 * Double.pi) * Self.day)
    }

    /// The ring a line sits on: what you said goes on yours, a session's line on its ring.
    public func ring(for e: HistoryEntry) -> Ring? {
        if e.kind == .heard { return rings.first }
        guard let s = e.session else { return nil }
        return rings.first { $0.id == s }
    }

    public func position(_ e: HistoryEntry) -> CGPoint? {
        guard let r = ring(for: e) else { return nil }
        return point(e.date, radius: r.radius)
    }

    /// The dots as drawn: lines that would sit on top of each other on a ring
    /// become one dot, so hover and click reach every dot that shows.
    public func dots(_ entries: [HistoryEntry]) -> [DialDot] {
        var out: [DialDot] = []
        for e in entries.sorted(by: { $0.date > $1.date }) {
            guard let p = position(e) else { continue }
            if let i = out.firstIndex(where: { hypot($0.point.x - p.x, $0.point.y - p.y) < Self.mergeDistance }) {
                out[i].count += 1
                out[i].oldest = min(out[i].oldest, e.date)
            } else {
                out.append(DialDot(entry: e, point: p, oldest: e.date))
            }
        }
        return out
    }

    /// The dot under the pointer, within 12 points.
    public static func nearest(_ dots: [DialDot], to p: CGPoint) -> DialDot? {
        dots.filter { hypot($0.point.x - p.x, $0.point.y - p.y) < 12 }
            .min { hypot($0.point.x - p.x, $0.point.y - p.y) < hypot($1.point.x - p.x, $1.point.y - p.y) }
    }

    /// The arcs drawn on one ring for its lines' times. A gap of more than
    /// half an hour ends a stretch. The latest stretch runs on to now while
    /// the session works or waits on you, if it spoke within half an hour.
    /// A stretch under 15 minutes is not drawn.
    public static func stretches(_ times: [Date], active: Bool, now: Date) -> [ClosedRange<Date>] {
        var spans: [(Date, Date)] = []
        for t in times.sorted() {
            if let last = spans.last, t.timeIntervalSince(last.1) <= stretchGap { spans[spans.count - 1].1 = t } else { spans.append((t, t)) }
        }
        var out: [ClosedRange<Date>] = []
        for (i, span) in spans.enumerated() {
            let runsOn = i == spans.count - 1 && active && now.timeIntervalSince(span.1) <= stretchGap
            let end = runsOn ? now : span.1
            guard end.timeIntervalSince(span.0) >= shortestStretch else { continue }
            out.append(span.0...end)
        }
        return out
    }

    /// An hour tick for each of the last 24 hours, newest first, with a clock
    /// label every 6 hours unless it would sit within 75 minutes of now.
    public static func hourTicks(now: Date, calendar: Calendar = .current) -> [HourTick] {
        let startHour = calendar.dateInterval(of: .hour, for: now)?.start ?? now
        return (0..<24).map { h in
            let t = startHour.addingTimeInterval(-Double(h) * 3600)
            let major = calendar.component(.hour, from: t) % 6 == 0
            return HourTick(date: t, major: major, labeled: major && labelClearsNow(t, now: now))
        }
    }

    /// False for a moment within 75 minutes of now, either just past it or
    /// nearly a day back, where the dial comes round to now again.
    public static func labelClearsNow(_ t: Date, now: Date) -> Bool {
        let back = now.timeIntervalSince(t)
        return back > labelClearance && back < day - labelClearance
    }
}

/// One drawn dot: the newest line there, and the older ones merged into it.
public struct DialDot: Sendable {
    public let entry: HistoryEntry
    public let point: CGPoint
    public var count = 1
    public var oldest: Date

    public init(entry: HistoryEntry, point: CGPoint, count: Int = 1, oldest: Date) {
        self.entry = entry; self.point = point; self.count = count; self.oldest = oldest
    }
}

/// The sessions as the Activity window speaks of them: the recap, the order
/// of the rings and the Show menu, and one name for each session.
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

    public struct Named: Sendable, Equatable {
        public let id: String
        public let name: String
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

    /// The sessions the recap speaks about, in its order, at most three.
    public var recapLines: [RecapLine] {
        let order: [SessionState] = [.needs, .reply, .stuck, .failed, .done, .working]
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
                case .done: "finished."
                default: "is still working."
                }
                return RecapLine(id: s.id, sentence: "\(n) \(verb)")
            }
        if !fromPlugin.isEmpty { return Array(fromPlugin.prefix(3)) }
        // The plugin hasn't reported yet: what Claude Code itself says.
        return live
            .filter { $0.waiting || $0.busy }
            .sorted { ($0.waiting ? 0 : 1) < ($1.waiting ? 0 : 1) }
            .prefix(3)
            .map { s in RecapLine(id: s.id, sentence: "\(Self.title(displayName(s.id))) \(s.waiting ? "needs you." : "is working.")") }
    }

    /// Who needs you first, then who is stuck, finished, or working: one short sentence each.
    public var recap: String {
        let parts = recapLines.map(\.sentence)
        if !parts.isEmpty { return parts.joined(separator: " ") }
        return known.isEmpty && live.isEmpty ? "No Claude Code sessions are open." : "Nothing needs you right now."
    }

    /// Sessions for the rings and the Show menu: the ones the recap names come
    /// first (they get the five rings), then today's history, newest first,
    /// then the rest the plugin knows.
    public var ordered: [Named] {
        var order: [String] = recapLines.map(\.id)
        for e in history.reversed() {
            guard let id = e.session, !order.contains(id) else { continue }
            order.append(id)
        }
        for s in known where !order.contains(s.id) { order.append(s.id) }
        return order.map { Named(id: $0, name: displayName($0)) }
    }

    /// Working or waiting on you, by the plugin's account, else Claude Code's.
    public func isActive(_ id: String) -> Bool {
        if let s = known.first(where: { $0.id == id }) { return [.working, .needs, .reply].contains(s.state) }
        if let s = live.first(where: { $0.id == id }) { return s.busy || s.waiting }
        return false
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
