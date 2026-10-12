import AppKit

/// The menu bar icon: a small dotted sphere, the orb's shape, drawn as a
/// template so it follows the menu bar's color.
enum MenuIcon {
    enum State: Hashable {
        /// Nothing to do: the plain sphere.
        case idle
        /// The wake word listens: a dot in the middle.
        case ready
        /// Listening to a command, working on it, or speaking: a fuller sphere.
        case active
        /// Lines are waiting (a call, full screen): a badge.
        case holding
        /// Muted: faded, with a slash.
        case muted

        var label: String {
            switch self {
            case .idle: "Earshot"
            case .ready: "Earshot, listening for Hey Earshot"
            case .active: "Earshot, busy"
            case .holding: "Earshot, lines waiting"
            case .muted: "Earshot, muted"
            }
        }
    }

    @MainActor private static var cache: [State: NSImage] = [:]

    @MainActor static func image(_ state: State) -> NSImage {
        if let i = cache[state] { return i }
        let i = draw(state)
        cache[state] = i
        return i
    }

    private static func draw(_ state: State) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let c = CGPoint(x: 9, y: 9)
            let radius: CGFloat = state == .active ? 7.4 : 6.8
            let fade: CGFloat = switch state {
            case .muted: 0.45
            case .holding: 0.7
            default: 1
            }
            // 46 points on a tilted sphere, nearer ones larger and darker.
            let n = 46, golden = Double.pi * (3 - 5.0.squareRoot()), tilt = 0.5
            for i in 0..<n {
                let y = 1 - (Double(i) + 0.5) / Double(n) * 2
                let r = (1 - y * y).squareRoot(), phi = Double(i) * golden
                let x = cos(phi) * r, z = sin(phi) * r
                let y1 = y * cos(tilt) - z * sin(tilt), z1 = y * sin(tilt) + z * cos(tilt)
                let depth = (z1 + 1) / 2
                let dot = CGFloat(0.42 + 0.5 * depth) * (state == .active ? 1.12 : 1)
                let p = CGPoint(x: c.x + CGFloat(x) * radius, y: c.y + CGFloat(y1) * radius)
                ctx.setFillColor(NSColor.black.withAlphaComponent(CGFloat(0.3 + 0.7 * depth) * fade).cgColor)
                ctx.fillEllipse(in: CGRect(x: p.x - dot, y: p.y - dot, width: dot * 2, height: dot * 2))
            }
            switch state {
            case .ready, .active:
                // A center dot with a gap around it, so it doesn't blur into the sphere.
                let r: CGFloat = state == .active ? 2.8 : 1.8
                ctx.setBlendMode(.clear)
                ctx.fillEllipse(in: CGRect(x: c.x - r - 1, y: c.y - r - 1, width: (r + 1) * 2, height: (r + 1) * 2))
                ctx.setBlendMode(.normal)
                ctx.setFillColor(NSColor.black.cgColor)
                ctx.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
            case .holding:
                // A badge at the top right, cut out of the sphere so it reads at a glance.
                let b = CGPoint(x: 14.6, y: 14.6)
                ctx.setBlendMode(.clear)
                ctx.fillEllipse(in: CGRect(x: b.x - 3.6, y: b.y - 3.6, width: 7.2, height: 7.2))
                ctx.setBlendMode(.normal)
                ctx.setFillColor(NSColor.black.cgColor)
                ctx.fillEllipse(in: CGRect(x: b.x - 2.4, y: b.y - 2.4, width: 4.8, height: 4.8))
            case .muted:
                ctx.setLineCap(.round)
                ctx.setBlendMode(.clear)
                ctx.setLineWidth(3.6)
                ctx.move(to: CGPoint(x: 2.5, y: 15.5)); ctx.addLine(to: CGPoint(x: 15.5, y: 2.5)); ctx.strokePath()
                ctx.setBlendMode(.normal)
                ctx.setStrokeColor(NSColor.black.cgColor)
                ctx.setLineWidth(1.5)
                ctx.move(to: CGPoint(x: 2.5, y: 15.5)); ctx.addLine(to: CGPoint(x: 15.5, y: 2.5)); ctx.strokePath()
            case .idle:
                break
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
