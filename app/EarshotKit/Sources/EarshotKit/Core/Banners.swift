import Foundation

/// A notification for a session that needs you while Earshot can't say so.
public struct Banner: Sendable, Equatable {
    /// One banner per session: a newer one replaces it.
    public let session: String
    /// The session's name.
    public let title: String
    /// The line Earshot would have said.
    public let body: String
}

/// Which lines Earshot can't say become a banner: only a line that says a
/// session needs you, and only one per session until it goes back to work.
public struct BannerBook: Sendable {
    static let maxSeen = 500

    private var shown: Set<String> = []
    /// Lines that already made a banner or were turned down: a line held
    /// again after a call never makes a second one.
    private var seen: Set<UUID> = []

    public init() {}

    public mutating func banner(for line: SpokenLine, name: String?) -> Banner? {
        guard line.asksYou, !line.session.isEmpty else { return nil }
        if seen.count >= Self.maxSeen { seen.removeAll() }
        guard seen.insert(line.id).inserted, !shown.contains(line.session) else { return nil }
        shown.insert(line.session)
        let title = line.name ?? name ?? "A session"
        return Banner(session: line.session, title: title.prefix(1).uppercased() + title.dropFirst(), body: line.text)
    }

    /// The session went back to work or closed, so you answered it: its banner
    /// is stale, and the next time it needs you gets a new one. True when it had one.
    public mutating func clear(session: String) -> Bool { shown.remove(session) != nil }
}

/// Posts the banners. The app connects the poster; until then, and while the
/// setting is off, nothing is posted.
public actor Banners {
    public typealias Show = @Sendable (Banner) async -> Void
    public typealias Remove = @Sendable (String) async -> Void

    private var book = BannerBook()
    private let enabled: @Sendable () -> Bool
    private var show: Show?
    private var remove: Remove?

    public init(enabled: @escaping @Sendable () -> Bool = { true }) { self.enabled = enabled }

    public func connect(show: @escaping Show, remove: @escaping Remove) {
        self.show = show
        self.remove = remove
    }

    /// A line Earshot can't say now: muted, or held for a call or a full screen app.
    public func unspoken(_ line: SpokenLine, name: String?) async {
        guard enabled(), let show, let banner = book.banner(for: line, name: name) else { return }
        await show(banner)
    }

    /// A session's new state. Back at work or closed: its banner goes.
    public func sessionChanged(_ session: String, to state: SessionState) async {
        switch state {
        case .working, .open, .closed:
            if book.clear(session: session) { await remove?(session) }
        default:
            break
        }
    }
}
