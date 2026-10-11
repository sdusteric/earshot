import Foundation
import os

public protocol FollowUpListening: Sendable {
    func listenFollowUp(_ f: Listener.FollowUp, within: Duration?) async
    func setVocabulary(_ v: [String]) async
    /// What Earshot is saying now, nil when it stopped, so it never wakes itself.
    func setSpeaking(_ text: String?) async
}

extension Listener: FollowUpListening {}

/// The parts of SpeechOut the voice loop uses.
public protocol LineSpeaker: Sendable {
    func enqueue(_ line: SpokenLine) async
    func beginListening() async
    func endListening() async
    func lineEvents() async -> AsyncStream<SpeechOut.LineEvent>
    func holdAfter(_ id: UUID) async
    func releaseHold() async
}

extension SpeechOut: LineSpeaker {}

/// From what you said to what Earshot says back.
public actor VoiceLoop: ListenObserver {
    private let followUps: any FollowUpListening
    private let parser: CommandParser
    private let dispatcher: Dispatcher
    private let directory: SessionDirectory
    private let approvals: ApprovalBook
    private let speech: any LineSpeaker
    private let chimes: any Chimes
    private let events: EventLog
    private let signposter = OSSignposter(subsystem: "com.earshot.app", category: "command")
    private let latencyLog = Logger(subsystem: "com.earshot.app", category: "latency")

    /// A question Earshot asked ("Which one?"), waiting for its answer.
    private var pending: Dispatcher.Pending?
    /// Follow-up windows to open once a line has been said.
    private var afterLine: [UUID: Listener.FollowUp] = [:]
    /// The open prompt a need line was about when it began, for its window.
    private var needPrompt: [UUID: String] = [:]
    /// When the command that led to a line ended, for the latency log.
    private var commandEnded: [UUID: ContinuousClock.Instant] = [:]
    /// One per heard capture whose utterance has not arrived yet. Each is
    /// paid (one endListening) when its utterance is handled, or after
    /// `owedLimit` if no utterance comes.
    private var awaiting: [UUID] = []
    /// Heard captures whose utterance is being handled: one endListening each.
    private var endsOwed = 0
    private let owedLimit: Duration = .seconds(15)

    public init(followUps: any FollowUpListening, parser: CommandParser, dispatcher: Dispatcher, directory: SessionDirectory,
                approvals: ApprovalBook, speech: any LineSpeaker, chimes: any Chimes, events: EventLog) {
        self.followUps = followUps; self.parser = parser; self.dispatcher = dispatcher; self.directory = directory
        self.approvals = approvals; self.speech = speech; self.chimes = chimes; self.events = events
    }

    public func start(utterances: AsyncStream<Listener.Utterance>) async {
        let lines = await speech.lineEvents()
        Task { for await e in lines { await self.lineEvent(e) } }
        Task { for await u in utterances { await self.handle(u) } }
    }

    // MARK: - ListenObserver

    public func captureBegan(_ trigger: Listener.Trigger) async {
        signposter.emitEvent("wake")
        await speech.beginListening()
        switch trigger {
        case .wake, .hotkey: Task { await self.prepare() }
        case .followUp: break
        }
    }

    public func captureEnded(heard: Bool) async {
        guard heard else { await speech.endListening(); return }
        let id = UUID()
        awaiting.append(id)
        Task {
            try? await Task.sleep(for: self.owedLimit)
            await self.giveUp(id)
        }
    }

    /// No utterance came for a heard capture: end its listening now.
    private func giveUp(_ id: UUID) async {
        guard let i = awaiting.firstIndex(of: id) else { return }
        awaiting.remove(at: i)
        await speech.endListening()
    }

    /// While you talk: fresh sessions, their names boosted, the model warm.
    private func prepare() async {
        await directory.refresh()
        let names = await directory.vocabulary()
        await followUps.setVocabulary(names)
        await parser.prewarm(sessions: names)
    }

    // MARK: - Utterances

    private func handle(_ u: Listener.Utterance) async {
        signposter.emitEvent("transcript")
        if !awaiting.isEmpty { awaiting.removeFirst(); endsOwed += 1 }
        if u.tooLong { await tooLong(u) } else { await respond(to: u) }
        if endsOwed > 0 {
            endsOwed -= 1
            await speech.endListening()
        }
    }

    private func respond(to u: Listener.Utterance) async {
        switch u.trigger {
        case .followUp(.approval(let id)):
            // Only a clear yes or no. Anything else leaves the prompt as it is.
            if let allow = Grammar.approvalWord(u.text) {
                switch await approvals.answer(id, allow: allow) {
                case .written:
                    await chimes.play(.confirm)
                    await say(allow ? "Approved." : "Told it no.", after: u)
                case .closed: break   // answered on screen first: say nothing
                case .failed: await say("Couldn't answer it.", after: u)
                }
                await events.add("command answer")
            }
        case .followUp(.reply):
            if let p = pending {
                pending = nil
                await apply(await dispatcher.reply(u.text, to: p), after: u)
            }
        case .wake, .hotkey:
            pending = nil
            afterLine.removeAll()
            let c = await parser.parse(u.text, sessions: await directory.vocabulary())
            signposter.emitEvent("command")
            await events.add("command \(Self.kind(c))")
            if u.trigger == .wake, case .answer = c {
                // The wake word alone never answers a prompt; the hotkey and the approval window do.
                await say("Hold the hotkey to answer it.", after: u)
            } else {
                await apply(await dispatcher.run(c), after: u)
            }
        }
    }

    /// Cut off at the length cap, so nothing is sent. In an approval window anything
    /// but yes or no is ignored, so nothing is said there either.
    private func tooLong(_ u: Listener.Utterance) async {
        switch u.trigger {
        case .followUp(.approval): return
        case .followUp(.reply): pending = nil
        case .wake, .hotkey: pending = nil; afterLine.removeAll()
        }
        await events.add("command too long")
        await say("That was too long for me. Try a shorter command.", after: u)
    }

    private func apply(_ o: Dispatcher.Outcome, after u: Listener.Utterance) async {
        if o.sound { await chimes.play(.confirm) }
        if let s = o.spokeAbout { await directory.noteSpoke(about: s) }
        if let p = o.pending { pending = p }
        guard let text = o.line else { return }
        await say(text, after: u, then: o.pending == nil ? nil : .reply)
    }

    private func say(_ text: String, after u: Listener.Utterance, then followUp: Listener.FollowUp? = nil) async {
        let line = SpokenLine(text: text, kind: .confirm, session: "")
        commandEnded[line.id] = u.endedAt
        if let followUp { afterLine[line.id] = followUp }
        await speech.enqueue(line)
    }

    // MARK: - Lines

    private func lineEvent(_ e: SpeechOut.LineEvent) async {
        switch e {
        case .started(let line):
            await followUps.setSpeaking(line.text)
            // A window is due after this line: keep the queue from moving on until it is open.
            var due = afterLine[line.id] != nil
            if line.kind == .need, !line.session.isEmpty, let a = await approvals.latest(session: line.session) {
                needPrompt[line.id] = a.id
                due = true
            }
            if due { await speech.holdAfter(line.id) }
            if let ended = commandEnded.removeValue(forKey: line.id) {
                let d = ContinuousClock.now - ended
                let ms = Int(d.components.seconds * 1000 + d.components.attoseconds / 1_000_000_000_000_000)
                signposter.emitEvent("speech")
                latencyLog.notice("latency \(ms, privacy: .public) ms")
                await events.add("latency \(ms) ms")
            }
        case .finished(let line):
            if !line.session.isEmpty { await directory.noteSpoke(about: line.session) }
            // Windows open only now, after Earshot's own line, so it never hears itself.
            let prompt = needPrompt.removeValue(forKey: line.id)
            if let f = afterLine.removeValue(forKey: line.id) {
                await followUps.listenFollowUp(f, within: nil)
            } else if let id = prompt, await approvals.isOpen(id) {
                // Only the prompt the line was about, and only while it is still open.
                await followUps.listenFollowUp(.approval(id: id), within: nil)
            }
            await speech.releaseHold()
        case .ended:
            await followUps.setSpeaking(nil)
        }
    }

    static func kind(_ c: Command) -> String {
        switch c {
        case .send: "send"
        case .status: "status"
        case .stop: "stop"
        case .start: "start"
        case .answer: "answer"
        case .unknown: "unknown"
        }
    }
}
