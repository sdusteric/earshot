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
    /// What was heard or said, under the orb (see CaptionPanel).
    private var caption: CaptionPanel?
    /// True while Earshot moves the panel itself, so only your drags are saved.
    private var placing = false

    init(model: AppModel) {
        self.model = model
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: Self.size, height: Self.size),
                        styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.level = .statusBar   // after isFloatingPanel, which sets the floating level
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false   // the glass draws its own
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        glass.style = .regular
        // Always the dark glass: the light points need a dark backing to stand
        // out, whatever is behind the orb and whatever the system appearance.
        glass.appearance = NSAppearance(named: .darkAqua)
        glass.cornerRadius = Self.size / 2
        if #available(macOS 27, *) { glass.effectIsInteractive = true }
        // Out of sight (the orb is off in Settings, or the panel faded out), it stops drawing.
        let hosting = OrbHostingView(rootView: AnyView(OrbView().environment(model).tracksWindowPresence()))
        hosting.onReset = { [weak self] in self?.resetPosition() }
        glass.contentView = hosting
        panel.contentView = glass
        caption = CaptionPanel(model: model) { [panel] in panel.frame }
        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.caption?.orbMoved()
                self?.saveMove()
            }
        }
        observe()
    }

    private func observe() {
        withObservationTracking {
            _ = model.listenPhase
            _ = model.speechState
            _ = model.config.showOrb
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
        if model.config.showOrb, let mode = OrbMode(model) {
            glass.tintColor = mode.glassTint(model.config.orbColor)
            guard !shown else { return }
            shown = true
            if !panel.isVisible {
                place()
                panel.alphaValue = 0
            }
            panel.orderFrontRegardless()
            fade(to: 1, over: 0.18)
        } else if shown {
            shown = false
            fade(to: 0, over: 0.25)
        }
    }

    private var fadeTask: Task<Void, Never>?

    /// Steps the alpha itself. The window animator runs its fade on a thread
    /// of its own, and that fade was seen to stall at alpha 0, leaving the orb
    /// invisible for a whole line.
    private func fade(to target: CGFloat, over seconds: Double) {
        fadeTask?.cancel()
        let from = panel.alphaValue, steps = max(1, Int(seconds * 60))
        fadeTask = Task { [weak self] in
            for i in 1...steps {
                try? await Task.sleep(for: .seconds(seconds / Double(steps)))
                guard let self, !Task.isCancelled else { return }
                self.panel.alphaValue = from + (target - from) * CGFloat(i) / CGFloat(steps)
            }
            guard let self, !Task.isCancelled else { return }
            if target == 0 { self.panel.orderOut(nil) }
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
        Self.forgetPosition()
        place()
    }

    /// The next time it shows, the orb is back at the top center.
    static func forgetPosition() { UserDefaults.standard.removeObject(forKey: positionKey) }
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
/// Working covers transcribing and the thinking after it, until the answer
/// starts, so the orb never drops out between your words and Earshot's.
enum OrbMode: Equatable {
    case listening, working, speaking

    @MainActor init?(_ model: AppModel) {
        switch model.listenPhase {
        case .capturing: self = .listening
        case .transcribing: self = .working
        default:
            if model.speechState == .speaking { self = .speaking; return }
            guard model.thinking else { return nil }
            self = .working
        }
    }

    var label: String {
        switch self {
        case .listening: "Listening"
        case .working: "Working on it"
        case .speaking: "Earshot is speaking"
        }
    }

    /// By state: blue while listening, violet while working, amber while
    /// speaking. A fixed color keeps one hue; the motion still shows the state.
    func rgb(_ choice: EarshotConfig.OrbColor) -> SIMD3<Double> {
        switch choice {
        case .state:
            switch self {
            case .listening: [0.39, 0.77, 1.0]
            case .working: [0.67, 0.56, 1.0]
            case .speaking: [1.0, 0.74, 0.42]
            }
        case .blue: [0.39, 0.77, 1.0]
        case .purple: [0.72, 0.58, 1.0]
        case .orange: [1.0, 0.66, 0.3]
        case .green: [0.45, 0.95, 0.6]
        case .pink: [1.0, 0.55, 0.78]
        case .white: [0.95, 0.96, 1.0]
        }
    }

    /// A light wash of the same color over the glass.
    func glassTint(_ choice: EarshotConfig.OrbColor) -> NSColor {
        let c = rgb(choice)
        return NSColor(red: c.x, green: c.y, blue: c.z, alpha: 0.16)
    }
}

/// The particle sphere. The floating panel uses it at full size on glass; the
/// Activity window shows a smaller one that rests in white while Earshot is idle.
struct OrbView: View {
    var size: CGFloat = OrbPanel.size
    /// The color while nothing is happening; nil keeps the last state's color.
    var restingColor: EarshotConfig.OrbColor?
    /// Turns slowly while idle instead of stopping (the Activity window's orb).
    var spinsWhenIdle = false
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.windowPresence) private var presence
    @State private var sphere = ParticleSphere()

    var body: some View {
        let mode = OrbMode(model)
        let color = mode == nil ? (restingColor ?? model.config.orbColor) : model.config.orbColor
        // Idle, a slow turn needs far fewer frames. Active, 60 a second is smooth and
        // half the work of a 120 Hz display's rate. Out of sight, none: SwiftUI keeps a
        // timeline running in a covered, minimized or hidden window.
        let paused = Cadence.orbPaused(active: mode != nil, spinsWhenIdle: spinsWhenIdle, visible: presence.visible)
        TimelineView(.animation(minimumInterval: mode == nil ? 1.0 / 30 : 1.0 / 60, paused: paused)) { timeline in
            Canvas { gc, size in
                let target: Float = switch mode {
                case .listening: model.micLevel?.value ?? 0
                case .speaking: model.speakLevel?.value ?? 0
                default: 0
                }
                sphere.step(to: timeline.date, mode: mode, level: target, reduceMotion: reduceMotion,
                            color: color, idleSpin: spinsWhenIdle)
                sphere.draw(in: &gc, size: size)
            }
        }
        .frame(width: size, height: size)
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
    private var color: SIMD3<Double> = OrbMode.listening.rgb(.state)
    private var choice: EarshotConfig.OrbColor = .state
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
    func step(to now: Date, mode: OrbMode?, level target: Float, reduceMotion: Bool, color choice: EarshotConfig.OrbColor,
              idleSpin: Bool = false) {
        // The first frame takes the color at once; later ones fade toward it.
        if last == nil { color = (mode ?? self.mode).rgb(choice) }
        dt = last.map { min(0.05, max(0, now.timeIntervalSince($0))) } ?? 0
        last = now
        t += dt
        if let mode { self.mode = mode }
        self.reduceMotion = reduceMotion
        self.choice = choice
        // The levels arrive 12 to 20 times a second: rise fast, fall slower.
        let goal = mode == nil ? 0 : Double(target)
        let tau = goal > level ? 0.04 : 0.14
        level += (goal - level) * min(1, dt / tau)
        color += (self.mode.rgb(choice) - color) * min(1, dt / 0.25)
        if !reduceMotion {
            let speed = mode == nil && idleSpin ? 0.15 : (self.mode == .working ? 1.5 : 0.3 + level * 1.1)
            rotation += dt * speed
        }
    }

    func draw(in gc: inout GraphicsContext, size: CGSize) {
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        let radius = size.width * 0.3, L = level, working = mode == .working, speaking = mode == .speaking
        let tint = Color(red: color.x, green: color.y, blue: color.z)
        let breathe = reduceMotion && working ? 0.65 + 0.35 * sin(t * 2.2) : 1
        let tt = reduceMotion ? 0 : t
        let tilt = 0.42, ct = cos(tilt), st = sin(tilt), cr = cos(rotation), sr = sin(rotation)

        // A dark disc under the points, so they read even where the glass is clear.
        let backing = size.width / 2
        gc.fill(Path(ellipseIn: CGRect(x: c.x - backing, y: c.y - backing, width: backing * 2, height: backing * 2)),
                with: .color(.black.opacity(0.28)))
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
