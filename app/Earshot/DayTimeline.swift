import EarshotKit
import SwiftUI

/// The day as a strip: the last 24 hours left to right with now at the right
/// end, a dot per line in its color, and the stretch since you last looked
/// shaded amber. Hover a dot to read its line; click it to open its session.
struct DayTimeline: View {
    let entries: [HistoryEntry]
    let since: Date?
    let now: Date
    let pick: (HistoryEntry) -> Void
    @State private var hovered: Placed?

    private static let day: TimeInterval = 24 * 3600
    private static let trackHeight: CGFloat = 16
    private static let labelRow: CGFloat = 16

    /// A dot where it sits, with how many lines it stands for.
    struct Placed: Equatable {
        let entry: HistoryEntry
        let x: CGFloat
        var count: Int
    }

    var body: some View {
        GeometryReader { geo in
            let dots = place(width: geo.size.width)
            ZStack(alignment: .topLeading) {
                Canvas { gc, size in draw(&gc, size: size, dots: dots) }
                if let h = hovered { callout(h, width: geo.size.width) }
            }
            .contentShape(.rect)
            .onContinuousHover { phase in
                switch phase {
                case .active(let p): hovered = nearest(dots, p.x)
                case .ended: hovered = nil
                }
            }
            .onTapGesture { p in if let d = nearest(dots, p.x) { pick(d.entry) } }
        }
        .frame(height: Self.trackHeight + Self.labelRow + 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(summary)
    }

    // MARK: Layout

    private func x(_ t: Date, width: CGFloat) -> CGFloat {
        let back = min(max(now.timeIntervalSince(t), 0), Self.day)
        return width * CGFloat(1 - back / Self.day)
    }

    /// Lines within 14 points of each other draw as one dot; the newest stands for them.
    private func place(width: CGFloat) -> [Placed] {
        var out: [Placed] = []
        for e in entries.sorted(by: { $0.date > $1.date }) {
            let px = min(max(x(e.date, width: width), 6), width - 6)
            if let i = out.firstIndex(where: { abs($0.x - px) < 14 }) { out[i].count += 1 } else {
                out.append(Placed(entry: e, x: px, count: 1))
            }
        }
        return out
    }

    private func nearest(_ dots: [Placed], _ px: CGFloat) -> Placed? {
        dots.filter { abs($0.x - px) < 10 }.min { abs($0.x - px) < abs($1.x - px) }
    }

    // MARK: Drawing

    private func draw(_ gc: inout GraphicsContext, size: CGSize, dots: [Placed]) {
        let w = size.width, h = Self.trackHeight
        let track = Path(roundedRect: CGRect(x: 0, y: 0, width: w, height: h), cornerRadius: h / 2)
        gc.fill(track, with: .color(ActivityPalette.track))
        // Since you last looked.
        if let since, now.timeIntervalSince(since) > 60 {
            let sx = x(since, width: w)
            var shade = gc
            shade.clip(to: track)
            shade.fill(Path(CGRect(x: sx, y: 0, width: w - sx, height: h)), with: .color(ActivityPalette.voice.opacity(0.13)))
            shade.fill(Path(CGRect(x: sx, y: 0, width: 1.5, height: h)), with: .color(ActivityPalette.voice.opacity(0.7)))
        }
        for d in dots {
            let urgent = d.entry.asksYou
            let r: CGFloat = urgent ? 5 : 3.5
            let rect = CGRect(x: d.x - r, y: h / 2 - r, width: r * 2, height: r * 2)
            gc.fill(Path(ellipseIn: rect.insetBy(dx: -1.5, dy: -1.5)), with: .color(ActivityPalette.track))
            gc.fill(Path(ellipseIn: rect), with: .color(ActivityPalette.color(d.entry)))
        }
        drawLabels(&gc, width: w)
    }

    /// A label every six hours, and "now" at the right end.
    private func drawLabels(_ gc: inout GraphicsContext, width w: CGFloat) {
        let y = Self.trackHeight + 4 + Self.labelRow / 2
        let cal = Calendar.current
        var t = cal.dateInterval(of: .hour, for: now)?.start ?? now
        let f = Date.FormatStyle().hour()
        while now.timeIntervalSince(t) < Self.day {
            let hour = cal.component(.hour, from: t)
            if hour % 6 == 0, now.timeIntervalSince(t) > 3 * 3600 {
                let text = Text(t.formatted(f)).font(.caption2.monospacedDigit()).foregroundColor(Color(white: 0.56))
                gc.draw(text, at: CGPoint(x: x(t, width: w), y: y), anchor: .center)
            }
            t = t.addingTimeInterval(-3600)
        }
        gc.draw(Text("now").font(.caption2.weight(.semibold)).foregroundColor(ActivityPalette.voice),
                at: CGPoint(x: w, y: y), anchor: .trailing)
    }

    private func callout(_ d: Placed, width: CGFloat) -> some View {
        let e = d.entry
        let text = e.kind == .heard ? "\u{201C}\(e.text)\u{201D}" : e.text
        let meta = [e.sessionName.map(SessionStyle.title), e.date.formatted(date: .omitted, time: .shortened),
                    d.count > 1 ? "+\(d.count - 1) more" : nil].compactMap { $0 }.joined(separator: "  ")
        let w: CGFloat = 260
        return VStack(alignment: .leading, spacing: 3) {
            Text(text).font(.callout).lineLimit(3)
            Text(meta).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(width: w, alignment: .leading)
        .background(ActivityPalette.raised, in: .rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(ActivityPalette.tick.opacity(0.6), lineWidth: 1))
        .shadow(color: .black.opacity(0.4), radius: 12, y: 4)
        .fixedSize(horizontal: false, vertical: true)
        .offset(x: min(max(d.x - w / 2, 0), width - w), y: -8)
        .alignmentGuide(.top) { $0[.bottom] }
        .allowsHitTesting(false)
    }

    private var summary: String {
        let said = entries.filter { $0.kind == .said }.count
        let heard = entries.count - said
        return "Today: Earshot spoke \(said) times and you asked \(heard) times. Hover a dot to read it."
    }
}
