import AppKit
import CoreGraphics
import Foundation

/// Busy while the app in front fills a whole display: a full screen Space, a
/// game, a slideshow or a video player. Kobi keeps its own lines for later
/// then (see SpeechOut's `quiet`), unless `enabled` says otherwise.
public final class FullScreenWatch: MicSource, @unchecked Sendable {
    private let enabled: @Sendable () -> Bool
    private let lock = NSLock()
    private var conts: [UUID: AsyncStream<Bool>.Continuation] = [:]
    private var last = false
    private var observers: [NSObjectProtocol] = []
    private var poll: Task<Void, Never>?

    public init(enabled: @escaping @Sendable () -> Bool) {
        self.enabled = enabled
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in self?.check() })
        }
        // A window can fill the screen without a Space or app change (a game
        // switching mode, a player going full window), and the setting can change.
        poll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                self?.check()
            }
        }
        last = compute()
    }

    deinit {
        poll?.cancel()
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
    }

    public var isBusy: Bool { get async { compute() } }

    public func changes() -> AsyncStream<Bool> {
        let (stream, cont) = AsyncStream<Bool>.makeStream()
        let id = UUID()
        lock.withLock { conts[id] = cont }
        cont.onTermination = { [weak self] _ in _ = self?.lock.withLock { self?.conts.removeValue(forKey: id) } }
        return stream
    }

    private func check() {
        let now = compute()
        let targets: [AsyncStream<Bool>.Continuation] = lock.withLock {
            guard now != last else { return [] }
            last = now
            return Array(conts.values)
        }
        targets.forEach { $0.yield(now) }
    }

    private func compute() -> Bool {
        guard enabled(), let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != getpid() else { return false }
        return Self.fillsDisplay(pid: app.processIdentifier)
    }

    /// True when one of the app's normal windows is exactly the size of a display.
    /// A zoomed window stops at the menu bar and Dock, so it doesn't count.
    static func fillsDisplay(pid: pid_t) -> Bool {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                       kCGNullWindowID) as? [[String: Any]] else { return false }
        var count: UInt32 = 0
        _ = CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        _ = CGGetActiveDisplayList(count, &ids, &count)
        let displays = ids.map { CGDisplayBounds($0).size }
        for w in windows {
            guard (w[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  (w[kCGWindowLayer as String] as? Int) == 0,
                  let dict = w[kCGWindowBounds as String] as? NSDictionary,
                  let b = CGRect(dictionaryRepresentation: dict) else { continue }
            if displays.contains(where: { abs($0.width - b.width) < 1 && abs($0.height - b.height) < 1 }) { return true }
        }
        return false
    }
}
