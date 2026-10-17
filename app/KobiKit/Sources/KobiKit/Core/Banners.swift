import Foundation

/// A notification for a session that needs you while Kobi can't say so.
public struct Banner: Sendable, Equatable {
    /// One banner per session: a newer one replaces it.
    public let session: String
    /// The session's name.
    public let title: String
    /// The line Kobi would have said.
    public let body: String
}

/// Which lines Kobi can't say become a banner: only a line that says a
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

/// Allow and Deny on a permission prompt's banner. A banner gets them only
/// when its session has exactly one open prompt, so each button answers one
/// prompt, never a guess between two. Nothing is ever allowed without a press.
public enum BannerApproval {
    /// The prompt a banner for this session would answer, or nil when the
    /// session has no open prompt or more than one.
    public static func match(session: String, open: [OpenApproval]) -> OpenApproval? {
        let these = open.filter { $0.session == session }
        return these.count == 1 ? these[0] : nil
    }

    /// The prompt a pressed button answers: the one with that id and session,
    /// while it is still open. Nil once it was answered, closed or its hook is gone.
    public static func target(id: String, session: String, open: [OpenApproval]) -> OpenApproval? {
        open.first { $0.id == id && $0.session == session }
    }

    /// The banner's text for a prompt: what it asks for ("Wants to run the migration.").
    public static func body(_ a: OpenApproval) -> String {
        a.what.isEmpty ? "Wants your OK." : "Wants \(a.what)."
    }

    /// A banner still in Notification Center: its session, and the prompt its
    /// buttons answer (nil: it has none).
    public struct Shown: Sendable, Equatable {
        public let session: String
        public let approval: String?

        public init(session: String, approval: String?) {
            self.session = session; self.approval = approval
        }
    }

    /// The banners to post again, with buttons, now that the prompts are
    /// `open`: a banner posted before its session's prompt reached Kobi has
    /// none, and one whose prompt closed answers nothing. Each gets the
    /// session's one open prompt, by the same rule as `match`. A banner whose
    /// buttons answer a prompt that is still open is left alone.
    public static func repost(shown: [Shown], open: [OpenApproval]) -> [(session: String, approval: OpenApproval)] {
        var out: [(session: String, approval: OpenApproval)] = []
        for b in shown where !out.contains(where: { $0.session == b.session }) {
            if let id = b.approval, open.contains(where: { $0.id == id && $0.session == b.session }) { continue }
            guard let a = match(session: b.session, open: open) else { continue }
            out.append((b.session, a))
        }
        return out
    }
}

/// Posts the banners. The app connects the poster; until then, and while the
/// setting is off, nothing is posted. A banner waits a few seconds first, and
/// is dropped when the line got said meanwhile (a short dictation held it) or
/// the session went back to work.
public actor Banners {
    public typealias Show = @Sendable (Banner) async -> Void
    public typealias Remove = @Sendable (String) async -> Void

    private var book = BannerBook()
    private let enabled: @Sendable () -> Bool
    private let delay: Duration
    private var show: Show?
    private var remove: Remove?
    /// Lines that were said, so a waiting banner for one of them is dropped.
    private var said: Set<UUID> = []
    /// When each session last went back to work or closed.
    private var answeredAt: [String: ContinuousClock.Instant] = [:]

    public init(enabled: @escaping @Sendable () -> Bool = { true }, delay: Duration = .seconds(4)) {
        self.enabled = enabled
        self.delay = delay
    }

    /// Kobi started saying this line.
    public func lineSaid(_ id: UUID) {
        if said.count >= BannerBook.maxSeen { said.removeAll() }
        said.insert(id)
    }

    public func connect(show: @escaping Show, remove: @escaping Remove) {
        self.show = show
        self.remove = remove
    }

    /// A line Kobi can't say now: muted, or held for a call or a full screen app.
    public func unspoken(_ line: SpokenLine, name: String?) async {
        guard enabled(), show != nil, line.asksYou else { return }
        let arrived = ContinuousClock.now
        if delay == .zero {
            await post(line, name: name, arrived: arrived)
        } else {
            // In a task of its own, so the lines behind this one don't wait.
            Task { [delay] in
                try? await Task.sleep(for: delay)
                await self.post(line, name: name, arrived: arrived)
            }
        }
    }

    private func post(_ line: SpokenLine, name: String?, arrived: ContinuousClock.Instant) async {
        guard enabled(), let show, !said.contains(line.id) else { return }
        if let back = answeredAt[line.session], back >= arrived { return }
        guard let banner = book.banner(for: line, name: name) else { return }
        await show(banner)
    }

    /// A session's new state. Back at work or closed: its banner goes.
    public func sessionChanged(_ session: String, to state: SessionState) async {
        switch state {
        case .working, .open, .closed:
            answeredAt[session] = ContinuousClock.now
            if book.clear(session: session) { await remove?(session) }
        default:
            break
        }
    }
}
