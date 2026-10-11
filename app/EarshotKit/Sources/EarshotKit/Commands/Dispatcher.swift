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

    public static let didntGetIt = "Sorry, I didn't get that."
    public static let stopText = "Stop what you're doing and wait for the user."
    static let counts = ["no", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine"]

    private let directory: SessionDirectory
    private let store: SessionStore
    private let transport: any SessionTransport
    private let runner: any ClaudeRunner
    private let approvals: ApprovalBook
    private let say: @Sendable (String) async -> Void
    private let receiptTimeout: Duration
    private let defaults: UserDefaults
    private var misses = 0
    private let log = Logger(subsystem: "com.earshot.app", category: "dispatch")

    public init(directory: SessionDirectory, store: SessionStore, transport: any SessionTransport, runner: any ClaudeRunner,
                approvals: ApprovalBook, say: @escaping @Sendable (String) async -> Void,
                receiptTimeout: Duration = .seconds(5), defaultsSuite: String? = nil) {
        self.directory = directory; self.store = store; self.transport = transport; self.runner = runner
        self.approvals = approvals; self.say = say; self.receiptTimeout = receiptTimeout
        defaults = defaultsSuite.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }

    public func run(_ c: Command) async -> Outcome {
        switch c {
        case .unknown:
            return Outcome(line: Self.didntGetIt)
        case .status(nil):
            await directory.refresh(ifOlderThan: 2)
            return Outcome(line: RollCall.line(await directory.sessions, now: Date()))
        case .answer(let allow, let target):
            return await answer(allow: allow, target: target)
        case .start(let project, let prompt):
            return await start(project, prompt: prompt)
        case .send(let target, _), .stop(let target, _):
            return await targeted(c, target)
        case .status(let target?):
            return await targeted(c, target)
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
            let hits = open.filter { NameMatch.score(text, $0.name) >= SessionDirectory.threshold }
            guard hits.count == 1 else { return Outcome(line: "I didn't catch which one.") }
            return await write(hits[0], allow: allow)
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
        case .several(let list):
            return Outcome(line: whichOne(list), pending: .chooseSession(c, list.map(\.id)))
        case .none:
            return Outcome(line: "I don't know a session called \(target ?? "that"). Open ones are \(Self.listThree(sessions)).")
        case .noTarget:
            return Outcome(line: "Which session? Open ones are \(Self.listThree(sessions)).",
                           pending: .chooseSession(c, sessions.map(\.id)))
        }
    }

    private func act(_ c: Command, on s: LiveSession) async -> Outcome {
        switch c {
        case .send(_, let prompt): return await send(prompt, to: s)
        case .status: return Outcome(line: RollCall.sentence(s, now: Date()), spokeAbout: s.id)
        case .stop(_, let now): return await stop(s, now: now)
        default: return Outcome(line: Self.didntGetIt)
        }
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
        if s.waiting || s.state == .needs || s.state == .reply {
            return Outcome(line: "Queued. \(Self.upper(s.name)) is still waiting on your OK.", spokeAbout: s.id)
        }
        if s.busy || s.state == .working {
            return Outcome(line: "Queued, \(s.name) is busy.", spokeAbout: s.id)
        }
        let session = s
        Task { await self.watchReceipt(session, sentAt: sentAt) }
        return Outcome(line: "Sent to \(s.name).", spokeAbout: s.id)
    }

    /// `claude --resume <id> --bg "<prompt>"`, with no other flags, continues the same session.
    private func resume(_ s: LiveSession, _ prompt: String) async -> Outcome {
        let r = await runner.run(["--resume", s.id, "--bg", prompt], cwd: s.cwd.isEmpty ? nil : s.cwd, timeout: .seconds(15))
        return r.status == 0 ? Outcome(line: "Sent to \(s.name).", spokeAbout: s.id) : Outcome(line: "Couldn't reach \(s.name).")
    }

    /// An idle session that got the prompt starts working: the plugin's
    /// status says so, or Claude Code lists it as busy.
    private func watchReceipt(_ s: LiveSession, sentAt: Date) async {
        let deadline = ContinuousClock.now + receiptTimeout
        while ContinuousClock.now < deadline {
            if await received(s.id, after: sentAt) { misses = 0; return }
            try? await Task.sleep(for: .milliseconds(50))
        }
        await directory.refresh()
        let busyNow = await directory.session(s.id)?.busy == true
        let reported = await received(s.id, after: sentAt)
        if busyNow || reported { misses = 0; return }
        misses += 1
        log.info("no receipt from a session (\(self.misses, privacy: .public) in a row)")
        if misses >= 2 {
            if let key = await brokenKey() { defaults.set(true, forKey: key) }
            await say("Sending to sessions stopped working with this Claude Code version. Background sessions still work.")
        } else {
            await say("\(Self.upper(s.name)) didn't pick it up.")
        }
    }

    private func received(_ id: String, after: Date) async -> Bool {
        guard let info = await store.sessions.first(where: { $0.id == id }) else { return false }
        return info.updated >= after && info.state != .open && info.state != .done
    }

    private func brokenKey() async -> String? { await runner.version().map { "socketBroken-\($0)" } }

    private func sendingBroken() async -> Bool {
        guard let key = await brokenKey() else { return false }
        return defaults.bool(forKey: key)
    }

    private func stop(_ s: LiveSession, now: Bool) async -> Outcome {
        let name = Self.upper(s.name)
        if now, s.isBackground {
            let r = await runner.run(["stop", s.id], cwd: nil, timeout: .seconds(10))
            return Outcome(line: r.status == 0 ? "Stopped \(s.name)." : "Couldn't stop \(s.name).", spokeAbout: s.id)
        }
        let active = s.busy || s.waiting || [.working, .needs, .reply, .stuck].contains(s.state)
        guard active else { return Outcome(line: "\(name) isn't doing anything.", spokeAbout: s.id) }
        guard let pid = s.pid, !(await sendingBroken()) else {
            if s.isBackground { return await stop(s, now: true) }
            return Outcome(line: "I can't reach \(s.name).")
        }
        guard await transport.send(pid: pid, sessionID: s.id, text: Self.stopText, priority: .now) else {
            return Outcome(line: "\(name) has closed.")
        }
        return Outcome(line: "\(name) will stop after its current step.", spokeAbout: s.id)
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
