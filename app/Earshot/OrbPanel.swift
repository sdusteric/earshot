import AppKit
import EarshotKit
import SwiftUI

/// A small panel at the top of the screen while Earshot hears a command,
/// works on it, or talks. It never takes focus and ignores clicks.
@MainActor final class OrbPanel {
    private let panel: NSPanel
    private let model: AppModel

    init(model: AppModel) {
        self.model = model
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 220, height: 44),
                        styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        panel.level = .statusBar
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
                self?.update()
                self?.observe()
            }
        }
        update()
    }

    private func update() {
        let show: Bool
        switch model.listenPhase {
        case .capturing, .transcribing: show = true
        default: show = model.speechState == .speaking
        }
        if show {
            guard let screen = NSScreen.main else { return }
            let f = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: f.midX - panel.frame.width / 2, y: f.maxY - panel.frame.height - 8))
            panel.orderFrontRegardless()
        } else {
            panel.orderOut(nil)
        }
    }
}

private struct OrbView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .symbolEffect(.pulse, isActive: !reduceMotion && isListening)
                .foregroundStyle(isListening ? Color.accentColor : .primary)
            Text(label).font(.callout.weight(.medium))
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
        .glassEffect(.regular, in: .capsule)
        .accessibilityElement(children: .combine)
    }

    private var isListening: Bool {
        if case .capturing = model.listenPhase { return true }
        return false
    }

    private var symbol: String {
        switch model.listenPhase {
        case .capturing: "mic.fill"
        case .transcribing: "ellipsis"
        default: "waveform"
        }
    }

    private var label: String {
        switch model.listenPhase {
        case .capturing: "Listening"
        case .transcribing: "Working on it"
        default: "Earshot"
        }
    }
}
