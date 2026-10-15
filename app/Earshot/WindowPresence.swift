import AppKit
import EarshotKit
import SwiftUI

extension EnvironmentValues {
    /// Whether the window holding this view is on screen, and key. Views that
    /// animate or poll pause out of sight: SwiftUI keeps a timeline running in
    /// a window that is covered, minimized or ordered out.
    @Entry var windowPresence = Cadence.Window()
}

extension View {
    /// Tells the views inside where their window is (see `windowPresence`).
    func tracksWindowPresence() -> some View { modifier(WindowPresenceTracker()) }
}

private struct WindowPresenceTracker: ViewModifier {
    @State private var presence = Cadence.Window()

    func body(content: Content) -> some View {
        content
            .environment(\.windowPresence, presence)
            .background(WindowPresenceProbe { if $0 != presence { presence = $0 } })
    }
}

/// An empty view that follows its window's occlusion and key state. It stops
/// following when it leaves the window (viewDidMoveToWindow with no window).
private struct WindowPresenceProbe: NSViewRepresentable {
    let report: (Cadence.Window) -> Void

    func makeNSView(context: Context) -> ProbeView {
        let v = ProbeView()
        v.report = report
        return v
    }

    func updateNSView(_ v: ProbeView, context: Context) { v.report = report }

    final class ProbeView: NSView {
        var report: ((Cadence.Window) -> Void)?
        private var tokens: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            tokens.forEach { NotificationCenter.default.removeObserver($0) }
            tokens = []
            guard let window else { send(.init(visible: false, key: false)); return }
            for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didBecomeKeyNotification,
                         NSWindow.didResignKeyNotification] {
                tokens.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.sendCurrent() }
                })
            }
            sendCurrent()
        }

        private func sendCurrent() {
            guard let window else { return }
            send(.init(visible: window.occlusionState.contains(.visible), key: window.isKeyWindow))
        }

        /// After the current view update: state may not change during one.
        private func send(_ w: Cadence.Window) {
            DispatchQueue.main.async { [weak self] in self?.report?(w) }
        }
    }
}
