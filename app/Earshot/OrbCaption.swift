import AppKit
import EarshotKit
import SwiftUI

/// What the floating orb's caption says: that Earshot listens, what it heard
/// (the plain words, as the history keeps them), or the line it is saying.
struct OrbCaption: Equatable {
    enum Kind: Equatable { case listening, heard, saying }
    let kind: Kind
    let text: String

    static let listening = OrbCaption(kind: .listening, text: "Listening")
}

/// A small caption on dark glass under the floating orb, at most two lines.
/// It shows exactly while the orb does: OrbPanel keeps both up a few seconds
/// after Earshot finishes, then hides them together. It never takes focus or
/// clicks. What it shows is never logged.
@MainActor final class CaptionPanel {
    static let maxWidth: CGFloat = 340
    private static let gap: CGFloat = 6

    private let panel: NSPanel
    private let glass = NSGlassEffectView()
    private let hosting: NSHostingController<AnyView>
    private let model: AppModel
    private let orbFrame: () -> NSRect
    /// Whether the orb is up, lingering included (see OrbPanel.linger).
    private let orbShown: () -> Bool
    private var shown = false
    private var fadeTask: Task<Void, Never>?
    private var lastAnnounced: OrbCaption?

    init(model: AppModel, orbFrame: @escaping () -> NSRect, orbShown: @escaping () -> Bool) {
        self.model = model
        self.orbFrame = orbFrame
        self.orbShown = orbShown
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 120, height: 32),
                        styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        glass.style = .regular
        // The orb's dark glass, with a darker wash so white text reads over any window.
        glass.appearance = NSAppearance(named: .darkAqua)
        glass.tintColor = NSColor.black.withAlphaComponent(0.35)
        hosting = NSHostingController(rootView: AnyView(CaptionView().environment(model)))
        hosting.sizingOptions = []
        glass.contentView = hosting.view
        panel.contentView = glass
        observe()
    }

    private func observe() {
        withObservationTracking {
            _ = model.caption
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.update()
                self?.observe()
            }
        }
        update()
    }

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// Called on every change of the caption, and by OrbPanel whenever the orb shows or hides.
    func update() {
        if orbShown(), let caption = model.caption {
            announce(caption)
            layout()
            guard !shown else { return }
            shown = true
            if !panel.isVisible { panel.alphaValue = 0 }
            panel.orderFrontRegardless()
            fade(to: 1, over: 0.18)
        } else if shown, !orbShown() {
            hide()
        }
    }

    private func hide() {
        shown = false
        fade(to: 0, over: 0.25)
        // A stale caption must not flash when the orb next shows.
        model.caption = nil
        lastAnnounced = nil
    }

    /// Sized to its words, up to two lines, and centered under the orb; above
    /// it when the orb sits too low on its screen for the caption to fit.
    private func layout() {
        var size = hosting.sizeThatFits(in: CGSize(width: Self.maxWidth, height: 200))
        size.width = ceil(min(size.width, Self.maxWidth))
        size.height = ceil(size.height)
        glass.cornerRadius = min(size.height / 2, 16)
        let orb = orbFrame()
        let screen = NSScreen.screens.first { $0.frame.intersects(orb) }?.visibleFrame ?? NSScreen.main?.visibleFrame ?? orb
        var y = orb.minY - Self.gap - size.height
        if y < screen.minY { y = orb.maxY + Self.gap }
        let x = min(max(orb.midX - size.width / 2, screen.minX + 8), screen.maxX - size.width - 8)
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
    }

    /// Follows the orb when you drag it.
    func orbMoved() {
        guard shown else { return }
        layout()
    }

    /// VoiceOver does not see a panel that never takes focus, so say what was
    /// heard. Earshot's own lines are already heard aloud, so they are not said twice.
    private func announce(_ c: OrbCaption) {
        guard c != lastAnnounced else { return }
        lastAnnounced = c
        guard c.kind == .heard else { return }
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: "Heard: \(c.text)",
                                        .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    /// Steps the alpha itself, as the orb does. With Reduce Motion it changes at once.
    private func fade(to target: CGFloat, over seconds: Double) {
        fadeTask?.cancel()
        if reduceMotion {
            panel.alphaValue = target
            if target == 0 { panel.orderOut(nil) }
            return
        }
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
}

/// The caption's words: a dot in the state's color (blue for you, amber for
/// Earshot's voice), then the text in white, or "Listening" in secondary.
private struct CaptionView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let caption = model.caption ?? .listening
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle()
                .fill(caption.kind == .saying ? ActivityPalette.voice : ActivityPalette.you)
                .frame(width: 6, height: 6)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                .accessibilityHidden(true)
            Text(caption.kind == .heard ? "\u{201C}\(caption.text)\u{201D}" : caption.text)
                .font(.callout)
                .foregroundStyle(caption.kind == .listening ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                .lineLimit(2)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .combine)
    }
}
