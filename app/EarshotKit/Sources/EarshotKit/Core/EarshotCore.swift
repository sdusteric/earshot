import Foundation

/// Wires the plugin socket to the speaker and the session list. Messages are
/// handled one at a time, in the order they arrive.
public final class EarshotCore: Sendable {
    public static var socketPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/Earshot/earshot.sock").path
    }

    public let speech: SpeechOut
    public let sessions: SessionStore
    public let events: EventLog
    private let server: LineServer
    private let inbox: AsyncStream<AppMessage>.Continuation
    private let stream: AsyncStream<AppMessage>

    public init(socketPath: String = EarshotCore.socketPath, speech: SpeechOut, sessions: SessionStore, events: EventLog) {
        self.speech = speech
        self.sessions = sessions
        self.events = events
        let (stream, inbox) = AsyncStream<AppMessage>.makeStream()
        self.stream = stream
        self.inbox = inbox
        server = LineServer(path: socketPath) { line in
            do {
                inbox.yield(try AppMessage.decode(line))
                return AppReply(ok: true).encoded
            } catch AppMessage.DecodeError.version {
                return AppReply(ok: false, reason: "version").encoded
            } catch {
                return AppReply(ok: false, reason: "unreadable").encoded
            }
        }
    }

    /// Starts the speaker, then opens the socket.
    public func start() async throws {
        await speech.start()
        let (stream, speech, sessions, events) = (self.stream, self.speech, self.sessions, self.events)
        Task {
            for await message in stream {
                switch message {
                case .say(let s):
                    await events.add("line \(s.kind.rawValue)")
                    await speech.enqueue(SpokenLine(text: s.text, kind: s.kind, session: s.session, transcript: s.transcript))
                case .status(let s):
                    let before = await sessions.apply(s)
                    if before == .needs || before == .reply, s.state != .needs, s.state != .reply {
                        await speech.sessionAnswered(s.session)
                    }
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

    /// The real thing: Kokoro, ElevenLabs and say from the config, the real
    /// player, mic and ducker. The config is read again for each line, so
    /// settings apply at once.
    public static func live(config: @escaping @Sendable () -> EarshotConfig)
        -> (core: EarshotCore, ducker: TapDucker, mic: MicMonitor, synth: LiveSynth) {
        let mic = MicMonitor()
        let ducker = TapDucker {
            let c = config()
            return (c.duckEnabled, c.duckLevel)
        }
        let synth = LiveSynth(config: config)
        let speech = SpeechOut(synth: synth, player: AudioFilePlayer(), mic: mic, ducker: ducker)
        let core = EarshotCore(speech: speech, sessions: SessionStore(), events: EventLog())
        return (core, ducker, mic, synth)
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
