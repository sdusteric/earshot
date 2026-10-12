import EarshotKit
import SwiftUI

/// Where everything sits on the 24-hour dial. Now is at the top and the past
/// runs counterclockwise from it; the outer ring is what you said, then one
/// ring per session, newest first, around the orb in the middle.
struct DialLayout {
    struct Lane: Identifiable {
        let id: String
        let name: String
        let color: Color
        let radius: CGFloat
    }

    static let youLane = "you"
    static let day: TimeInterval = 24 * 3600

    let size: CGFloat
    let now: Date
    let lanes: [Lane]
    let orbSize: CGFloat
    let outer: CGFloat

    var center: CGPoint { CGPoint(x: size / 2, y: size / 2) }

    init(size: CGFloat, now: Date, sessions: [(id: String, name: String, color: Color)]) {
        self.size = size
        self.now = now
        outer = size / 2 - 52
        orbSize = size * 0.3
        let inner = orbSize / 2 + 30
        let count = CGFloat(sessions.count + 1)
        let gap = min(30, (outer - inner) / max(count, 1))
        var lanes = [Lane(id: Self.youLane, name: "You", color: DialPalette.you, radius: outer)]
        for (i, s) in sessions.enumerated() {
            lanes.append(Lane(id: s.id, name: s.name, color: s.color, radius: outer - gap * CGFloat(i + 1)))
        }
        self.lanes = lanes
    }

    /// The angle of a moment: -90 degrees is now, a day ago is a full turn back.
    func angle(_ t: Date) -> Double {
        let back = min(max(now.timeIntervalSince(t), 0), Self.day)
        return -Double.pi / 2 - back / Self.day * 2 * Double.pi
    }

    func point(_ t: Date, radius: CGFloat) -> CGPoint {
        let a = angle(t)
        return CGPoint(x: center.x + cos(a) * radius, y: center.y + sin(a) * radius)
    }

    func lane(for e: HistoryEntry) -> Lane? {
        if e.kind == .heard { return lanes.first }
        guard let s = e.session else { return nil }
        return lanes.first { $0.id == s }
    }

    func position(_ e: HistoryEntry) -> CGPoint? {
        guard let l = lane(for: e) else { return nil }
        return point(e.date, radius: l.radius)
    }

    /// The moment under a point on the dial, when it is on the dial's face.
    func time(at p: CGPoint) -> Date? {
        let dx = p.x - center.x, dy = p.y - center.y
        let r = (dx * dx + dy * dy).squareRoot()
        guard r > orbSize / 2 + 8, r < outer + 24 else { return nil }
        var a = atan2(dy, dx) + Double.pi / 2   // 0 at the top, growing clockwise
        if a > 0 { a -= 2 * Double.pi }
        return now.addingTimeInterval(a / (2 * Double.pi) * Self.day)
    }
}

enum DialPalette {
    static let ground = Color(red: 0.043, green: 0.051, blue: 0.071)
    static let raised = Color(red: 0.067, green: 0.078, blue: 0.106)
    static let track = Color(red: 0.11, green: 0.125, blue: 0.17)
    static let tick = Color(red: 0.23, green: 0.255, blue: 0.32)
    static let you = Color(red: 0.39, green: 0.77, blue: 1.0)
    static let voice = Color(red: 1.0, green: 0.74, blue: 0.42)

    static func color(_ e: HistoryEntry, sessions: [SessionInfo]) -> Color {
        if e.kind == .heard { return you }
        switch e.lineKind {
        case .need, .reply: return .orange
        case .alert: return .red
        case .done: return .green
        default: return voice
        }
    }
}

/// The dial: hour ticks, session rings, a dot per line, the stretch since you
/// last looked, the selected stretch, and the orb in the middle.
struct DayDial: View {
    let entries: [HistoryEntry]
    let layout: DialLayout
    let since: Date?
    let selection: ClosedRange<Date>?
    let highlighted: Set<UUID>
    let focusLane: String?
    let select: (Date?) -> Void
    @Environment(AppModel.self) private var model
    @State private var hover: HistoryEntry?

    var body: some View {
        ZStack {
            Canvas { gc, _ in draw(&gc) }
            OrbView(size: layout.orbSize, restingColor: .white, spinsWhenIdle: true)
                .background(Circle().fill(.black))
                .clipShape(.circle)
                .overlay(Circle().stroke(DialPalette.tick, lineWidth: 1))
                .contentShape(.circle)
                .onTapGesture { model.tapToTalk() }
                .help("Click and say a command")
                .accessibilityAddTraits(.isButton)
                .accessibilityHint("Listens for one command")
            if let hover, let p = layout.position(hover) { callout(hover, at: p) }
        }
        .frame(width: layout.size, height: layout.size)
        .contentShape(.rect)
        .onContinuousHover { phase in
            switch phase {
            case .active(let p): hover = nearest(to: p)
            case .ended: hover = nil
            }
        }
        .gesture(SpatialTapGesture().onEnded { v in
            if let e = nearest(to: v.location) {
                select(e.date)
            } else {
                select(layout.time(at: v.location))
            }
        })
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Today around the orb")
    }

    private func nearest(to p: CGPoint) -> HistoryEntry? {
        var best: (HistoryEntry, CGFloat)?
        for e in entries {
            guard let q = layout.position(e) else { continue }
            let d = hypot(q.x - p.x, q.y - p.y)
            if d < 12, d < (best?.1 ?? .infinity) { best = (e, d) }
        }
        return best?.0
    }

    private func draw(_ gc: inout GraphicsContext) {
        let c = layout.center

        // The stretch since you last looked, shaded in Earshot's voice color.
        if let since, since < layout.now, layout.now.timeIntervalSince(since) < DialLayout.day {
            sector(&gc, from: since, to: layout.now, color: DialPalette.voice.opacity(0.09))
            arc(&gc, from: since, to: layout.now, radius: layout.outer + 14, color: DialPalette.voice.opacity(0.75), width: 2)
        }
        if let selection {
            sector(&gc, from: selection.lowerBound, to: selection.upperBound, color: Color.white.opacity(0.06))
        }

        // Hour ticks, clock labels every 6 hours, a longer tick for now.
        let cal = Calendar.current
        let startHour = cal.dateInterval(of: .hour, for: layout.now)?.start ?? layout.now
        for h in 0..<24 {
            let t = startHour.addingTimeInterval(-Double(h) * 3600)
            let hour = cal.component(.hour, from: t)
            let major = hour % 6 == 0
            let a = layout.angle(t)
            var p = Path()
            p.move(to: CGPoint(x: c.x + cos(a) * (layout.outer + 20), y: c.y + sin(a) * (layout.outer + 20)))
            p.addLine(to: CGPoint(x: c.x + cos(a) * (layout.outer + (major ? 30 : 25)), y: c.y + sin(a) * (layout.outer + (major ? 30 : 25))))
            gc.stroke(p, with: .color(DialPalette.tick), lineWidth: major ? 1.5 : 1)
            if major {
                let lp = CGPoint(x: c.x + cos(a) * (layout.outer + 33), y: c.y + sin(a) * (layout.outer + 33))
                let label = Text(t, format: .dateTime.hour()).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                gc.draw(label, at: lp, anchor: anchor(for: a))
            }
        }
        var nowTick = Path()
        nowTick.move(to: CGPoint(x: c.x, y: c.y - layout.outer - 18))
        nowTick.addLine(to: CGPoint(x: c.x, y: c.y - layout.outer - 34))
        gc.stroke(nowTick, with: .color(DialPalette.voice), lineWidth: 2)
        gc.draw(Text("now").font(.caption2.weight(.semibold)).foregroundStyle(DialPalette.voice),
                at: CGPoint(x: c.x, y: c.y - layout.outer - 36), anchor: .bottom)

        // Rings: a quiet track per lane, brighter for the lane in focus.
        for lane in layout.lanes {
            let focused = focusLane == nil || focusLane == lane.id
            var ring = Path()
            ring.addEllipse(in: CGRect(x: c.x - lane.radius, y: c.y - lane.radius, width: lane.radius * 2, height: lane.radius * 2))
            gc.stroke(ring, with: .color(focused ? DialPalette.track : DialPalette.track.opacity(0.45)), lineWidth: 14)
        }

        // Each ring's name, just past now, where a day-old moment would sit.
        for lane in layout.lanes {
            let focused = focusLane == nil || focusLane == lane.id
            let a = -Double.pi / 2 + 0.05
            let p = CGPoint(x: c.x + cos(a) * lane.radius, y: c.y + sin(a) * lane.radius)
            let name = Text(lane.id == DialLayout.youLane ? "You" : SessionStyle.title(lane.name))
                .font(.caption2.weight(.medium))
                .foregroundStyle(lane.color.opacity(focused ? 0.95 : 0.4))
            gc.draw(name, at: CGPoint(x: p.x + 6, y: p.y), anchor: .leading)
        }

        // A dot per line: nearer now is brighter, a match for the search is larger.
        for e in entries {
            guard let lane = layout.lane(for: e), let p = layout.position(e) else { continue }
            let age = layout.now.timeIntervalSince(e.date) / DialLayout.day
            let dim = focusLane == nil || focusLane == lane.id ? 1.0 : 0.3
            let lit = highlighted.isEmpty || highlighted.contains(e.id)
            let r: CGFloat = (e.lineKind == .need ? 6 : 4.5) * (lit && !highlighted.isEmpty ? 1.4 : 1)
            let color = DialPalette.color(e, sessions: model.sessions)
            let rect = CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)
            gc.fill(Path(ellipseIn: rect.insetBy(dx: -2, dy: -2)), with: .color(DialPalette.ground))
            gc.fill(Path(ellipseIn: rect), with: .color(color.opacity((1 - age * 0.55) * dim * (lit ? 1 : 0.25))))
        }
    }

    private func sector(_ gc: inout GraphicsContext, from: Date, to: Date, color: Color) {
        let c = layout.center
        var p = Path()
        p.move(to: c)
        p.addArc(center: c, radius: layout.outer + 10, startAngle: .radians(layout.angle(to)),
                 endAngle: .radians(layout.angle(from)), clockwise: true)
        p.closeSubpath()
        gc.fill(p, with: .color(color))
    }

    private func arc(_ gc: inout GraphicsContext, from: Date, to: Date, radius: CGFloat, color: Color, width: CGFloat) {
        var p = Path()
        p.addArc(center: layout.center, radius: radius, startAngle: .radians(layout.angle(to)),
                 endAngle: .radians(layout.angle(from)), clockwise: true)
        gc.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round))
    }

    private func anchor(for a: Double) -> UnitPoint {
        UnitPoint(x: 0.5 - cos(a) * 0.5, y: 0.5 - sin(a) * 0.5)
    }

    private func callout(_ e: HistoryEntry, at p: CGPoint) -> some View {
        let right = p.x < layout.size / 2
        return VStack(alignment: .leading, spacing: 3) {
            Text(e.kind == .heard ? "\u{201C}\(e.text)\u{201D}" : e.text).font(.callout).lineLimit(3)
            if let reply = e.reply { Text(reply).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
            HStack(spacing: 6) {
                if let name = e.sessionName { Text(SessionStyle.title(name)) }
                Text(e.date, format: .dateTime.hour().minute())
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(width: 230, alignment: .leading)
        .background(DialPalette.raised, in: .rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(DialPalette.tick.opacity(0.6)))
        .shadow(color: .black.opacity(0.4), radius: 12, y: 4)
        .position(x: p.x + (right ? 130 : -130), y: p.y)
        .allowsHitTesting(false)
        .transition(.opacity)
    }
}

/// Earshot's newest line, typing itself in as it is said.
struct NowStrip: View {
    let entry: HistoryEntry?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let entry {
            let fresh = Date().timeIntervalSince(entry.date) < 20 && !reduceMotion
            TimelineView(.animation(paused: !fresh)) { t in
                let text = entry.kind == .heard ? (entry.reply ?? entry.text) : entry.text
                let shown = fresh ? Int(t.date.timeIntervalSince(entry.date) * 38) : text.count
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Circle().fill(DialPalette.voice).frame(width: 7, height: 7).accessibilityHidden(true)
                    Text(String(text.prefix(max(0, shown))))
                        .font(.title3)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Last line: \(entry.kind == .heard ? (entry.reply ?? entry.text) : entry.text)")
        }
    }
}
