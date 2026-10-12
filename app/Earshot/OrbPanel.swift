import AppKit
import EarshotKit
import SwiftUI

/// A small orb at the top of the screen while Earshot hears a command, works
/// on it, or talks. It never takes focus and ignores clicks.
@MainActor final class OrbPanel {
    static let size: CGFloat = 112

    private let panel: NSPanel
    private let model: AppModel
    private var shown = false

    init(model: AppModel) {
        self.model = model
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: Self.size, height: Self.size),
                        styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = NSHostingView(rootView: OrbView().environment(model))
        observe()
    }

    private func observe() {
        withObservationTracking {
            _ = model.listenPhase
            _ = model.speechState
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.announce()
                self?.update()
                self?.observe()
            }
        }
        update()
    }

    private var lastPhase: Listener.Phase = .off

    /// VoiceOver does not see a panel that never takes focus, so say the phase.
    private func announce() {
        let phase = model.listenPhase
        defer { lastPhase = phase }
        guard phase != lastPhase else { return }
        let text: String
        switch phase {
        case .capturing: text = "Listening"
        case .transcribing: text = "Working on it"
        default: return
        }
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    private func update() {
        if OrbMode(model) != nil {
            guard let screen = NSScreen.main else { return }
            let f = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: f.midX - panel.frame.width / 2, y: f.maxY - panel.frame.height - 8))
            guard !shown else { return }
            shown = true
            if !panel.isVisible { panel.alphaValue = 0 }
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { $0.duration = 0.18; panel.animator().alphaValue = 1 }
        } else if shown {
            shown = false
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; panel.animator().alphaValue = 0 },
                                                 completionHandler: { [weak self] in
                Task { @MainActor in
                    // Shown again while it faded out.
                    guard let self, !self.shown else { return }
                    self.panel.orderOut(nil)
                }
            })
        }
    }
}

/// What the orb shows. Capturing wins over working, which wins over speaking.
enum OrbMode: Equatable {
    case listening, working, speaking

    @MainActor init?(_ model: AppModel) {
        switch model.listenPhase {
        case .capturing: self = .listening
        case .transcribing: self = .working
        default:
            guard model.speechState == .speaking else { return nil }
            self = .speaking
        }
    }

    var label: String {
        switch self {
        case .listening: "Listening"
        case .working: "Working on it"
        case .speaking: "Earshot is speaking"
        }
    }

    /// Blue while listening, violet while working, amber while speaking.
    var rgb: SIMD3<Double> {
        switch self {
        case .listening: [0.39, 0.77, 1.0]
        case .working: [0.67, 0.56, 1.0]
        case .speaking: [1.0, 0.74, 0.42]
        }
    }
}

private struct OrbView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sphere = ParticleSphere()

    var body: some View {
        let mode = OrbMode(model)
        TimelineView(.animation(paused: mode == nil)) { timeline in
            Canvas { gc, size in
                let target: Float = switch mode {
                case .listening: model.micLevel?.value ?? 0
                case .speaking: model.speakLevel?.value ?? 0
                default: 0
                }
                sphere.step(to: timeline.date, mode: mode, level: target, reduceMotion: reduceMotion)
                sphere.draw(in: &gc, size: size)
            }
        }
        .frame(width: OrbPanel.size, height: OrbPanel.size)
        .glassEffect(.regular.tint(.black.opacity(0.55)), in: .circle)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(mode?.label ?? "Earshot")
    }
}

/// About 380 points on a turning sphere. Listening, the surface pushes out
/// with the mic level; working, it turns faster while a bright band rolls
/// down it; speaking, it swells with Earshot's voice. With Reduce Motion it
/// stops turning and keeps only brightness and a small size change.
/// Advanced from the timeline's date on each frame, never on its own.
@MainActor final class ParticleSphere {
    private struct Point { var x, y, z, seed: Double }

    private let points: [Point]
    private var last: Date?
    private var t: Double = 0
    private var rotation: Double = 0
    private var level: Double = 0
    private var color: SIMD3<Double> = OrbMode.listening.rgb
    private var mode: OrbMode = .listening
    private var reduceMotion = false
    private var dt: Double = 0

    init(count: Int = 380) {
        let golden = Double.pi * (3 - 5.0.squareRoot())
        points = (0..<count).map { i in
            let y = 1 - (Double(i) + 0.5) / Double(count) * 2
            let r = (1 - y * y).squareRoot(), phi = Double(i) * golden
            return Point(x: cos(phi) * r, y: y, z: sin(phi) * r, seed: .random(in: 0..<1))
        }
    }

    /// `mode` nil means the panel is fading out: keep drawing the last mode, settling.
    func step(to now: Date, mode: OrbMode?, level target: Float, reduceMotion: Bool) {
        dt = last.map { min(0.05, max(0, now.timeIntervalSince($0))) } ?? 0
        last = now
        t += dt
        if let mode { self.mode = mode }
        self.reduceMotion = reduceMotion
        // The levels arrive 12 to 20 times a second: rise fast, fall slower.
        let goal = mode == nil ? 0 : Double(target)
        let tau = goal > level ? 0.04 : 0.14
        level += (goal - level) * min(1, dt / tau)
        color += (self.mode.rgb - color) * min(1, dt / 0.25)
        if !reduceMotion { rotation += dt * (self.mode == .working ? 1.5 : 0.3 + level * 1.1) }
    }

    func draw(in gc: inout GraphicsContext, size: CGSize) {
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        let radius = size.width * 0.3, L = level, working = mode == .working, speaking = mode == .speaking
        let tint = Color(red: color.x, green: color.y, blue: color.z)
        let breathe = reduceMotion && working ? 0.65 + 0.35 * sin(t * 2.2) : 1
        let tt = reduceMotion ? 0 : t
        let tilt = 0.42, ct = cos(tilt), st = sin(tilt), cr = cos(rotation), sr = sin(rotation)

        gc.blendMode = .plusLighter
        let glow = radius * 1.25
        gc.fill(Path(ellipseIn: CGRect(x: c.x - glow, y: c.y - glow, width: glow * 2, height: glow * 2)),
                with: .radialGradient(Gradient(colors: [tint.opacity((0.08 + 0.42 * L) * breathe), tint.opacity(0)]),
                                      center: c, startRadius: 0, endRadius: glow))

        let dotScale = size.width / 112
        for p in points {
            let x1 = p.x * cr + p.z * sr, z1 = -p.x * sr + p.z * cr
            let y1 = p.y * ct - z1 * st, z2 = p.y * st + z1 * ct
            var d: Double, band = 1.0
            if reduceMotion {
                d = 1 + 0.12 * L
            } else if working {
                band = 0.5 + 0.5 * sin(p.y * 7 - tt * 5)
                d = 1 + 0.07 * band
            } else {
                let n = 0.5 + 0.5 * sin(p.seed * 40 + tt * (speaking ? 7 : 5))
                d = 1 + L * (speaking ? 0.18 + 0.32 * n : 0.08 + 0.32 * n)
            }
            let f = 3 / (3 - z2), depth = (z2 + 1) / 2
            let px = c.x + x1 * radius * d * f, py = c.y + y1 * radius * d * f
            let alpha = (0.16 + 0.84 * depth) * (working ? 0.3 + 0.7 * band : 0.75 + 0.25 * L) * breathe
            let r = (0.5 + 0.7 * depth) * dotScale * (1 + L * 0.4)
            gc.fill(Path(ellipseIn: CGRect(x: px - r, y: py - r, width: r * 2, height: r * 2)), with: .color(tint.opacity(alpha)))
        }
    }
}
