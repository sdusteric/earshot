import AppKit

/// Earshot lives in the menu bar, so it has no Dock icon and Command-Tab
/// skips it. While one of its own windows is open (Activity, Settings, the
/// welcome), it becomes a regular app so you can switch back to that window;
/// when the last one closes it leaves the Dock again. The orb and the menu
/// bar panel are panels and don't count.
@MainActor
final class DockPresence {
    private var observers: [NSObjectProtocol] = []

    func start() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification,
                     NSWindow.willCloseNotification, NSWindow.didMiniaturizeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let closing = name == NSWindow.willCloseNotification ? note.object as? NSWindow : nil
                MainActor.assumeIsolated { self?.update(closing: closing) }
            })
        }
    }

    private func update(closing: NSWindow?) {
        let open = NSApp.windows.contains { w in
            w !== closing && Self.counts(w) && (w.isVisible || w.isMiniaturized)
        }
        let want: NSApplication.ActivationPolicy = open ? .regular : .accessory
        guard NSApp.activationPolicy() != want else { return }
        NSApp.setActivationPolicy(want)
        // Turning regular can leave the app behind the window it just showed.
        if open { NSApp.activate() }
    }

    /// A titled window you work in, not the orb, the menu bar panel or a sheet.
    private static func counts(_ w: NSWindow) -> Bool {
        !(w is NSPanel) && w.styleMask.contains(.titled) && w.canBecomeMain && w.sheetParent == nil
    }
}
