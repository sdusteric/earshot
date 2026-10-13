import Foundation

/// Wires the plugin socket to the speaker and the session list. Messages are
/// handled one at a time, in the order they arrive.
public final class EarshotCore: Sendable {
    public static var socketPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/Earshot/earshot.sock").path
    }

    /// Lines older than this when read are refused; the plugin waits 200 ms.
    static let lateAfterMs: Double = 150

    public let speech: SpeechOut
    public let sessions: SessionStore
    public let events: EventLog
    public let approvals: ApprovalBook
    public let availability: ListenAvailability
    /// Notifications for a session that needs you while Earshot can't speak.
    public let banners: Banners
    private let away = AwayBook()
    private let server: LineServer
    private let inbox: AsyncStream<AppMessage>.Continuation
    private let stream: AsyncStream<AppMessage>

    public init(socketPath: String = EarshotCore.socketPath, speech: SpeechOut, sessions: SessionStore, events: EventLog,
                approvals: ApprovalBook = ApprovalBook(), availability: ListenAvailability = ListenAvailability(),
                banners: Banners = Banners()) {
        self.speech = speech
        self.sessions = sessions
        self.events = events
        self.approvals = approvals
        self.availability = availability
        self.banners = banners
        let (stream, inbox) = AsyncStream<AppMessage>.makeStream()
        self.stream = stream
        self.inbox = inbox
        server = LineServer(path: socketPath) { (line: Data) -> LineServer.Answer in
            let message: AppMessage
            do {
                message = try AppMessage.decode(line)
            } catch AppMessage.DecodeError.version {
                return LineServer.Answer(reply: AppReply(ok: false, reason: "version").encoded)
            } catch {
                return LineServer.Answer(reply: AppReply(ok: false, reason: "unreadable").encoded)
            }
            let late: (Double?) -> Bool = { sent in
                guard let sent else { return false }
                return Date().timeIntervalSince1970 * 1000 - sent > EarshotCore.lateAfterMs
            }
            switch message {
            case .say(let s):
                // The plugin waits 0.2 s, then says the line itself. A line read
                // later than this was (or is about to be) said already.
                if late(s.sent) { return LineServer.Answer(reply: AppReply(ok: false, reason: "late").encoded) }
            case .approval(let a) where !a.isClosed:
                // The hook stops waiting after 0.2 s; it then sends closed.
                if late(a.sent) { return LineServer.Answer(reply: AppReply(ok: false, reason: "late").encoded) }
                if !availability.canListen {
                    return LineServer.Answer(reply: AppReply(ok: false, reason: "not listening").encoded)
                }
            default:
                break   // status, and closed approvals, however late
            }
            // Kept only once the plugin has the answer: if it stopped waiting,
            // it says the line itself.
            return LineServer.Answer(reply: AppReply(ok: true).encoded) { inbox.yield(message) }
        }
    }

    /// Starts the speaker, then opens the socket.
    public func start() async throws {
        await speech.start()
        let (stream, speech, sessions, events, approvals) = (self.stream, self.speech, self.sessions, self.events, self.approvals)
        let (banners, away) = (self.banners, self.away)
        // A line held for a call or a full screen app can become a banner.
        let held = await speech.heldLines()
        Task {
            for await line in held { await banners.unspoken(line, name: await sessions.name(of: line.session)) }
        }
        Task {
            for await message in stream {
                switch message {
                case .say(let s):
                    let line = SpokenLine(text: s.text, kind: s.kind, session: s.session, transcript: s.transcript, name: s.name)
                    await away.note(line)
                    if s.muted == true {
                        // The plugin is muted: nothing is said, but a session that needs you gets a banner.
                        await events.add("line \(s.kind.rawValue), muted")
                        await banners.unspoken(line, name: await sessions.name(of: s.session))
                    } else {
                        await events.add("line \(s.kind.rawValue)")
                        await speech.enqueue(line)
                    }
                case .status(let s):
                    let before = await sessions.apply(s)
                    if before == .needs || before == .reply, s.state != .needs, s.state != .reply {
                        await speech.sessionAnswered(s.session)
                    }
                    if before != nil { await banners.sessionChanged(s.session, to: s.state) }
                case .approval(let a):
                    let taken = await approvals.apply(a)
                    await events.add(a.isClosed ? "approval closed (\(a.by ?? "?"))" : (taken ? "approval open" : "approval refused"))
                }
            }
        }
        try server.start()
        await events.add("listening for the plugin")
    }

    public func stop() {
        server.stop()
        inbox.finish()
    }

    /// The Mac locked or went to sleep: what changes from now on goes into the recap.
    public func wentAway(at date: Date = Date()) async { await away.left(at: date) }

    /// You came back. After 10 minutes or more away with something changed,
    /// the recap is queued (when `speak` allows it) and returned.
    @discardableResult
    public func cameBack(at date: Date = Date(), speak: Bool) async -> AwayRecap.Recap? {
        let list = await sessions.sessions
        let states = Dictionary(list.map { ($0.id, $0.state) }, uniquingKeysWith: { a, _ in a })
        let names = Dictionary(list.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        guard let recap = await away.back(at: date, states: states, names: names), speak else { return nil }
        await events.add("recap")
        await speech.sayRecap(recap)
        return recap
    }

    /// The real thing: Kokoro, ElevenLabs and say from the config, the real
    /// player, mic and ducker. The config is read again for each line, so
    /// settings apply at once.
    public static func live(config: @escaping @Sendable () -> EarshotConfig)
        -> (core: EarshotCore, ducker: TapDucker, mic: MicMonitor, synth: LiveSynth, speakLevel: AudioLevel,
            fullScreen: FullScreenWatch) {
        let mic = MicMonitor()
        let ducker = TapDucker {
            let c = config()
            return (c.duckEnabled, c.duckLevel)
        }
        let synth = LiveSynth(config: config)
        let player = AudioFilePlayer(output: {
            AudioDevices.chooseOutput(setting: config().outputDevice, devices: AudioDevices.all())
        })
        let fullScreen = FullScreenWatch { config().quietInFullScreen }
        let speech = SpeechOut(synth: synth, player: player, mic: mic, quiet: fullScreen, ducker: ducker)
        let core = EarshotCore(speech: speech, sessions: SessionStore(), events: EventLog(),
                               banners: Banners { config().banner })
        return (core, ducker, mic, synth, player.level, fullScreen)
    }
}

/// Builds the engine chain from the config for each line, keeping one Kokoro
/// engine per voice so the model stays loaded.
public final class LiveSynth: Synthesizer, @unchecked Sendable {
    private let config: @Sendable () -> EarshotConfig
    private let lock = NSLock()
    private var kokoro: KokoroEngine?

    init(config: @escaping @Sendable () -> EarshotConfig) { self.config = config }

    public func audio(for line: SpokenLine) async -> URL? {
        let c = config()
        return await EngineChain.make(config: c, kokoro: engine(for: c)).audio(for: line)
    }

    /// Loads Kokoro now when it is the engine, so the first line is not slow.
    /// A cold load takes about 12 seconds.
    public func prepare() async {
        let c = config()
        guard c.engine == .kokoro else { return }
        await engine(for: c).prepare()
    }

    private func engine(for c: EarshotConfig) -> KokoroEngine {
        lock.withLock {
            if let kokoro, kokoro.voice == c.kokoroVoice { return kokoro }
            let fresh = KokoroEngine(voice: c.kokoroVoice)
            kokoro = fresh
            return fresh
        }
    }
}
