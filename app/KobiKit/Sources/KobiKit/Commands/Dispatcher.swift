import Foundation
import os

/// Carries out one command and returns what to say.
public actor Dispatcher {
    public enum Pending: Sendable, Equatable {
        /// "Which one?": the command waits for a session name.
        case chooseSession(Command, [String])
        /// "What should it do?"
        case startPrompt(KnownProject)
        /// "Which one, billing or docs?"
        case chooseApproval(allow: Bool, [String])
        /// "Stop billing and blog?": these sessions stop on a clear yes.
        case confirmStop([String])
        /// "Send to kobi: run the tests?": a send heard unclearly goes on a clear yes.
        case confirmSend(session: String, prompt: String)
    }

    public struct Outcome: Sendable, Equatable {
        public var line: String?
        public var pending: Pending?
        /// The session this was about, for "last spoke about".
        public var spokeAbout: String?
        /// A voice answer was written: the confirm sound plays first.
        public var sound: Bool

        public init(line: String? = nil, pending: Pending? = nil, spokeAbout: String? = nil, sound: Bool = false) {
            self.line = line; self.pending = pending; self.spokeAbout = spokeAbout; self.sound = sound
        }
    }

    /// What became of a prompt, once Kobi knows: sent to an idle session
    /// (watchReceipt), queued behind a busy one (watchQueued), or a background
    /// session resumed with it (watchResume).
    public struct Receipt: Sendable, Equatable {
        public enum Result: Sendable, Equatable {
            /// It started working on the prompt (or stopped on a prompt of its own).
            case started
            /// Claude Code answered and the session stayed idle: it didn't pick it up.
            /// A queued prompt: its session's turn ended and no new one began.
            case missed
            /// The session closed after the send.
            case closed
            /// Claude Code never answered: no evidence either way.
            case unknown
        }
        public let session: String
        public let name: String
        /// When the prompt was sent.
        public let sent: Date
        public let result: Result

        public init(session: String, name: String, sent: Date, result: Result) {
            self.session = session; self.name = name; self.sent = sent; self.result = result
        }

        /// The line under the reply field, or nil when there is nothing to add.
        public var line: String? {
            switch result {
            case .started: "\(Dispatcher.upper(name)) started working."
            case .missed: "\(Dispatcher.upper(name)) didn't pick it up."
            case .closed: "\(Dispatcher.upper(name)) has closed."
            case .unknown: nil
            }
        }
    }

    public static let didntGetIt = "Sorry, I didn't get that."

    /// What Kobi says when it heard words but no command in them: the words,
    /// so you know whether the mic or the wording was the trouble. At most 12
    /// words are read back. Spoken only; never logged.
    public static func didntGet(_ heard: String) -> String {
        let words = heard.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return didntGetIt }
        let said = words.prefix(12).joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: ".,!?;: "))
        guard !said.isEmpty else { return didntGetIt }
        return "Sorry, I heard: \(said)" + (words.count > 12 ? "..." : ".")
    }

    public static let stopText = "Stop what you're doing and wait for the user."
    static let counts = ["no", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine"]

    private let directory: SessionDirectory
    private let store: SessionStore
    private let transport: any SessionTransport
    private let runner: any ClaudeRunner
    private let approvals: ApprovalBook
    private let say: @Sendable (String) async -> Void
    private let receiptTimeout: Duration
    private let pollInterval: Duration
    /// How long a reply queued behind a busy session is watched for its start.
    private let queuedTimeout: Duration
    /// Waits you dismissed in Activity: what Kobi says reads them as open.
    private let dismissals: @Sendable () -> Dismissals
    /// The one watch per session on a queued reply; a newer queued reply takes it over.
    private var queuedWatches: [String: UUID] = [:]
    private var misses = 0
    /// Claude Code versions whose sockets did not work, for this run only.
    private var brokenVersions: Set<String> = []
    private var loggedNoVersion = false
    /// The greeting's last opener, so two in a row don't start the same way.
    private var lastOpener = -1
    private let log = Logger(subsystem: "com.kobi.app", category: "dispatch")
    private var receiptConts: [UUID: AsyncStream<Receipt>.Continuation] = [:]

    public init(directory: SessionDirectory, store: SessionStore, transport: any SessionTransport, runner: any ClaudeRunner,
                approvals: ApprovalBook, say: @escaping @Sendable (String) async -> Void,
                dismissals: @escaping @Sendable () -> Dismissals = { Dismissals() },
                receiptTimeout: Duration = .seconds(5), pollInterval: Duration = .seconds(1),
                queuedTimeout: Duration = .seconds(600)) {
        self.directory = directory; self.store = store; self.transport = transport; self.runner = runner
        self.approvals = approvals; self.say = say; self.dismissals = dismissals; self.receiptTimeout = receiptTimeout
        self.pollInterval = pollInterval; self.queuedTimeout = queuedTimeout
    }

    private func freshOpener(_ n: Int) -> Int {
        var i = Int.random(in: 0..<n)
        if n > 1, i == lastOpener { i = (i + 1) % n }
        lastOpener = i
        return i
    }

    public func run(_ c: Command) async -> Outcome {
        switch c {
        case .unknown:
            return Outcome(line: Self.didntGetIt)
        case .quiet, .repeatLast:   // VoiceLoop says the last line again
            return Outcome()
        case .stopAll:
            return await askStopAll()
        case .status(nil):
            await directory.refresh(ifOlderThan: 2)
            return Outcome(line: RollCall.line(await directory.sessions, now: Date(), dismissals: dismissals()))
        case .greet:
            await directory.refresh(ifOlderThan: 2)
            return Outcome(line: RollCall.greeting(await directory.sessions, now: Date(), dismissals: dismissals(),
                                                   pick: freshOpener))
        case .answer(let allow, let target):
            return await answer(allow: allow, target: target)
        case .start(let project, let prompt):
            return await start(project, prompt: prompt)
        case .send(let target, _), .stop(let target, _):
            return await targeted(c, target)
        case .status(let target?):
            return await targeted(c, target)
        case .confirmSend(let target, let prompt):
            return await askToSend(target, prompt)
        }
    }

    public func reply(_ text: String, to pending: Pending) async -> Outcome {
        if ["never mind", "nevermind", "cancel", "forget it", "nothing", "none"].contains(NameMatch.normalize(text)) {
            return Outcome()
        }
        switch pending {
        case .chooseSession(let c, let ids):
            switch await directory.resolve(text, among: ids) {
            case .one(let s): return await act(c, on: s)
            case .several: return Outcome(line: "I still can't tell which one.")
            default: return Outcome(line: "I didn't catch which one.")
            }
        case .startPrompt(let p):
            let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return prompt.isEmpty ? Outcome(line: Self.didntGetIt) : await launch(p, prompt)
        case .chooseApproval(let allow, let ids):
            let open = await approvals.current.filter { ids.contains($0.id) }
            if open.isEmpty { return Outcome() }
            let hits = open.filter { NameMatch.score(text, $0.name) >= SessionDirectory.threshold }
            // The named prompt closed since the question (answered on screen): a late answer says nothing.
            if hits.isEmpty, open.count < ids.count { return Outcome() }
            guard hits.count == 1 else { return Outcome(line: "I didn't catch which one.") }
            return await write(hits[0], allow: allow)
        case .confirmStop(let ids):
            guard Grammar.windowAnswer(text) == true else { return Outcome(line: "Okay, I didn't stop anything.") }
            return await stopAll(ids)
        case .confirmSend(let id, let prompt):
            guard Grammar.windowAnswer(text) == true else { return Outcome(line: "Okay, I didn't send it.") }
            await directory.refresh(ifOlderThan: 2)
            guard let s = await directory.session(id) else { return Outcome(line: "That session has closed.") }
            return await send(prompt, to: s)
        }
    }

    // MARK: - Sessions

    private func targeted(_ c: Command, _ target: String?) async -> Outcome {
        await directory.refresh(ifOlderThan: 2)
        let sessions = await directory.sessions
        guard !sessions.isEmpty else { return Outcome(line: "No Claude sessions are open.") }
        switch await directory.resolve(target) {
        case .one(let s):
            return await act(c, on: s)
        case .several(let found):
            // Oldest first, so "the first one" and "the older one" agree.
            let list = SessionDirectory.oldestFirst(found)
            return Outcome(line: whichOne(list), pending: .chooseSession(c, list.map(\.id)))
        case .none:
            return Outcome(line: "I don't know a session called \(target ?? "that"). Open ones are \(Self.listThree(sessions)).")
        case .noTarget:
            return Outcome(line: "Which session? Open ones are \(Self.listThree(sessions)).",
                           pending: .chooseSession(c, sessions.map(\.id)))
        }
    }

    /// A send heard unclearly: read back first. When the name could be several
    /// sessions, "Which one?" is the check: naming one is a clear choice.
    private func askToSend(_ target: String, _ prompt: String) async -> Outcome {
        await directory.refresh(ifOlderThan: 2)
        guard !(await directory.sessions).isEmpty else { return Outcome(line: "No Claude sessions are open.") }
        switch await directory.resolve(target) {
        case .one(let s):
            return Outcome(line: "Send to \(s.name): \(prompt)?", pending: .confirmSend(session: s.id, prompt: prompt),
                           spokeAbout: s.id)
        case .several:
            return await targeted(.send(target: target, prompt: prompt), target)
        case .none, .noTarget:
            return Outcome(line: Self.didntGetIt)
        }
    }

    private func act(_ c: Command, on s: LiveSession) async -> Outcome {
        switch c {
        case .send(_, let prompt): return await send(prompt, to: s)
        case .status: return Outcome(line: RollCall.sentence(s, now: Date(), dismissals: dismissals()), spokeAbout: s.id)
        case .stop(_, let now): return await stop(s, now: now)
        default: return Outcome(line: Self.didntGetIt)
        }
    }

    /// A reply typed in the session view, to that session by its ID. The same
    /// path as a spoken send: busy or waiting sessions queue it.
    public func send(typed prompt: String, toSession id: String) async -> Outcome {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return Outcome(line: "") }
        await directory.refresh(ifOlderThan: 2)
        guard let s = await directory.session(id) else { return Outcome(line: "That session has closed.") }
        return await send(text, to: s)
    }

    private func send(_ prompt: String, to s: LiveSession) async -> Outcome {
        let broken = await sendingBroken()
        guard let pid = s.pid, !broken else {
            if s.isBackground { return await resume(s, prompt) }
            if broken { return Outcome(line: "Sending to \(s.name) doesn't work with this Claude Code version yet.") }
            return Outcome(line: "I can't reach \(s.name).")
        }
        let sentAt = Date()
        guard await transport.send(pid: pid, sessionID: s.id, text: prompt, priority: .next) else {
            return Outcome(line: "\(Self.upper(s.name)) has closed.")
        }
        if s.waiting || s.state == .needs {
            return Outcome(line: "Queued. \(Self.upper(s.name)) is still waiting on your OK.", spokeAbout: s.id)
        }
        let session = s
        // The list can be 2 s old. The plugin's status, when it came after the
        // list and says the turn ended, is the newer word: the reply runs now.
        let live = await store.sessions.first { $0.id == s.id }
        let listedAt = await directory.listedAt
        let endedSinceListed = live.map { info in
            Self.turnEnded(info.state) && listedAt.map { info.updated >= $0 } ?? true
        } ?? false
        if s.busy || s.state == .working, !endedSinceListed {
            // Claude Code takes it up when the current turn ends; the receipt says when.
            let token = UUID()
            queuedWatches[s.id] = token
            // Working at the send, by the plugin's word, else by Claude Code's list.
            let wasWorking = live.map { Self.turnBegan($0.state) } ?? true
            // Subscribed before the reply returns, so no status after the send is missed.
            let changes = await store.changes()
            Task {
                await self.watchQueued(session, sentAt: sentAt, wasWorking: wasWorking, token: token, changes: changes)
            }
            return Outcome(line: Self.queuedLine(s.name), spokeAbout: s.id)
        }
        // This receipt is the newer word: a queued watch from before says nothing.
        queuedWatches[s.id] = nil
        Task { await self.watchReceipt(session, sentAt: sentAt) }
        return Outcome(line: "Sent to \(s.name).", spokeAbout: s.id)
    }

    static func queuedLine(_ name: String) -> String { "Queued. \(upper(name)) will see it when it finishes." }

    /// `claude --resume <id> --bg "<prompt>"`, with no other flags, continues the same session.
    private func resume(_ s: LiveSession, _ prompt: String) async -> Outcome {
        let sentAt = Date()
        let r = await runner.run(["--resume", s.id, "--bg", prompt], cwd: s.cwd.isEmpty ? nil : s.cwd, timeout: .seconds(15))
        guard r.status == 0 else { return Outcome(line: "Couldn't reach \(s.name).") }
        queuedWatches[s.id] = nil
        let session = s
        Task { await self.watchResume(session, sentAt: sentAt) }
        return Outcome(line: "Sent to \(s.name).", spokeAbout: s.id)
    }

    /// Every receipt watchReceipt settles, for the line under a reply field.
    /// Carries the session and its name, never the prompt.
    public func receipts() -> AsyncStream<Receipt> {
        let (stream, cont) = AsyncStream<Receipt>.makeStream()
        let id = UUID()
        receiptConts[id] = cont
        cont.onTermination = { [weak self] _ in Task { await self?.dropReceipts(id) } }
        return stream
    }

    private func dropReceipts(_ id: UUID) { receiptConts[id] = nil }

    private func watchReceipt(_ s: LiveSession, sentAt: Date) async {
        publish(Receipt(session: s.id, name: s.name, sent: sentAt, result: await checkReceipt(s, sentAt: sentAt)))
    }

    private func publish(_ r: Receipt) { receiptConts.values.forEach { $0.yield(r) } }

    /// A background session resumed with the prompt: started once Claude Code
    /// lists it working or waiting, or the plugin says it works. A resumed
    /// session may not be listed at once, so missing from the list is not
    /// closed here. Watched three receipt timeouts at most, then unknown. Never
    /// said, and never counted as a miss: resuming doesn't use the socket.
    private func watchResume(_ s: LiveSession, sentAt: Date) async {
        let clock = ContinuousClock()
        let deadline = clock.now + receiptTimeout * 3
        var result = Receipt.Result.unknown
        while clock.now < deadline {
            if await received(s.id, after: sentAt) { result = .started; break }
            await directory.refresh()
            if await directory.lastRefreshSucceeded, let now = await directory.session(s.id), now.busy || now.waiting {
                result = .started
                break
            }
            try? await Task.sleep(for: pollInterval)
        }
        publish(Receipt(session: s.id, name: s.name, sent: sentAt, result: result))
    }

    private enum QueuedEvent: Sendable { case store([SessionInfo]), tick }

    /// A reply queued behind a busy session: Claude Code takes it up when the
    /// turn ends. The plugin's statuses show that turn end (done, idle or
    /// failed) and the next one begin: started. Claude Code's list, read at most
    /// every ten polls (and shared with other refreshes), shows a session that
    /// closed. A turn that ended with nothing begun a receipt timeout later,
    /// with Claude Code listing the session idle, is a miss. When the plugin's
    /// last word at the send was a turn end (`wasWorking` false: Claude Code's
    /// list had not caught up), the turn it was queued behind had ended
    /// already, so a turn that begins after the send is the reply's: started.
    /// One watch per session, with one poll, for queuedTimeout at most; then
    /// unknown. A later send to the session ends it without a receipt. Never
    /// said aloud and never counted toward the broken mark, which is about idle sends.
    private func watchQueued(_ s: LiveSession, sentAt: Date, wasWorking: Bool, token: UUID,
                             changes: AsyncStream<[SessionInfo]>) async {
        let result = await checkQueued(s, sentAt: sentAt, wasWorking: wasWorking, token: token, changes: changes)
        guard queuedWatches[s.id] == token else { return }   // a newer queued reply took over
        queuedWatches[s.id] = nil
        publish(Receipt(session: s.id, name: s.name, sent: sentAt, result: result))
    }

    private func checkQueued(_ s: LiveSession, sentAt: Date, wasWorking: Bool, token: UUID,
                             changes: AsyncStream<[SessionInfo]>) async -> Receipt.Result {
        let clock = ContinuousClock()
        let deadline = clock.now + queuedTimeout
        let (events, cont) = AsyncStream<QueuedEvent>.makeStream()
        let feed = Task { for await list in changes { cont.yield(.store(list)) } }
        let ticker = Task { [pollInterval] in
            while !Task.isCancelled {
                try? await Task.sleep(for: pollInterval)
                cont.yield(.tick)
            }
        }
        defer { feed.cancel(); ticker.cancel(); cont.finish() }
        let listEvery = Self.seconds(pollInterval * 10)
        var ticks = 0
        // When the plugin said the turn ended, and when Claude Code was last asked about it (or the end).
        var ended: (at: Date, by: ContinuousClock.Instant)?
        for await e in events {
            guard queuedWatches[s.id] == token else { return .unknown }
            if clock.now >= deadline { return .unknown }
            switch e {
            case .store(let list):
                guard let info = list.first(where: { $0.id == s.id }), info.updated >= sentAt else { continue }
                if let end = ended {
                    if Self.turnBegan(info.state), info.updated >= end.at { return .started }
                } else if Self.turnEnded(info.state) {
                    ended = (info.updated, clock.now)
                } else if !wasWorking, Self.turnBegan(info.state) {
                    return .started
                }
            case .tick:
                ticks += 1
                if let end = ended, clock.now >= end.by + receiptTimeout {
                    // The turn ended a while ago with nothing begun: ask Claude Code now.
                    await directory.refresh()
                    guard await directory.lastRefreshSucceeded else { ended = (end.at, clock.now); continue }
                    guard let now = await directory.session(s.id) else { return .closed }
                    return now.busy || now.waiting ? .started : .missed
                }
                guard ticks % 10 == 0 else { continue }
                await directory.refresh(ifOlderThan: listEvery)
                if await directory.lastRefreshSucceeded, await directory.session(s.id) == nil { return .closed }
            }
        }
        return .unknown
    }

    /// The plugin's states that end a turn, and the ones that show a new one began.
    static func turnEnded(_ s: SessionState) -> Bool { [.done, .open, .failed].contains(s) }
    static func turnBegan(_ s: SessionState) -> Bool { [.working, .needs, .reply].contains(s) }

    static func seconds(_ d: Duration) -> TimeInterval {
        Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }

    /// An idle session that got the prompt starts working: the plugin's
    /// status says so, or Claude Code lists it as busy or waiting at a poll.
    /// The plugin is silent while Kobi is muted, so Claude Code is asked too.
    /// A miss is said here; the result goes to receipts().
    private func checkReceipt(_ s: LiveSession, sentAt: Date) async -> Receipt.Result {
        let clock = ContinuousClock()
        let deadline = clock.now + receiptTimeout
        var nextPoll = clock.now + pollInterval
        var answered = false
        while clock.now < deadline {
            if await received(s.id, after: sentAt) { misses = 0; return .started }
            if clock.now >= nextPoll {
                nextPoll = clock.now + pollInterval
                await directory.refresh()
                if await directory.lastRefreshSucceeded {
                    answered = true
                    // Gone from the list: the session closed. Not a miss, and nothing to say.
                    guard let now = await directory.session(s.id) else { return .closed }
                    if now.busy || now.waiting { misses = 0; return .started }
                }
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        await directory.refresh()
        if await directory.lastRefreshSucceeded {
            answered = true
            guard let now = await directory.session(s.id) else { return .closed }
            if now.busy || now.waiting { misses = 0; return .started }
        }
        if await received(s.id, after: sentAt) { misses = 0; return .started }
        // Claude Code never answered: no evidence either way.
        guard answered else { return .unknown }
        misses += 1
        log.info("no receipt from a session (\(self.misses, privacy: .public) in a row)")
        if misses >= 2 {
            if let version = await runner.version() {
                if brokenVersions.insert(version).inserted {
                    await say("Sending to sessions stopped working with this Claude Code version. Background sessions still work.")
                }
                return .missed
            }
            if !loggedNoVersion { loggedNoVersion = true; log.info("no Claude Code version, so sending is never marked broken") }
        }
        await say("\(Self.upper(s.name)) didn't pick it up.")
        return .missed
    }

    private func received(_ id: String, after: Date) async -> Bool {
        guard let info = await store.sessions.first(where: { $0.id == id }) else { return false }
        return info.updated >= after && info.state != .open && info.state != .done
    }

    private func sendingBroken() async -> Bool {
        guard let v = await runner.version() else { return false }
        return brokenVersions.contains(v)
    }

    static func isActive(_ s: LiveSession) -> Bool { s.busy || s.waiting || [.working, .needs, .stuck].contains(s.state) }

    private func stop(_ s: LiveSession, now: Bool) async -> Outcome {
        let name = Self.upper(s.name)
        if now, s.isBackground {
            let r = await runner.run(["stop", s.id], cwd: nil, timeout: .seconds(10))
            return Outcome(line: r.status == 0 ? "Stopped \(s.name)." : "Couldn't stop \(s.name).", spokeAbout: s.id)
        }
        guard Self.isActive(s) else { return Outcome(line: "\(name) isn't doing anything.", spokeAbout: s.id) }
        guard let pid = s.pid, !(await sendingBroken()) else {
            if s.isBackground { return await stop(s, now: true) }
            if await sendingBroken() { return Outcome(line: "Sending to \(s.name) doesn't work with this Claude Code version yet.") }
            return Outcome(line: "I can't reach \(s.name).")
        }
        guard await transport.send(pid: pid, sessionID: s.id, text: Self.stopText, priority: .now) else {
            return Outcome(line: "\(name) has closed.")
        }
        return Outcome(line: Self.willStop(s.name), spokeAbout: s.id)
    }

    static func willStop(_ name: String) -> String { "\(upper(name)) will stop after its current step." }

    /// One word can stop many sessions, so Kobi names them and asks first.
    private func askStopAll() async -> Outcome {
        await directory.refresh(ifOlderThan: 2)
        let sessions = await directory.sessions
        guard !sessions.isEmpty else { return Outcome(line: "No Claude sessions are open.") }
        let active = sessions.filter(Self.isActive)
        guard !active.isEmpty else { return Outcome(line: "Nothing is running.") }
        let line = active.count <= 3 ? "Stop \(Self.join(active.map(\.name)))?" : "Stop all \(active.count) sessions that are running?"
        return Outcome(line: line, pending: .confirmStop(active.map(\.id)))
    }

    private func stopAll(_ ids: [String]) async -> Outcome {
        await directory.refresh(ifOlderThan: 2)
        var stopping: [String] = [], other: [String] = []
        for id in ids {
            guard let s = await directory.session(id), Self.isActive(s) else { continue }
            let o = await stop(s, now: false)
            if o.line == Self.willStop(s.name) { stopping.append(s.name) }
            else if let line = o.line { other.append(line) }
        }
        var parts: [String] = []
        if !stopping.isEmpty {
            parts.append("\(Self.upper(Self.join(stopping))) will stop after \(stopping.count == 1 ? "its" : "their") current step.")
        }
        parts += other
        return Outcome(line: parts.isEmpty ? "Nothing is running now." : parts.joined(separator: " "))
    }

    // MARK: - Start

    private func start(_ project: String, prompt: String?) async -> Outcome {
        guard let p = await directory.matchProject(project) else {
            return Outcome(line: "I don't know a folder called \(project).")
        }
        guard p.trusted else { return Outcome(line: "\(Self.upper(p.name)) isn't trusted yet. Open it in Claude once first.") }
        guard let prompt, !prompt.isEmpty else {
            return Outcome(line: "What should the new session in \(p.name) do?", pending: .startPrompt(p))
        }
        return await launch(p, prompt)
    }

    private func launch(_ p: KnownProject, _ prompt: String) async -> Outcome {
        let r = await runner.run(["--bg", prompt], cwd: p.path, timeout: .seconds(20))
        if r.status == 0 { return Outcome(line: "Started a session in \(p.name).") }
        if r.stderr.lowercased().contains("trust") {
            return Outcome(line: "\(Self.upper(p.name)) isn't trusted yet. Open it in Claude once first.")
        }
        return Outcome(line: "Couldn't start a session in \(p.name).")
    }

    // MARK: - Answers

    private func answer(allow: Bool, target: String?) async -> Outcome {
        var open = await approvals.current
        guard !open.isEmpty else { return Outcome(line: "Nothing is waiting on your OK.") }
        if let target {
            open = open.filter { NameMatch.score(target, $0.name) >= SessionDirectory.threshold }
            guard !open.isEmpty else { return Outcome(line: "Nothing in \(target) is waiting on your OK.") }
        }
        // The newest prompt of each session.
        var latest: [String: OpenApproval] = [:]
        for a in open { latest[a.session] = a }
        let pick = latest.values.sorted { $0.opened < $1.opened }
        if pick.count == 1 { return await write(pick[0], allow: allow) }
        let names = pick.map(\.name)
        let list = names.dropLast().joined(separator: ", ") + " or " + (names.last ?? "")
        return Outcome(line: "Which one, \(list)?", pending: .chooseApproval(allow: allow, pick.map(\.id)))
    }

    private func write(_ a: OpenApproval, allow: Bool) async -> Outcome {
        switch await approvals.answer(a.id, allow: allow) {
        case .written: return Outcome(line: allow ? "Approved." : "Told it no.", spokeAbout: a.session, sound: true)
        case .closed: return Outcome()
        case .failed: return Outcome(line: "Couldn't answer it.")
        }
    }

    // MARK: - Words

    private func whichOne(_ list: [LiveSession]) -> String {
        let count = list.count < Self.counts.count ? Self.counts[list.count] : String(list.count)
        let projects = Set(list.map(\.project))
        if projects.count == 1, let p = projects.first {
            let labels = list.map { $0.label.isEmpty ? $0.name : $0.label }
            return "\(Self.upper(p)) has \(count): \(Self.join(labels)). Which one?"
        }
        return "\(Self.upper(count)) match: \(Self.join(list.map(\.name))). Which one?"
    }

    static func listThree(_ sessions: [LiveSession]) -> String { join(Array(sessions.prefix(3).map(\.name))) }

    static func join(_ items: [String]) -> String {
        guard items.count > 1 else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + " and " + items.last!
    }

    static func upper(_ s: String) -> String { s.prefix(1).uppercased() + s.dropFirst() }
}
