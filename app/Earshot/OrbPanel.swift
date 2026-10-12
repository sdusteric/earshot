import AppKit
import EarshotKit
import SwiftUI

/// A small orb at the top of the screen while Earshot hears a command, works
/// on it, or talks. It never takes focus. Drag it anywhere; it stays there
/// until you double-click it, which puts it back at the top center.
@MainActor final class OrbPanel {
    static let size: CGFloat = 112
    private static let positionKey = "orbCenter"

    private let panel: NSPanel
    private let glass = NSGlassEffectView()
    private let model: AppModel
    private var shown = false
    /// True while Earshot moves the panel itself, so only your drags are saved.
    private var placing = false

    init(model: AppModel) {
        self.model = model
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: Self.size, height: Self.size),
                        styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false   // the glass draws its own
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        glass.style = .regular
        glass.cornerRadius = Self.size / 2
        if #available(macOS 27, *) { glass.effectIsInteractive = true }
        let hosting = OrbHostingView(rootView: AnyView(OrbView().environment(model)))
        hosting.onReset = { [weak self] in self?.resetPosition() }
        glass.contentView = hosting
        panel.contentView = glass
        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveMove() }
        }
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
        if let mode = OrbMode(model) {
            glass.tintColor = mode.glassTint
            guard !shown else { return }
            shown = true
            if !panel.isVisible {
                place()
                panel.alphaValue = 0
            }
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

    /// Where you last dragged it, if that spot is still on a screen; otherwise
    /// the top center of the screen you are using.
    private func place() {
        let half = Self.size / 2
        var center: NSPoint?
        if let saved = UserDefaults.standard.array(forKey: Self.positionKey) as? [Double], saved.count == 2 {
            let p = NSPoint(x: saved[0], y: saved[1])
            if NSScreen.screens.contains(where: { $0.frame.insetBy(dx: half, dy: half).contains(p) }) { center = p }
        }
        if center == nil, let f = NSScreen.main?.visibleFrame {
            center = NSPoint(x: f.midX, y: f.maxY - half - 8)
        }
        guard let c = center else { return }
        placing = true
        panel.setFrameOrigin(NSPoint(x: c.x - half, y: c.y - half))
        placing = false
    }

    private func saveMove() {
        guard !placing else { return }
        let f = panel.frame
        UserDefaults.standard.set([Double(f.midX), Double(f.midY)], forKey: Self.positionKey)
    }

    private func resetPosition() {
        UserDefaults.standard.removeObject(forKey: Self.positionKey)
        NSAnimationContext.runAnimationGroup { _ in place() }
    }
}

/// Drags the panel from anywhere on the orb. The panel never becomes key, so
/// the app you are using keeps focus. A double-click asks for the reset.
private final class OrbHostingView: NSHostingView<AnyView> {
    var onReset: (() -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onReset?(); return }
        window?.performDrag(with: event)
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
    /// On light glass the colors are deeper, so the points stay visible.
    func rgb(dark: Bool) -> SIMD3<Double> {
        switch (self, dark) {
        case (.listening, true): [0.39, 0.77, 1.0]
        case (.working, true): [0.67, 0.56, 1.0]
        case (.speaking, true): [1.0, 0.74, 0.42]
        case (.listening, false): [0.0, 0.42, 0.9]
        case (.working, false): [0.4, 0.27, 0.88]
        case (.speaking, false): [0.86, 0.43, 0.0]
        }
    }

    /// A light wash of the same color over the glass.
    var glassTint: NSColor {
        let c = rgb(dark: true)
        return NSColor(red: c.x, green: c.y, blue: c.z, alpha: 0.14)
    }
}

private struct OrbView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
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
                sphere.step(to: timeline.date, mode: mode, level: target, reduceMotion: reduceMotion,
                            dark: colorScheme == .dark)
                sphere.draw(in: &gc, size: size)
            }
        }
        .frame(width: OrbPanel.size, height: OrbPanel.size)
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
    private var color: SIMD3<Double> = OrbMode.listening.rgb(dark: true)
    private var dark = true
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
    func step(to now: Date, mode: OrbMode?, level target: Float, reduceMotion: Bool, dark: Bool) {
        dt = last.map { min(0.05, max(0, now.timeIntervalSince($0))) } ?? 0
        last = now
        t += dt
        if let mode { self.mode = mode }
        self.reduceMotion = reduceMotion
        self.dark = dark
        // The levels arrive 12 to 20 times a second: rise fast, fall slower.
        let goal = mode == nil ? 0 : Double(target)
        let tau = goal > level ? 0.04 : 0.14
        level += (goal - level) * min(1, dt / tau)
        color += (self.mode.rgb(dark: dark) - color) * min(1, dt / 0.25)
        if !reduceMotion { rotation += dt * (self.mode == .working ? 1.5 : 0.3 + level * 1.1) }
    }

    func draw(in gc: inout GraphicsContext, size: CGSize) {
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        let radius = size.width * 0.3, L = level, working = mode == .working, speaking = mode == .speaking
        let tint = Color(red: color.x, green: color.y, blue: color.z)
        let breathe = reduceMotion && working ? 0.65 + 0.35 * sin(t * 2.2) : 1
        let tt = reduceMotion ? 0 : t
        let tilt = 0.42, ct = cos(tilt), st = sin(tilt), cr = cos(rotation), sr = sin(rotation)

        // Light adds up on dark glass; on light glass points draw over each other.
        gc.blendMode = dark ? .plusLighter : .normal
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
