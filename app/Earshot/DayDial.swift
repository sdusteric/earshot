import EarshotKit
import SwiftUI

/// The dial's geometry from EarshotKit, with each ring's name, color, and
/// whether it is active. The outer ring is what you said, then one ring per
/// session, newest first, around the orb in the middle.
struct DialLayout {
    struct Lane: Identifiable {
        let id: String
        let name: String
        let color: Color
        let radius: CGFloat
        /// Working or waiting on you: its arc runs on to now.
        var active = false
    }

    static let youLane = DialGeometry.youLane
    static let day = DialGeometry.day

    let geometry: DialGeometry
    let lanes: [Lane]

    var size: CGFloat { geometry.size }
    var now: Date { geometry.now }
    var orbSize: CGFloat { geometry.orbSize }
    var outer: CGFloat { geometry.outer }
    var center: CGPoint { geometry.center }

    init(size: CGFloat, now: Date, sessions: [(id: String, name: String, color: Color, active: Bool)]) {
        geometry = DialGeometry(size: size, now: now, sessions: sessions.map(\.id))
        var lanes = [Lane(id: Self.youLane, name: "You", color: DialPalette.you, radius: geometry.outer)]
        for (s, ring) in zip(sessions, geometry.rings.dropFirst()) {
            lanes.append(Lane(id: s.id, name: s.name, color: s.color, radius: ring.radius, active: s.active))
        }
        self.lanes = lanes
    }

    func angle(_ t: Date) -> Double { geometry.angle(t) }

    func point(_ t: Date, radius: CGFloat) -> CGPoint { geometry.point(t, radius: radius) }

    func lane(for e: HistoryEntry) -> Lane? {
        guard let ring = geometry.ring(for: e) else { return nil }
        return lanes.first { $0.id == ring.id }
    }

    func position(_ e: HistoryEntry) -> CGPoint? { geometry.position(e) }

    func time(at p: CGPoint) -> Date? { geometry.time(at: p) }
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
        if e.asksYou { return .orange }
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
    @State private var hover: DialDot?

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
            if let hover { callout(hover) }
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
            if let d = nearest(to: v.location) {
                select(d.entry.date)
            } else {
                select(layout.time(at: v.location))
            }
        })
        .accessibilityElement(children: .contain)
        .accessibilityLabel(summary)
    }

    /// What VoiceOver says for the dial, which draws its dots where it can't see them.
    private var summary: String {
        guard let newest = entries.max(by: { $0.date < $1.date }) else { return "Today around the orb. Nothing yet." }
        let t = newest.date.formatted(date: .omitted, time: .shortened)
        let about = newest.sessionName.map { ", about \(SessionStyle.title($0))" } ?? ""
        return "Today around the orb. \(entries.count) \(entries.count == 1 ? "line" : "lines"), the newest at \(t)\(about)."
    }

    /// The dots as drawn, with lines that would sit on top of each other merged.
    private var dots: [DialDot] { layout.geometry.dots(entries) }

    private func nearest(to p: CGPoint) -> DialDot? { DialGeometry.nearest(dots, to: p) }

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
        for tick in DialGeometry.hourTicks(now: layout.now) {
            let t = tick.date, major = tick.major
            let a = layout.angle(t)
            var p = Path()
            p.move(to: CGPoint(x: c.x + cos(a) * (layout.outer + 20), y: c.y + sin(a) * (layout.outer + 20)))
            p.addLine(to: CGPoint(x: c.x + cos(a) * (layout.outer + (major ? 30 : 25)), y: c.y + sin(a) * (layout.outer + (major ? 30 : 25))))
            gc.stroke(p, with: .color(DialPalette.tick), lineWidth: major ? 1.5 : 1)
            // An hour label within 75 minutes of now would crowd the "now" label.
            if tick.labeled {
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

        // Rings: a track for a lane with lines today, a hairline for one without,
        // and each session's stretches of lines (on to now while it works or
        // waits on you), in its state color.
        var times: [String: [Date]] = [:]
        for e in entries {
            guard let lane = layout.lane(for: e) else { continue }
            times[lane.id, default: []].append(e.date)
        }
        for lane in layout.lanes {
            let focused = focusLane == nil || focusLane == lane.id
            var ring = Path()
            ring.addEllipse(in: CGRect(x: c.x - lane.radius, y: c.y - lane.radius, width: lane.radius * 2, height: lane.radius * 2))
            if let ts = times[lane.id] {
                gc.stroke(ring, with: .color(focused ? DialPalette.track : DialPalette.track.opacity(0.45)), lineWidth: 14)
                for stretch in DialGeometry.stretches(ts, active: lane.active, now: layout.now) {
                    arc(&gc, from: stretch.lowerBound, to: stretch.upperBound, radius: lane.radius,
                        color: lane.color.opacity(focused ? 0.55 : 0.2), width: 6)
                }
            } else {
                gc.stroke(ring, with: .color(DialPalette.tick.opacity(focused ? 0.7 : 0.3)), lineWidth: 1)
            }
            // Working or waiting on you now: a mark at now in its state color, so
            // the dial agrees with the recap even when the session has said nothing lately.
            if lane.active {
                arc(&gc, from: layout.now.addingTimeInterval(-1200), to: layout.now, radius: lane.radius,
                    color: lane.color.opacity(focused ? 0.9 : 0.3), width: 6)
            }
        }

        // Each ring's name, just past now, where a day-old moment would sit.
        for lane in layout.lanes {
            let focused = focusLane == nil || focusLane == lane.id
            let a = -Double.pi / 2 + 0.16   // clockwise of now, clear of the newest dots
            let p = CGPoint(x: c.x + cos(a) * lane.radius, y: c.y + sin(a) * lane.radius)
            let name = Text(lane.id == DialLayout.youLane ? "You" : Self.shortName(lane.name))
                .font(.caption2.weight(.medium))
                .foregroundStyle(lane.color.opacity(focused ? 0.95 : 0.4))
            gc.draw(name, at: CGPoint(x: p.x + 6, y: p.y), anchor: .leading)
        }

        // A dot per line: nearer now is brighter, a match for the search is larger.
        // Lines that would sit on top of each other on a ring draw as one dot.
        for dot in dots {
            let e = dot.entry, p = dot.point
            guard let lane = layout.lane(for: e) else { continue }
            let age = layout.now.timeIntervalSince(e.date) / DialLayout.day
            let dim = focusLane == nil || focusLane == lane.id ? 1.0 : 0.3
            let lit = highlighted.isEmpty || highlighted.contains(e.id)
            let r: CGFloat = (e.lineKind == .need || e.asksYou ? 6 : 4.5) * (lit && !highlighted.isEmpty ? 1.4 : 1)
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

    /// A ring label short enough to stay clear of the dots near now.
    static func shortName(_ name: String) -> String {
        let t = SessionStyle.title(name)
        return t.count <= 16 ? t : String(t.prefix(15)) + "\u{2026}"
    }

    private func anchor(for a: Double) -> UnitPoint {
        UnitPoint(x: 0.5 - cos(a) * 0.5, y: 0.5 - sin(a) * 0.5)
    }

    private func callout(_ dot: DialDot) -> some View {
        let e = dot.entry, p = dot.point
        let right = p.x < layout.size / 2
        let f = Date.FormatStyle().hour().minute()
        return VStack(alignment: .leading, spacing: 3) {
            if dot.count > 1 {
                Text("\(dot.count) lines, \(dot.oldest.formatted(f)) to \(e.date.formatted(f)). The newest:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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

    /// A line this new types in here and waits to join the list below.
    static func isFresh(_ e: HistoryEntry?, now: Date = Date()) -> Bool {
        guard let e else { return false }
        return now.timeIntervalSince(e.date) < 45
    }

    var body: some View {
        if let entry, !Self.isFresh(entry) {
            Text("Quiet since \(entry.date.formatted(date: .omitted, time: .shortened))")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else if let entry {
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
